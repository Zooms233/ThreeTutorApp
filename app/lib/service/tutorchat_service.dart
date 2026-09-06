import 'dart:convert';
import 'dart:io';

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

  TutorChatService({StorageService? storage, PromptBuilder? prompts, LlmClient? client})
      : _storage = storage ?? StorageService(),
        _prompts = prompts ?? PromptBuilder(),
        _client = client ?? LlmClient();

  // —— 基础 ——

  Future<LlmConfig> _config() async => LlmConfig.fromMap(await _storage.loadConfig());

  Future<String> _courseDir(String courseName) async => (await _storage.getCourseDir(courseName)).path;

  String _today() {
    final n = DateTime.now();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }

  String _now() {
    final n = DateTime.now();
    return '${_today()} ${n.hour.toString().padLeft(2, '0')}:${n.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _appendUser(String path, String name, String content, String phase) =>
      _storage.appendChatMessage(path, {
        'type': 'message',
        'phase': phase,
        'role': 'user',
        'name': name,
        'time': _now(),
        'content': content,
      });

  Future<void> _appendTutor(String path, String name, String content, String phase) =>
      _storage.appendChatMessage(path, {
        'type': 'message',
        'phase': phase,
        'role': 'tutor',
        'name': name,
        'content': content,
      });

  //课程内全部导师名（tutor_*.json 的 name 字段）
  Future<List<String>> _tutorNames(String courseDir) async {
    final names = <String>[];
    for (final e in Directory(courseDir).listSync()) {
      final base = e.path.split(Platform.pathSeparator).last;
      if (e is File && base.startsWith('tutor_') && base.endsWith('.json')) {
        final name = (jsonDecode(await e.readAsString()) as Map<String, dynamic>)['name'] as String?;
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
  (String, String) _parseReplyLine(String line, List<String> tutorNames, String fallback) {
    final pattern = RegExp('^(${tutorNames.map(RegExp.escape).join('|')})[::]\\s*(.*)\$');
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
  Future<String> judgeFlow(String courseName, {required bool toggleActive}) async {
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
    final lesson = await _storage.getCurrentLesson(courseName);
    final path = lesson['path'] as String;
    final meta = jsonDecode((await File(path).readAsLines()).first) as Map<String, dynamic>;
    final responder = meta['tutor'] as String? ?? '导师'; //问答=next_tutor；聊天前缀未命中时的回退
    final learner = await _storage.loadCourseLearner(courseName);
    final userName = learner['name'] as String? ?? '学习者';
    final phase = social ? 'social' : 'qa';

    await _appendUser(path, userName, content, phase);

    final courseDir = await _courseDir(courseName);
    final messages = social
        ? await _prompts.social(courseDir: courseDir, chatPath: path)
        : await _prompts.qa(courseDir: courseDir, chatPath: path, tutorName: responder);

    final result = await _client.chat(config: await _config(), messages: messages, stream: true);

    final (name, text) = social
        ? _parseReplyLine(result.text, await _tutorNames(courseDir), responder)
        : (responder, result.text.trim());
    await _appendTutor(path, name, text, phase);
    return (name, text);
  }

  // —— 场景 2：上课对话（ongoing + 用户消息）——

  ///先写后说（phase=teaching）→ 教学全量拼装（无调度指令）→ 流式生成 → 写档。
  ///返回 (本课导师名, 回复全文)。
  Future<(String, String)> sendLessonMessage({
    required String courseName,
    required String content,
  }) async {
    final lesson = await _storage.getCurrentLesson(courseName);
    final path = lesson['path'] as String;
    final meta = jsonDecode((await File(path).readAsLines()).first) as Map<String, dynamic>;
    if (meta['status'] != 'ongoing') throw LlmException('非上课状态（meta=${meta['status']}），无法走上课对话');
    final tutor = meta['tutor'] as String? ?? '导师';
    final learner = await _storage.loadCourseLearner(courseName);
    final userName = learner['name'] as String? ?? '学习者';

    await _appendUser(path, userName, content, 'teaching');
    final courseDir = await _courseDir(courseName);
    final messages = await _prompts.teaching(courseDir: courseDir, chatPath: path, tutorName: tutor);
    final result = await _client.chat(config: await _config(), messages: messages, stream: true);
    await _appendTutor(path, tutor, result.text, 'teaching');
    return (tutor, result.text);
  }

  // —— 场景 4：课前问候（「开始上课」按钮）——

  ///meta idle→ongoing → 拼装（含问候调度指令）→ 流式生成 → 写档 phase=teaching。
  ///失败：重试耗尽后 meta 保持 ongoing，抛出（用户直接发消息即走上课对话自然恢复）。
  Future<String> startLesson({required String courseName}) async {
    final lesson = await _storage.getCurrentLesson(courseName);
    final path = lesson['path'] as String;
    final tutor = lesson['tutor'] as String;
    await _storage.patchChatMeta(path, {'status': 'ongoing'});

    final courseDir = await _courseDir(courseName);
    final dispatch = await rootBundle.loadString('assets/prompts/dispatch_greeting.md');
    final messages = await _prompts.teaching(
      courseDir: courseDir,
      chatPath: path,
      tutorName: tutor,
      dispatch: dispatch,
    );
    final result = await _client.chat(config: await _config(), messages: messages, stream: true);
    await _appendTutor(path, tutor, result.text, 'teaching');
    return result.text;
  }

  // —— 场景 5+6+7：下课总结 → 课后更新 → 导师群聊生成 ——
  //返回值告知 UI 课后更新是否完成（false = meta 保持 ongoing，可重新点击重跑场景 5+6）

  ///下课总结（含调度指令）→ 落档后自动课后更新 → 群聊生成（失败跳过）。
  ///抛出 = 总结或更新失败；更新失败时 meta 保持 ongoing、下一课文件不创建。
  Future<void> endLesson({required String courseName}) async {
    final lesson = await _storage.getCurrentLesson(courseName);
    final path = lesson['path'] as String;
    final tutor = lesson['tutor'] as String;
    final lessonNo = lesson['lesson'] as int;

    //下课总结（meta 仍 ongoing）
    final courseDir = await _courseDir(courseName);
    final dispatch = await rootBundle.loadString('assets/prompts/dispatch_summary.md');
    final messages = await _prompts.teaching(
      courseDir: courseDir,
      chatPath: path,
      tutorName: tutor,
      dispatch: dispatch,
    );
    final result = await _client.chat(config: await _config(), messages: messages, stream: true);
    await _appendTutor(path, tutor, result.text, 'teaching');

    //总结落档 → 课后更新（JSON 解析重试 1 次后仍失败 → 保持 ongoing）
    final updated = await _postLessonUpdate(courseName, courseDir, path, tutor, lessonNo);
    if (!updated) {
      throw LlmException('课后更新失败：meta 保持 ongoing，可重新点击「今天就到这里」重跑');
    }
  }

  //课后更新：更新指令 + PROGRESS 规范 + 现有清单 + 本课导师档案 + 对话；jsonMode 非流式
  Future<bool> _postLessonUpdate(
    String courseName,
    String courseDir,
    String lessonPath,
    String tutorName,
    int lessonNo,
  ) async {
    Map<String, dynamic>? output;
    for (var attempt = 0; attempt < 2; attempt++) {
      final messages =
          await _prompts.update(courseDir: courseDir, chatPath: lessonPath, tutorName: tutorName);
      final result = await _client.chat(
        config: await _config(),
        messages: messages,
        stream: false,
        jsonMode: true,
      );
      try {
        output = _extractJson(result.text);
        break;
      } on FormatException {
        if (attempt == 1) return false; //重试后仍解析失败
      }
    }
    //写档五步；返回创建的下一课文件路径（群聊生成写档目标）
    final nextPath = await _applyLessonUpdate(courseName, courseDir, lessonPath, tutorName, lessonNo, output!);
    //群聊生成：输入=本课对话，写档=下一课文件头；失败跳过，不阻塞课后更新其余成果
    try {
      await _generateGroupChat(courseDir, lessonPath, nextPath);
    } catch (_) {}
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
      if (status != '✓' && mistake != null && mistake.isNotEmpty) block['mistake'] = mistake;
      final idx = rows.indexWhere((r) => r['name'] == name);
      if (idx >= 0) {
        final row = rows[idx];
        row['records'] = [...(row['records'] as List? ?? const []), block];
        rows[idx] = row;
      } else {
        rows.add({'name': name, 'records': [block]});
      }
    }
    final progressText = rows.map(jsonEncode).join('\n');
    await File('$courseDir/PROGRESS.jsonl').writeAsString('$progressText\n');

    //3. relation：与现文有差异才重写本课导师档案
    final relation = output['relation'] as String?;
    if (relation != null && relation.isNotEmpty) {
      final tutorFile = await _tutorFile(courseDir, tutorName);
      if (tutorFile != null) {
        final data = jsonDecode(await tutorFile.readAsString()) as Map<String, dynamic>;
        if (data['relation'] != relation) {
          data['relation'] = relation;
          await tutorFile.writeAsString(jsonEncode(data));
        }
      }
    }

    //4. 本课 meta：status→ended、date→实际完成日（lesson/tutor 保持）
    await _storage.patchChatMeta(lessonPath, {'status': 'ended', 'date': today});

    //5. 创建下一课文件（idle 预填，tutor=轮换后）
    return _storage.createLessonFile(courseName, lessonNo + 1, nextTutor);
  }

  //场景 7：导师群聊生成（聊天职责的自动版）——解析前缀逐条写档，写入下一课文件头
  Future<void> _generateGroupChat(String courseDir, String chatPath, String targetPath) async {
    final dispatch = await rootBundle.loadString('assets/prompts/dispatch_group.md');
    final messages = await _prompts.groupChat(courseDir: courseDir, chatPath: chatPath, dispatch: dispatch);
    final result = await _client.chat(config: await _config(), messages: messages, stream: true);
    final names = await _tutorNames(courseDir);
    //未命中导师名 → name 取 meta.tutor（本课导师，04 规定）
    final meta = jsonDecode((await File(chatPath).readAsLines()).first) as Map<String, dynamic>;
    final fallback = meta['tutor'] as String? ?? (names.isNotEmpty ? names.first : '导师');
    for (final line in result.text.split('\n')) {
      if (line.trim().isEmpty) continue;
      final (name, content) = _parseReplyLine(line, names, fallback);
      if (content.isEmpty) continue;
      await _storage.appendChatMessage(targetPath, {
        'type': 'message',
        'phase': 'social',
        'role': 'tutor',
        'name': name,
        'content': content,
      });
    }
  }
}
