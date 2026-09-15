import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show ValueNotifier, debugPrint, kDebugMode;
import 'package:flutter/services.dart' show rootBundle;

import 'package:three_tutor/service/key_cipher.dart';
import 'package:three_tutor/service/llm_client.dart';
import 'package:three_tutor/service/prompt.dart';
import 'package:three_tutor/service/storage.dart';

//编排层：五场景的 读档 → 组装 → 调用 → 写档 → 状态推进（04-LLM调用.md 场景与载入）。
//先写后说：用户消息落档后才发请求；回复落档后 UI 才解锁输入框。
//LLM 只产出文本；status 推进、日期计算、档案轮换等确定性计算全部在本层完成。

class ThreeTutorService {
  final StorageService _storage;
  final PromptBuilder _prompts;
  final LlmClient _client;

  // —— 跨页面生成中状态 ——
  //退出聊天页再进入时仍显示「正在输入中」并锁输入框，避免用户消息与后台生成并发写同一文件。
  //状态由本层（而非页面）持有，且 static 跨实例共享：聊天页每次进入都新建 service 实例，
  //busy 若挂在实例上，退出重进后新实例读不到进行中状态、也收不到完成通知
  //（Banner 丢失 + 完成后不触发刷新——下课更新→群聊全程跨页面存活的关键）。
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

  // —— 思考强度全局配置（设置页两段式档位，CONFIG.json 落盘恢复）——
  //纯文本组（闲聊/群聊生成/课后更新/画像提炼）共用一档；教学组（上课对话/问答/
  //课前问候，带翻书 tools）共用一档。取值仅 disabled / low / high（无档位时字段不发送）。
  //教学组开思考后：响应 reasoning 随 tool_call/tutor 行落档，并在后续请求回传
  //（DeepSeek 硬约束：带 tools 的请求必须回传历史 reasoning_content，否则 400）
  static String textThinkingEffort = 'low';
  static String teachingThinkingEffort = 'disabled';

  static bool isValidThinkingEffort(String v) =>
      v == 'disabled' || v == 'low' || v == 'high';

  ///某课程当前的生成中 Banner 文案（空 = 空闲）
  static String busyLabelOf(String courseName) => _busy[courseName] ?? '';

  ///页面侧占位：场景方法发出请求前预先占 busy（如建档后问候前），
  ///使输入框/按钮立即锁定，避免用户消息与即将发出的后台写入竞态
  static void setBusyForCourse(String courseName, String label) =>
      _setBusy(courseName, label);

  ThreeTutorService({
    StorageService? storage,
    PromptBuilder? prompts,
    LlmClient? client,
  }) : _storage = storage ?? StorageService(),
       _prompts = prompts ?? PromptBuilder(),
       _client = client ?? LlmClient();

  // —— 基础 ——

  //激活档解析：按 active id 从 profiles 取（active 为 null/悬空 = 无激活配置）。
  //Key 读时解混淆；无配置直接抛可读异常，由各场景现有错误展示链路提示用户完善
  Future<LlmConfig> _config() async {
    final config = await _storage.loadConfig();
    final activeId = config['active'] as String?;
    final sel = <Map<String, dynamic>>[
      for (final p in (config['profiles'] as List? ?? []))
        if (p is Map && p['id'] == activeId) Map<String, dynamic>.from(p),
    ];
    if (sel.isEmpty) {
      throw LlmException('API 未配置，请到「设置 → API 配置」完善');
    }
    final p = sel.first;
    return LlmConfig(
      apiUrl: p['apiUrl'] as String? ?? '',
      apiKey: deobfuscateKey(p['apiKey'] as String? ?? ''),
      model: p['model'] as String? ?? '',
    );
  }

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

  //临时测试（验证上下文拼接，验证后可删）：打印每轮实际发送的 messages 结构快照——
  //只打印角色序列 + 简化标签（提示词→长度、用户→编号+头30字、翻书→工具参数、教材→长度），
  //不打印全文，观察拼接顺序是否如预期（追加/重放/缓存延续）。
  //trace 开关：仅 debug 构建生效（release 编译期剔除，对话片段不落 logcat）；
  //临时排查 release 问题可临时改回 true
  static const bool _traceEnabled = kDebugMode;

  void _traceMessages(
    List<Map<String, dynamic>> messages, {
    List<Map<String, dynamic>>? tools,
    String? tag,
  }) {
    if (!_traceEnabled) return;
    final buf = StringBuffer();
    var userNo = 0;
    for (var i = 0; i < messages.length; i++) {
      final m = messages[i];
      final role = m['role'] as String? ?? '?';
      final content = m['content'];
      switch (role) {
        case 'system':
          buf.writeln('  [$i] system（${_describeSystem(content as String)}）');
        case 'user':
          userNo++;
          final head = (content as String? ?? '').replaceAll('\n', ' ').trim();
          buf.writeln(
            '  [$i] 用户消息$userNo「${head.length > 30 ? '${head.substring(0, 30)}…' : head}」',
          );
        case 'assistant':
          final calls = m['tool_calls'];
          if (calls is List && calls.isNotEmpty) {
            final fn =
                (calls.first as Map<String, dynamic>)['function']
                    as Map<String, dynamic>?;
            String? toolPath;
            int? offset, limit;
            try {
              final args =
                  jsonDecode(fn?['arguments'] as String? ?? '{}')
                      as Map<String, dynamic>;
              toolPath = args['path'] as String?;
              offset = args['offset'] as int?;
              limit = args['limit'] as int?;
            } catch (_) {}
            buf.writeln(
              '  [$i] assistant（翻书：$toolPath 第$offset行起${limit ?? ''}行）',
            );
          } else {
            final head = (content as String? ?? '')
                .replaceAll('\n', ' ')
                .trim();
            buf.writeln(
              '  [$i] 导师回复「${head.length > 30 ? '${head.substring(0, 30)}…' : head}」',
            );
          }
        case 'tool':
          buf.writeln('  [$i] tool（材料，${(content as String).length}字）');
        default:
          buf.writeln('  [$i] $role');
      }
    }
    debugPrint(
      '[trace] ${tag ?? ''} ${tools == null ? '不带工具' : '带工具'} ${messages.length}条\n$buf',
    );
  }

  //system 内容描述：识别规则文件 + 拼装块（不同场景的 system 组合不同，便于观察拼接来源）
  String _describeSystem(String content) {
    final blocks = <String>[];
    var rule = '?';
    //规则文件按标题特征识别（learner_extra 无 # 标题，用首句特征）
    if (content.contains('# 教学规则')) {
      rule = 'teaching.md';
      blocks.add('教学规则');
    } else if (content.contains('# 问答规则')) {
      rule = 'qa.md';
      blocks.add('问答规则');
    } else if (content.contains('# 聊天规则')) {
      rule = 'social.md';
      blocks.add('聊天规则');
    } else if (content.contains('# 导师群聊规范')) {
      rule = 'group.md';
      blocks.add('群聊规范');
    } else if (content.contains('# 课后更新任务')) {
      rule = 'update.md';
      blocks.add('更新指令');
    } else if (content.contains('从课次留档中提炼')) {
      rule = 'learner_extra.md';
      blocks.add('提炼规则');
    } else {
      rule = '?';
    }
    //拼装块识别（teaching/qa 的档案块带导师名，一并显示）
    final identity = RegExp(r'你是(.+?)。下面是你的档案').firstMatch(content);
    if (identity != null) blocks.add('导师档案[${identity.group(1)}]');
    if (content.contains('【学习者】')) blocks.add('学习者');
    if (content.contains('【课程状态】')) blocks.add('状态');
    if (content.contains('【知识点进度】')) blocks.add('进度');
    if (content.contains('【现有知识点】')) blocks.add('知识点清单');
    if (content.contains('今天是')) blocks.add('日期');
    if (content.contains('【教学范围')) blocks.add('教学范围');
    if (content.contains('今日教材进度')) blocks.add('教材当前节');
    if (content.contains('【教学材料目录】')) blocks.add('目录');
    return '$rule：${blocks.join('+')}（${content.length}字）';
  }

  Future<LlmResult> _chatLogged({
    required String course,
    String? lessonPath,
    required String scene,
    required List<Map<String, dynamic>> messages,
    bool jsonMode = false,
    bool stream = true,
    int? maxTokens, //JSON 场景防截断
    String? thinkingEffort, //思考档位透传（各场景由设置页全局两段配置注入，见各调用点）
    List<Map<String, dynamic>>? tools, //OpenAI 兼容 tools 定义（agent 翻书）；null=不带
    void Function(String delta)? onDelta,
    String? label,
    String? traceTag, //临时测试：请求轮次标识（如 上课#1），打印消息结构快照
  }) async {
    _traceMessages(messages, tools: tools, tag: traceTag); //临时测试：验证上下文拼接
    final result = await _client.chat(
      config: await _config(),
      messages: messages,
      jsonMode: jsonMode,
      stream: stream,
      maxTokens: maxTokens,
      thinkingEffort: thinkingEffort,
      tools: tools,
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

  ///「其他」字段提炼（关系页编辑入口）：读本课程课次留档 → LLM 提炼 → 返回草稿文本。
  ///本课程内忽略最新 1 篇（多为下课流程刚创建的空下一课文件），余下按课次号新→旧取 3 篇。
  ///只预填不落盘（UI 把关后随保存写入）；无可用素材（课次不足 2 篇）返回 null（调用方提示）。
  Future<String?> extractLearnerExtra({required String courseName}) async {
    final files = await _storage.listChatFiles(courseName); //旧→新
    final lessons = files.length <= 1
        ? <({String course, String path})>[]
        : files.reversed
              .skip(1) //跳过最新 1 篇
              .take(3)
              .map((p) => (course: courseName, path: p))
              .toList();
    if (lessons.isEmpty) return null;
    final messages = await _prompts.learnerExtra(lessons: lessons);
    final result = await _chatLogged(
      course: courseName,
      lessonPath: lessons.first.path, //账记最新一篇
      scene: '提炼',
      messages: messages,
      stream: false,
      label: '提炼',
      thinkingEffort: textThinkingEffort, //纯文本组全局档位
    );
    return result.text.trim();
  }

  ///「其他」字段跨课程提炼（建课页入口）：跨课程收素材（每门课忽略最新 1 篇空文件，
  ///余下按文件创建时间取 3 篇）→ LLM 提炼通用画像 → 返回草稿文本。
  ///只预填不落盘（表单把关后随建课写入）；记账归属最新一篇所属课程
  ///（新课程目录尚不存在，且多素材请求以最新一篇为主要依据）。
  ///无可用素材返回 null（调用方提示）。
  Future<String?> extractLearnerExtraAnyCourse() async {
    final lessons = await _storage.recentLessonsAcrossCourses();
    if (lessons.isEmpty) return null;
    final messages = await _prompts.learnerExtra(
      lessons: lessons,
      fromOtherCourse: true,
    );
    final result = await _chatLogged(
      course: lessons.first.course, //账记最新一篇所属课程
      lessonPath: lessons.first.path,
      scene: '提炼',
      messages: messages,
      stream: false,
      label: '提炼',
      thinkingEffort: textThinkingEffort, //纯文本组全局档位
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
    String phase, {
    String reasoning = '', //思考链随档落档（教学组开思考时历史回传用）
  }) => _storage.appendChatMessage(path, {
    'type': 'message',
    'phase': phase,
    'role': 'tutor',
    'name': name,
    'content': content,
    if (reasoning.isNotEmpty) 'reasoning': reasoning,
  });

  //修改重发定位：改写文件中物理最后一条 user 行（content + time=编辑时刻）并截断其后所有行。
  //安全性依据（UI 已判定长按消息 = 当前流目标文件的最后一条 user 行）：该行之后只可能是
  //本轮回复链（tool_call/tool/tutor）——auto 群聊行要么在别的文件、要么在该行之前；
  //生成失败时回复链可能残缺，截断后重发即恢复。busy 锁保证判定到执行间无并发写档。
  Future<void> _rewriteLastUser(String path, String content) async {
    final file = File(path);
    final lines = await file.readAsLines();
    var idx = -1;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      final row = jsonDecode(line) as Map<String, dynamic>;
      if (row['type'] == 'message' && row['role'] == 'user') idx = i;
    }
    if (idx < 0) throw LlmException('未找到可修改的用户消息');
    final row = jsonDecode(lines[idx]) as Map<String, dynamic>;
    row['content'] = content;
    row['time'] = _now(); //时间锚点更新为编辑时刻（重放头部 [MM-DD HH:mm] 随之）
    lines[idx] = jsonEncode(row);
    await file.writeAsString('${lines.sublist(0, idx + 1).join('\n')}\n');
  }

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

  //review 偏移（写档用，SRS 思路）：首次登记/刚答错后 ✓+7、△+3、✗+1；
  //此后连续 ✓ 使间隔递增 14→30→60（封顶）——越熟练越少打扰，停学期积压自动缩水；
  //间隔从 records 序列推导，PROGRESS schema 零变更
  String _offsetReview(String date, String status, List<dynamic> history) {
    int days;
    if (status == '△') {
      days = 3;
    } else if (status == '✗') {
      days = 1;
    } else {
      //从尾部数连续 ✓ 次数（不含本次），查表取间隔
      var streak = 0;
      for (final rec in history.reversed) {
        if ((rec as Map<String, dynamic>)['status'] != '✓') break;
        streak++;
      }
      days = switch (streak) {
        0 => 7,
        1 => 14,
        2 => 30,
        _ => 60,
      };
    }
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
  ///edit=true 为修改重发：改写目标文件物理最后一条 user 行（content/time 并截断其后本轮
  ///回复链，见 _rewriteLastUser）而非追加新行——被改行恰在本次拼装读取的文件内，回复衔接。
  ///返回 (实际发言导师名, 回复全文)；失败抛 LlmException（消息已留档，重试/再发由连续合并消化；
  ///修改场景内容已改写留档，重试幂等）。
  Future<(String, String)> sendUserMessage({
    required String courseName,
    required String content,
    required bool social,
    bool edit = false,
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

      if (edit) {
        await _rewriteLastUser(path, content);
      } else {
        await _appendUser(path, userName, content, phase);
      }

      final courseDir = await _courseDir(courseName);
      final messages = social
          ? await _prompts.social(courseDir: courseDir, chatPath: path)
          : await _prompts.qa(
              courseDir: courseDir,
              chatPath: path,
              tutorName: responder,
            );

      //qa 走 agent 翻书（教材按需载入：仅注入目录，需要哪节读哪节——省 token 核心）；
      //social 纯文本不带工具
      final result = social
          ? await _chatLogged(
              course: courseName,
              lessonPath: path,
              scene: '闲聊',
              messages: messages,
              stream: true,
              label: '闲聊',
              thinkingEffort: textThinkingEffort, //纯文本组全局档位
            )
          : await _chatWithTextbook(
              courseName: courseName,
              courseDir: courseDir,
              path: path,
              tutor: responder,
              scene: '问答',
              messages: messages,
              label: '问答',
            );

      final (name, text) = social
          ? _parseReplyLine(
              result.text,
              await _tutorNames(courseDir),
              responder,
            )
          : (responder, result.text.trim());
      await _appendTutor(
        path,
        name,
        text,
        phase,
        //思考链仅教学/问答（翻书链路）需要存档回传；闲聊纯文本无回传约束
        reasoning: social ? '' : result.reasoningContent,
      );
      return (name, text);
    } finally {
      _setBusy(courseName, '');
    }
  }

  // —— agent 翻书（按需载入教材，对齐 pi agent harness）——
  //请求带 read_textbook 工具 → 响应含 tool_calls → 执行（读盘切节）→ 落档 tool_call/tool
  //指针行 → 以 tool 消息追加上下文 → 再请求，循环直到无翻书（上限 maxRounds 轮，末轮不带
  //工具强制出文本）。中间轮次只落指针不落正文：下次请求重放时物化回原样 → 前缀缓存延续。
  //返回最后一轮（纯文本）的 LlmResult；翻书轮次夹带的文本丢弃（罕见，模型以翻书为主）。
  //
  //思考模式约束（DeepSeek 2026-09 文档）：带 tools 的请求必须完整回传历史
  //reasoning_content，否则 400。档位由设置页全局配置（teachingThinkingEffort，默认
  //disabled）；开启后响应 reasoning 随 tool_call/tutor 行落档（'reasoning' 字段），
  //会话内即时回传（current 链）+ 重放时由 _mapHistory 从档回传。旧档案无 reasoning
  //字段（disabled 时代）不回传——未思考的轮次无内容可回传，符合约束语义
  Future<LlmResult> _chatWithTextbook({
    required String courseName,
    required String courseDir,
    required String path, //落档路径（与 messages 来源文件一致）
    required String tutor, //busy 文案与 tool 行 name
    required String scene,
    required List<Map<String, dynamic>> messages,
    String? label,
    int maxRounds = 4,
  }) async {
    var current = messages;
    var result = const LlmResult(text: '');
    for (var round = 0; round < maxRounds; round++) {
      final isLast = round == maxRounds - 1;
      result = await _chatLogged(
        course: courseName,
        lessonPath: path,
        scene: scene,
        messages: current,
        stream: true,
        tools: isLast ? null : PromptBuilder.readToolDefs,
        thinkingEffort: teachingThinkingEffort, //教学组全局档位（见上注释）
        label: label,
        traceTag: '$label#${round + 1}', //临时测试：轮次标识（验证上下文拼接）
      );
      if (result.toolCalls.isEmpty) return result;

      //翻书轮次：落档 assistant(tool_calls) 行（tool_calls 原样，重放透传保持字节一致）
      await _storage.appendChatMessage(path, {
        'type': 'tool_call',
        'role': 'assistant',
        'name': tutor,
        'time': _now(),
        'tool_calls': result.toolCalls,
        //开思考时落档思考链：后续请求（会话链与重放）回传用
        if (result.reasoningContent.isNotEmpty)
          'reasoning': result.reasoningContent,
      });
      _setBusy(courseName, '$tutor 正在翻阅教材…');

      //assistant 消息用与重放相同的 PromptMessage 构造（键序一致，缓存前缀不碎）；
      //reasoning 同步入链：翻书循环第二轮请求必须回传，否则 400
      current = [
        ...current,
        PromptMessage(
          'assistant',
          null,
          result.toolCalls,
          null,
          result.reasoningContent.isEmpty ? null : result.reasoningContent,
        ).toMap(),
      ];
      for (final call in result.toolCalls) {
        final id = call['id'] as String? ?? '';
        final fn = call['function'] as Map<String, dynamic>?;
        String? toolPath; //read 工具的 path（目录中相对路径）
        int? offset, limit;
        String? content;
        try {
          final args =
              jsonDecode(fn?['arguments'] as String? ?? '{}')
                  as Map<String, dynamic>;
          toolPath = args['path'] as String?;
          offset = args['offset'] as int?;
          limit = args['limit'] as int?;
          if (toolPath == null || toolPath.isEmpty) {
            throw const FormatException('缺少 path');
          }
          content = PromptBuilder.executeReadTool(
            courseDir,
            toolPath,
            offset,
            limit,
          );
        } catch (e) {
          content = null;
        }
        if (content == null) {
          //未找到/参数错：错误文本作为快照落档（重放直接用，不再物化）
          final err = toolPath == null || toolPath.isEmpty
              ? '【read】参数解析失败，请核对 path（目录中的文件路径）。'
              : '【read】文件「$toolPath」不存在或行号超出范围，请对照【教学材料目录】重新调用。';
          await _storage.appendChatMessage(path, {
            'type': 'tool',
            'tool_call_id': id,
            'name': tutor,
            'time': _now(),
            'content': err,
          });
          current = [...current, PromptMessage('tool', err, null, id).toMap()];
        } else {
          //成功：只落指针（path/offset/limit），重放时物化读盘
          await _storage.appendChatMessage(path, {
            'type': 'tool',
            'tool_call_id': id,
            'name': tutor,
            'time': _now(),
            'path': toolPath,
            'offset': ?offset,
            'limit': ?limit,
          });
          current = [
            ...current,
            PromptMessage('tool', content, null, id).toMap(),
          ];
        }
      }
    }
    return result;
  }

  // —— 场景 2：上课对话（ongoing + 用户消息）——

  ///先写后说（phase=teaching）→ 教学全量拼装（无调度指令）→ 流式生成 → 写档。
  ///edit=true 为修改重发：改写本课文件物理最后一条 user 行并截断其后回复链，不再追加新行
  ///（meta 非 ongoing 时照常抛异常——ended 后「修改」入口已消失，此处兜底）。
  ///返回 (本课导师名, 回复全文)。
  Future<(String, String)> sendLessonMessage({
    required String courseName,
    required String content,
    bool edit = false,
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

      if (edit) {
        await _rewriteLastUser(path, content);
      } else {
        await _appendUser(path, userName, content, 'teaching');
      }
      final courseDir = await _courseDir(courseName);
      final messages = await _prompts.teaching(
        courseDir: courseDir,
        chatPath: path,
        tutorName: tutor,
      );
      //agent 翻书：请求带 read_textbook 工具，需要时导师按需读教材节追加上下文
      final result = await _chatWithTextbook(
        courseName: courseName,
        courseDir: courseDir,
        path: path,
        tutor: tutor,
        scene: '上课',
        messages: messages,
        label: '上课',
      );
      await _appendTutor(
        path,
        tutor,
        result.text,
        'teaching',
        reasoning: result.reasoningContent,
      );
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
      //agent 翻书（问候也可按需翻教材——如商定今日内容时查阅目录对应节）
      final result = await _chatWithTextbook(
        courseName: courseName,
        courseDir: courseDir,
        path: path,
        tutor: tutor,
        scene: '问候',
        messages: messages,
        label: '问候',
      );
      await _appendTutor(
        path,
        tutor,
        result.text,
        'teaching',
        reasoning: result.reasoningContent,
      );
      return result.text;
    } finally {
      _setBusy(courseName, '');
    }
  }

  // —— 场景 6+7：课后更新 → 导师群聊生成 ——
  //返回值告知 UI 课后更新是否完成（false = meta 保持 ongoing，可重新点击重跑场景 6）

  ///课后更新 → 群聊生成（失败跳过）。不再单独生成下课总结——
  ///真实对话中导师收尾时会自然总结，显式告别语与之重复（2026-09 实测）。
  ///onMessage：群聊消息逐条落档即回调，UI 逐条弹出用。
  ///抛出 = 更新失败；更新失败时 meta 保持 ongoing、下一课文件不创建。
  Future<void> endLesson({
    required String courseName,
    void Function(Map<String, dynamic> message)? onMessage,
  }) async {
    final lesson = await _storage.getCurrentLesson(courseName);
    final path = lesson['path'] as String;
    final tutor = lesson['tutor'] as String;
    final lessonNo = lesson['lesson'] as int;
    _setBusy(courseName, '整理课程进度中…'); //跨页面生成中状态（更新→群聊全程）

    try {
      final courseDir = await _courseDir(courseName);
      //课后更新（JSON 解析重试 1 次后仍失败 → 保持 ongoing）
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
        thinkingEffort: textThinkingEffort, //纯文本组全局档位（默认 low）
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
    //群聊生成：输入=本课对话，写档=本课文件尾（教学对话之后）；失败跳过，不阻塞课后更新其余成果
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
      final idx = rows.indexWhere((r) => r['name'] == name);
      final history = idx >= 0
          ? rows[idx]['records'] as List? ?? const []
          : const [];
      final block = <String, dynamic>{
        'status': status,
        'date': today,
        'review': _offsetReview(today, status, history),
      };
      final mistake = item['mistake'] as String?;
      if (status != '✓' && mistake != null && mistake.isNotEmpty) {
        block['mistake'] = mistake;
      }
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
      thinkingEffort: textThinkingEffort, //纯文本组全局档位
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
