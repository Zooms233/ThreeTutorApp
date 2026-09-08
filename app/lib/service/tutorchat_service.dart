import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter/services.dart' show rootBundle;

import 'package:tutor_chat/service/llm_client.dart';
import 'package:tutor_chat/service/prompt.dart';
import 'package:tutor_chat/service/storage.dart';

//编排层：五场景的 读档 → 组装 → 调用 → 写档 → 状态推进（04-LLM调用.md 场景与载入）。
//先写后说：用户消息落档后才发请求；回复落档后 UI 才解锁输入框。
//LLM 只产出文本；status 推进、日期计算、档案轮换等确定性计算全部在本层完成。

class TutorChatService {
  final StorageService _storage;
  final PromptBuilder _prompts;
  final LlmClient _client;

  // —— 跨页面生成中状态 ——
  //退出聊天页再进入时仍显示「正在输入中」并锁输入框，避免用户消息与后台生成并发写同一文件。
  //状态由本层（而非页面）持有，且 static 跨实例共享：聊天页每次进入都新建 service 实例，
  //busy 若挂在实例上，退出重进后新实例读不到进行中状态、也收不到完成通知
  //（Banner 丢失 + 完成后不触发刷新——下课总结→更新→群聊全程跨页面存活的关键）。
  static final Map<String, String> _busy = {}; //courseName → Banner 文案；无条目 = 空闲
  static final ValueNotifier<int> busyVersion = ValueNotifier(
    0,
  ); //busy 每次变更自增，页面监听用

  static void _setBusy(String courseName, String label) {
    if (label.isEmpty) {
      if (_busy.remove(courseName) != null) busyVersion.value++;
    } else if (_busy[courseName] != label) {
      _busy[courseName] = label;
      busyVersion.value++;
    }
  }

  ///某课程当前的生成中 Banner 文案（空 = 空闲）
  static String busyLabelOf(String courseName) => _busy[courseName] ?? '';

  ///页面侧占位：场景方法发出请求前预先占 busy（如建档后问候前），
  ///使输入框/按钮立即锁定，避免用户消息与即将发出的后台写入竞态
  static void setBusyForCourse(String courseName, String label) =>
      _setBusy(courseName, label);

  TutorChatService({
    StorageService? storage,
    PromptBuilder? prompts,
    LlmClient? client,
  }) : _storage = storage ?? StorageService(),
       _prompts = prompts ?? PromptBuilder(),
       _client = client ?? LlmClient();

  // —— 基础 ——

  Future<LlmConfig> _config() async =>
      LlmConfig.fromMap(await _storage.loadConfig());

  Future<String> _courseDir(String courseName) async =>
      (await _storage.getCourseDir(courseName)).path;

  // —— 群聊重新生成（独立入口：不依赖下课链，可单独触发/验证） ——

  //定位最新 ended 课次（群聊归属于已下课的课次；从最新往回找）
  Future<String?> _latestEndedLessonPath(String courseName) async {
    final files = await _storage.listChatFiles(courseName);
    for (final path in files.reversed) {
      final meta =
          jsonDecode((await File(path).readAsLines()).first)
              as Map<String, dynamic>;
      if (meta['status'] == 'ended') return path;
    }
    return null;
  }

  ///清空最新 ended 课次的既有群聊：文件重写过滤 auto 行（破坏性操作，调用方需确认）；
  ///返回是否找到 ended 课次
  Future<bool> clearGroupChat({required String courseName}) async {
    final path = await _latestEndedLessonPath(courseName);
    if (path == null) return false;
    final kept = (await File(path).readAsLines())
        .where((line) => line.trim().isEmpty || !line.contains('"auto":true'))
        .toList();
    await File(path).writeAsString(kept.join('\n'));
    return true;
  }

  ///重新生成最新 ended 课次的群聊（调用方先 clearGroupChat）：逐条落档 + 回调上屏
  Future<void> regenerateGroupChat({
    required String courseName,
    void Function(Map<String, dynamic> message)? onMessage,
  }) async {
    final path = await _latestEndedLessonPath(courseName);
    if (path == null) throw LlmException('没有已结束的课次，无群聊可生成');
    final courseDir = await _courseDir(courseName);
    await _generateGroupChat(courseDir, path, path, onMessage: onMessage);
  }

  // —— token 用量入账 ——
  //统一对话出口：透传协议层；成功后把 usage 追加进数据根 USAGE.jsonl。设置页「用量统计」
  //现读该账本聚合展示，账本文件即唯一事实。失败重试的中间请求拿不到 usage，无法入账
  //（账本只记成功请求）；连通性检验（ping）也不计。
  Future<LlmResult> _chatLogged({
    required String course,
    String? lessonPath,
    required String scene,
    required List<Map<String, String>> messages,
    bool jsonMode = false,
    bool stream = true,
    int? maxTokens, //JSON 场景防截断
    String? thinkingEffort, //思考档位透传（更新/群聊用 'low'：保指令遵循，砍思考量）
    void Function(String delta)? onDelta,
    String? label,
  }) async {
    final result = await _client.chat(
      config: await _config(),
      messages: messages,
      jsonMode: jsonMode,
      stream: stream,
      maxTokens: maxTokens,
      thinkingEffort: thinkingEffort,
      onDelta: onDelta,
      label: label,
    );
    final u = result.usage;
    if (u != null) {
      //fire-and-forget：不阻塞对话主流程；写账失败静默（账本非关键路径）
      unawaited(
        _storage
            .appendUsage(
              course: course,
              lesson: lessonPath?.split(RegExp(r'[/\\]')).last,
              scene: scene,
              input: u.input,
              output: u.output,
              cacheRead: u.cacheRead,
              reasoning: u.reasoning,
            )
            .catchError((Object _) {}),
      );
    }
    return result;
  }

  ///「其他」字段提炼（关系页编辑入口）：读最新课次留档全文 → LLM 提炼 → 返回草稿文本。
  ///只预填不落盘（UI 把关后随保存写入）；无课次记录返回 null（调用方提示）。
  Future<String?> extractLearnerExtra({required String courseName}) async {
    final files = await _storage.listChatFiles(courseName);
    if (files.isEmpty) return null;
    final path = files.last;
    final messages = await _prompts.learnerExtra(chatPath: path);
    final result = await _chatLogged(
      course: courseName,
      lessonPath: path,
      scene: '提炼',
      messages: messages,
      stream: false,
      label: '提炼',
    );
    return result.text.trim();
  }

  String _today() {
    final n = DateTime.now();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }

  String _now() {
    final n = DateTime.now();
    return '${_today()} ${n.hour.toString().padLeft(2, '0')}:${n.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _appendUser(
    String path,
    String name,
    String content,
    String phase,
  ) => _storage.appendChatMessage(path, {
    'type': 'message',
    'phase': phase,
    'role': 'user',
    'name': name,
    'time': _now(),
    'content': content,
  });

  Future<void> _appendTutor(
    String path,
    String name,
    String content,
    String phase,
  ) => _storage.appendChatMessage(path, {
    'type': 'message',
    'phase': phase,
    'role': 'tutor',
    'name': name,
    'content': content,
  });

  //social 落档目标：上一课文件尾（群聊讨论段）；不足两课时兜底最新文件
  Future<String> _socialTargetFile(String courseName) async {
    final files = await _storage.listChatFiles(courseName);
    return files.length >= 2 ? files[files.length - 2] : files.last;
  }

  //课程内全部导师名（tutor_*.json 的 name 字段）
  Future<List<String>> _tutorNames(String courseDir) async {
    final names = <String>[];
    for (final e in Directory(courseDir).listSync()) {
      final base = e.path.split(Platform.pathSeparator).last;
      if (e is File && base.startsWith('tutor_') && base.endsWith('.json')) {
        final name =
            (jsonDecode(await e.readAsString()) as Map<String, dynamic>)['name']
                as String?;
        if (name != null && name.isNotEmpty) names.add(name);
      }
    }
    return names;
  }

  //按档案 name 字段定位档案文件
  Future<File?> _tutorFile(String courseDir, String tutorName) async {
    for (final e in Directory(courseDir).listSync()) {
      final base = e.path.split(Platform.pathSeparator).last;
      if (e is File && base.startsWith('tutor_') && base.endsWith('.json')) {
        final data = jsonDecode(await e.readAsString()) as Map<String, dynamic>;
        if (data['name'] == tutorName) return e;
      }
    }
    return null;
  }

  //轮换：tutor_a→b→c→a（按文件名字母序；当前导师找不到则不轮换）
  Future<String> _rotateTutor(String courseDir, String currentTutor) async {
    final files = <(String, String)>[]; //（文件字母, 档案 name）
    for (final e in Directory(courseDir).listSync()) {
      final base = e.path.split(Platform.pathSeparator).last;
      final m = RegExp(r'^tutor_([abc])\.json$').firstMatch(base);
      if (e is File && m != null) {
        final data = jsonDecode(await e.readAsString()) as Map<String, dynamic>;
        files.add((m.group(1)!, data['name'] as String? ?? ''));
      }
    }
    files.sort((a, b) => a.$1.compareTo(b.$1));
    final idx = files.indexWhere((f) => f.$2 == currentTutor);
    if (idx < 0 || files.isEmpty) return currentTutor;
    return files[(idx + 1) % files.length].$2;
  }

  //回复行解析：「{导师名}: {内容}」（半/全角冒号）；未命中导师名 → (fallback, 原行)
  (String, String) _parseReplyLine(
    String line,
    List<String> tutorNames,
    String fallback,
  ) {
    final pattern = RegExp(
      '^(${tutorNames.map(RegExp.escape).join('|')})[::]\\s*(.*)\$',
    );
    final m = pattern.firstMatch(line.trim());
    if (m == null) return (fallback, line.trim());
    return (m.group(1)!, m.group(2)!.trim());
  }

  //课后更新输出提取：剥离 ```json 围栏 → 取最外层 {} → jsonDecode
  Map<String, dynamic> _extractJson(String text) {
    var t = text.trim();
    final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(t);
    if (fence != null) t = fence.group(1)!.trim();
    final start = t.indexOf('{');
    final end = t.lastIndexOf('}');
    if (start < 0 || end <= start) throw const FormatException('输出中未找到 JSON');
    return jsonDecode(t.substring(start, end + 1)) as Map<String, dynamic>;
  }

  //review 偏移（写档用）：✓+7d / △+3d / ✗+1d，其他默认 +7
  String _offsetReview(String date, String status) {
    final days = status == '△' ? 3 : (status == '✗' ? 1 : 7);
    final d = DateTime.parse(date).add(Duration(days: days));
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  // —— 三态判定（UI 输入框发送去向）——

  ///返回 'qa' | 'teaching' | 'social'（04 消息三态与发送流向）。
  ///idle 且未上过课 → qa（无 toggle）；idle 且上过课 → toggle 未激活 qa / 激活 social；ongoing → teaching。
  Future<String> judgeFlow(
    String courseName, {
    required bool toggleActive,
  }) async {
    final meta = await _storage.loadLatestChatMeta(courseName);
    if (meta == null) return 'qa';
    if (meta['status'] == 'ongoing') return 'teaching';
    final state = await _storage.loadCourseState(courseName);
    final lessons = state['lessons'] as int? ?? 0;
    return (lessons >= 1 && toggleActive) ? 'social' : 'qa';
  }

  // —— 场景 1/3：交流期发送（问答 / 聊天）——

  ///先写后说：用户消息落档 → 拼装 → 调用 → 回应写档。
  ///返回 (实际发言导师名, 回复全文)；失败抛 LlmException（消息已留档，重试/再发由连续合并消化）。
  Future<(String, String)> sendUserMessage({
    required String courseName,
    required String content,
    required bool social,
  }) async {
    //入口即占 busy：定位文件/读 meta 等准备期间输入框已锁（页面可能先占通用文案，
    //此处细化），杜绝判定窗口内连发两条导致的并发写同一文件
    _setBusy(courseName, social ? '群里正在输入中…' : '正在输入中…');
    try {
      //落档目标：qa 写最新课次文件（下一课区间的交流段）；social 写上一课文件尾（群聊讨论段）
      final path = social
          ? await _socialTargetFile(courseName)
          : (await _storage.getCurrentLesson(courseName))['path'] as String;
      final meta =
          jsonDecode((await File(path).readAsLines()).first)
              as Map<String, dynamic>;
      final responder =
          meta['tutor'] as String? ?? '导师'; //问答=next_tutor；聊天前缀未命中时的回退
      if (!social) _setBusy(courseName, '$responder 正在输入中…'); //拿到导师名后细化文案
      final learner = await _storage.loadCourseLearner(courseName);
      final userName = learner['name'] as String? ?? '学习者';
      final phase = social ? 'social' : 'qa';

      await _appendUser(path, userName, content, phase);

      final courseDir = await _courseDir(courseName);
      final messages = social
          ? await _prompts.social(courseDir: courseDir, chatPath: path)
          : await _prompts.qa(
              courseDir: courseDir,
              chatPath: path,
              tutorName: responder,
            );

      final result = await _chatLogged(
        course: courseName,
        lessonPath: path,
        scene: social ? '闲聊' : '问答',
        messages: messages,
        stream: true,
        label: social ? '闲聊' : '问答',
      );

      final (name, text) = social
          ? _parseReplyLine(
              result.text,
              await _tutorNames(courseDir),
              responder,
            )
          : (responder, result.text.trim());
      await _appendTutor(path, name, text, phase);
      return (name, text);
    } finally {
      _setBusy(courseName, '');
    }
  }

  // —— 场景 2：上课对话（ongoing + 用户消息）——

  ///先写后说（phase=teaching）→ 教学全量拼装（无调度指令）→ 流式生成 → 写档。
  ///返回 (本课导师名, 回复全文)。
  Future<(String, String)> sendLessonMessage({
    required String courseName,
    required String content,
  }) async {
    _setBusy(courseName, '正在输入中…'); //入口即占 busy（校验期间锁输入框）
    try {
      final lesson = await _storage.getCurrentLesson(courseName);
      final path = lesson['path'] as String;
      final meta =
          jsonDecode((await File(path).readAsLines()).first)
              as Map<String, dynamic>;
      if (meta['status'] != 'ongoing') {
        throw LlmException('非上课状态（meta=${meta['status']}），无法走上课对话');
      }
      final tutor = meta['tutor'] as String? ?? '导师';
      _setBusy(courseName, '$tutor 正在输入中…'); //拿到导师名后细化文案
      final learner = await _storage.loadCourseLearner(courseName);
      final userName = learner['name'] as String? ?? '学习者';

      await _appendUser(path, userName, content, 'teaching');
      final courseDir = await _courseDir(courseName);
      final messages = await _prompts.teaching(
        courseDir: courseDir,
        chatPath: path,
        tutorName: tutor,
      );
      final result = await _chatLogged(
        course: courseName,
        lessonPath: path,
        scene: '上课',
        messages: messages,
        stream: true,
        label: '上课',
      );
      await _appendTutor(path, tutor, result.text, 'teaching');
      return (tutor, result.text);
    } finally {
      _setBusy(courseName, '');
    }
  }

  // —— 场景 4：课前问候（「开始上课」按钮）——

  ///meta idle→ongoing → 拼装（含问候调度指令）→ 流式生成 → 写档 phase=teaching。
  ///失败：重试耗尽后 meta 保持 ongoing，抛出（用户直接发消息即走上课对话自然恢复）。
  Future<String> startLesson({required String courseName}) async {
    final lesson = await _storage.getCurrentLesson(courseName);
    final path = lesson['path'] as String;
    final tutor = lesson['tutor'] as String;
    _setBusy(courseName, '$tutor 正在输入中…'); //跨页面生成中状态
    try {
      await _storage.patchChatMeta(path, {'status': 'ongoing'});

      final courseDir = await _courseDir(courseName);
      //占位符替换：dispatch_greeting.md 内的 {导师名} 填入本课导师（与 update.md 规则同规则）
      final dispatch = (await rootBundle.loadString(
        'assets/prompts/dispatch_greeting.md',
      )).replaceAll('{导师名}', tutor);
      final messages = await _prompts.teaching(
        courseDir: courseDir,
        chatPath: path,
        tutorName: tutor,
        dispatch: dispatch,
      );
      final result = await _chatLogged(
        course: courseName,
        lessonPath: path,
        scene: '问候',
        messages: messages,
        stream: true,
        label: '问候',
      );
      await _appendTutor(path, tutor, result.text, 'teaching');
      return result.text;
    } finally {
      _setBusy(courseName, '');
    }
  }

  // —— 场景 5+6+7：下课总结 → 课后更新 → 导师群聊生成 ——
  //返回值告知 UI 课后更新是否完成（false = meta 保持 ongoing，可重新点击重跑场景 5+6）

  ///下课总结（含调度指令）→ 落档后自动课后更新 → 群聊生成（失败跳过）。
  ///onMessage：每条消息落档即回调（总结一条 + 群聊逐条），UI 逐条弹出用。
  ///抛出 = 总结或更新失败；更新失败时 meta 保持 ongoing、下一课文件不创建。
  Future<void> endLesson({
    required String courseName,
    void Function(Map<String, dynamic> message)? onMessage,
  }) async {
    final lesson = await _storage.getCurrentLesson(courseName);
    final path = lesson['path'] as String;
    final tutor = lesson['tutor'] as String;
    final lessonNo = lesson['lesson'] as int;
    _setBusy(courseName, '$tutor 正在输入中…'); //跨页面生成中状态（总结→更新→群聊全程）

    try {
      //下课总结（meta 仍 ongoing）
      final courseDir = await _courseDir(courseName);
      final dispatch = await rootBundle.loadString(
        'assets/prompts/dispatch_summary.md',
      );
      final messages = await _prompts.teaching(
        courseDir: courseDir,
        chatPath: path,
        tutorName: tutor,
        dispatch: dispatch,
      );
      final result = await _chatLogged(
        course: courseName,
        lessonPath: path,
        scene: '总结',
        messages: messages,
        stream: true,
        label: '总结',
      );
      await _appendTutor(path, tutor, result.text, 'teaching');
      //总结落档即回调：UI 先显示导师告别，再逐条放群聊
      onMessage?.call({
        'type': 'message',
        'phase': 'teaching',
        'role': 'tutor',
        'name': tutor,
        'content': result.text,
      });

      //总结落档 → 课后更新（JSON 解析重试 1 次后仍失败 → 保持 ongoing）
      final updated = await _postLessonUpdate(
        courseName,
        courseDir,
        path,
        tutor,
        lessonNo,
        onMessage: onMessage,
      );
      if (!updated) {
        throw LlmException('课后更新失败：meta 保持 ongoing，可重新点击「今天就到这里」重跑');
      }
    } finally {
      _setBusy(courseName, '');
    }
  }

  //课后更新：更新指令 + PROGRESS 规范 + 现有清单 + 本课导师档案 + 对话；jsonMode 非流式
  Future<bool> _postLessonUpdate(
    String courseName,
    String courseDir,
    String lessonPath,
    String tutorName,
    int lessonNo, {
    void Function(Map<String, dynamic> message)? onMessage,
  }) async {
    Map<String, dynamic>? output;
    for (var attempt = 0; attempt < 2; attempt++) {
      final messages = await _prompts.update(
        courseDir: courseDir,
        chatPath: lessonPath,
        tutorName: tutorName,
      );
      _setBusy(courseName, '整理课程进度中…'); //更新环节的状态文案（区别于总结/群聊）
      final result = await _chatLogged(
        course: courseName,
        lessonPath: lessonPath,
        scene: '更新',
        messages: messages,
        stream: false,
        //不开 jsonMode（response_format）了：DeepSeek 文档明确该模式有概率返回空
        //content（叠加思考模式更易触发，2026-09-08 遗传学实测两连空），服务端 bug
        //绕开优于对抗；update.md 已严格约束纯 JSON 输出，_extractJson 负责兼容围栏
        maxTokens: 4096, //防 JSON 截断
        thinkingEffort: 'low', //格式化 JSON 生成用低强度思考（disabled 会复读指令不执行）
        label: '更新',
      );
      try {
        output = _extractJson(result.text);
        break;
      } on FormatException {
        if (attempt == 1) return false; //重试后仍解析失败
      }
    }
    //写档四步；群聊生成写本课文件尾；下一课文件在群聊落档后创建（qa 交流写它的头部）
    final nextTutor = await _applyLessonUpdate(
      courseName,
      courseDir,
      lessonPath,
      tutorName,
      lessonNo,
      output!,
    );
    _setBusy(courseName, '群里正在输入中…'); //群聊阶段切换 Banner 文案（跨页面状态）
    //群聊生成：输入=本课对话，写档=本课文件尾（总结之后）；失败跳过，不阻塞课后更新其余成果
    try {
      await _generateGroupChat(
        courseDir,
        lessonPath,
        lessonPath,
        onMessage: onMessage,
      );
    } catch (_) {}
    await _storage.createLessonFile(courseName, lessonNo + 1, nextTutor);
    return true;
  }

  //课后更新写档：按序五步，全部确定性计算（04 场景流程）；返回创建的下一课文件路径
  Future<String> _applyLessonUpdate(
    String courseName,
    String courseDir,
    String lessonPath,
    String tutorName,
    int lessonNo,
    Map<String, dynamic> output,
  ) async {
    final today = _today();
    final nextTutor = await _rotateTutor(courseDir, tutorName);

    //1. STATE 单行重写
    final state = await _storage.loadCourseState(courseName);
    state['position'] = output['position'] as String? ?? '';
    state['next_tutor'] = nextTutor;
    state['lessons'] = (state['lessons'] as int? ?? 0) + 1;
    state['last_date'] = today;
    await _storage.saveCourseState(courseName, state);

    //2. PROGRESS：新知识点追加一行；已有整行重写（records 追加新状态块）
    final rows = await _storage.loadCourseProgress(courseName);
    for (final raw in (output['progress'] as List? ?? const [])) {
      final item = raw as Map<String, dynamic>;
      final name = item['name'] as String? ?? '';
      if (name.isEmpty) continue;
      final status = item['status'] as String? ?? '✓';
      final block = <String, dynamic>{
        'status': status,
        'date': today,
        'review': _offsetReview(today, status),
      };
      final mistake = item['mistake'] as String?;
      if (status != '✓' && mistake != null && mistake.isNotEmpty) {
        block['mistake'] = mistake;
      }
      final idx = rows.indexWhere((r) => r['name'] == name);
      if (idx >= 0) {
        final row = rows[idx];
        row['records'] = [...(row['records'] as List? ?? const []), block];
        rows[idx] = row;
      } else {
        rows.add({
          'name': name,
          'records': [block],
        });
      }
    }
    //写回前按每行最新状态块的日期排序（旧→新）：loadCourseProgress 返回的是
    //UI 序（新在前），直接写回会让文件行序逐轮翻转、显示顺序错乱；
    //按日期归位保证文件恒时间正序，load 后 reversed 恒新在前（顺带修复历史乱序）
    String latestDate(Map<String, dynamic> row) {
      final records = row['records'] as List? ?? const [];
      if (records.isEmpty) return '';
      return (records.last as Map<String, dynamic>)['date'] as String? ?? '';
    }

    rows.sort((a, b) => latestDate(a).compareTo(latestDate(b)));
    final progressText = rows.map(jsonEncode).join('\n');
    await File('$courseDir/PROGRESS.jsonl').writeAsString('$progressText\n');

    //3. relation：与现文有差异才重写本课导师档案
    final relation = output['relation'] as String?;
    if (relation != null && relation.isNotEmpty) {
      final tutorFile = await _tutorFile(courseDir, tutorName);
      if (tutorFile != null) {
        final data =
            jsonDecode(await tutorFile.readAsString()) as Map<String, dynamic>;
        if (data['relation'] != relation) {
          data['relation'] = relation;
          await tutorFile.writeAsString(jsonEncode(data));
        }
      }
    }

    //4. 本课 meta：status→ended、date→实际完成日（lesson/tutor 保持）
    await _storage.patchChatMeta(lessonPath, {
      'status': 'ended',
      'date': today,
    });
    return nextTutor;
  }

  //场景 7：导师群聊生成（聊天职责的自动版）——流式逐行落档，写入本课文件尾
  //每行「导师名: 内容」在流式输出中生成完整（遇换行）即写档并回调，UI 实时逐条弹出，
  //不再等全量聚合后人为加延迟（那样长响应期间用户什么都看不到）。
  Future<void> _generateGroupChat(
    String courseDir,
    String chatPath,
    String targetPath, {
    void Function(Map<String, dynamic> message)? onMessage,
  }) async {
    final dispatch = await rootBundle.loadString(
      'assets/prompts/dispatch_group.md',
    );
    final messages = await _prompts.groupChat(
      courseDir: courseDir,
      chatPath: chatPath,
      dispatch: dispatch,
    );
    final names = await _tutorNames(courseDir);
    //未命中导师名 → name 取 meta.tutor（本课导师，04 规定）
    final meta =
        jsonDecode((await File(chatPath).readAsLines()).first)
            as Map<String, dynamic>;
    final fallback =
        meta['tutor'] as String? ?? (names.isNotEmpty ? names.first : '导师');

    //流式逐行解析：delta 增量拼入 buffer，每遇完整行即解析落档；
    //写档用串行链保证行序（文件追加不能并发）；解析本身同步（在 onDelta 回调里）
    Future<void> chain = Future.value();
    var buffer = '';
    void onLine(String raw) {
      final line = raw.replaceAll('\r', '').trim();
      if (line.isEmpty) return;
      final (name, content) = _parseReplyLine(line, names, fallback);
      if (content.isEmpty) return;
      final message = {
        'type': 'message',
        'phase': 'social',
        'role': 'tutor',
        'name': name,
        'content': content,
        'auto': true, //课后自动生成标记（qa 写入目标文件不含本文件，渲染忽略）
      };
      chain = chain.then((_) async {
        await _storage.appendChatMessage(targetPath, message);
        onMessage?.call(message);
      });
    }

    await _chatLogged(
      //courseDir 的 basename 即课程名（_courseDir 由课程名拼接生成）
      course: courseDir.split(RegExp(r'[/\\]')).last,
      lessonPath: chatPath,
      scene: '群聊',
      messages: messages,
      stream: true,
      label: '群聊',
      onDelta: (delta) {
        buffer += delta;
        for (;;) {
          final i = buffer.indexOf('\n');
          if (i < 0) break;
          onLine(buffer.substring(0, i));
          buffer = buffer.substring(i + 1);
        }
      },
    );
    onLine(buffer); //流末残留行（无换行结尾）
    await chain; //等最后一条落档完成（异常传播给调用方的群聊跳过逻辑）
  }
}
