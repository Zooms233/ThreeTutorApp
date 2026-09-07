import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

//组装层：把场景所需的提示词/档案/状态/教材/对话拼成 client 可用的 messages。
//system 按缓存顺序排列：①规则 → ②档案 → ③状态 → ④本次注入 → 对话历史（04-LLM调用.md）。
//IO 只发生在读取资源时；拼装本身为纯字符串运算。

///一条请求消息。role: system/user/assistant。
class PromptMessage {
  final String role;
  final String content;

  const PromptMessage(this.role, this.content);

  Map<String, String> toMap() => {'role': role, 'content': content};
}

class PromptBuilder {
  static const _promptsRoot = 'assets/prompts';
  static const _textbookLimit = 8000; //教材当前节截断上限

  // —— 提示词资产 ——

  Future<String> _prompt(String name) => rootBundle.loadString('$_promptsRoot/$name');

  // —— 资源读取 ——

  Future<Map<String, dynamic>> _readJson(String path) async {
    final file = File(path);
    if (!file.existsSync()) return {};
    return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> _readProgress(String path) async {
    final file = File(path);
    if (!file.existsSync()) return [];
    final rows = <Map<String, dynamic>>[];
    for (final line in await file.readAsLines()) {
      if (line.trim().isEmpty) continue;
      rows.add(jsonDecode(line) as Map<String, dynamic>);
    }
    return rows;
  }

  //课程内导师档案：完整路径 → 内容（key 用完整路径，_tutorFile 依赖它定位文件）
  Future<Map<String, Map<String, dynamic>>> _tutorProfiles(String courseDir) async {
    final dir = Directory(courseDir);
    final profiles = <String, Map<String, dynamic>>{};
    if (!dir.existsSync()) return profiles;
    await for (final e in dir.list()) {
      final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (e is File && name.startsWith('tutor_') && name.endsWith('.json')) {
        profiles[e.path] = await _readJson(e.path);
      }
    }
    return profiles;
  }

  // —— 档案与状态文本块 ——

  //身份声明：插在规则与档案之间，明确「你是哪位导师」（多档案场景防认错身份）
  String _identity(String tutorName) => '你是$tutorName。下面是你的档案：';

  String _tutorBlock(Map<String, dynamic> t) {
    final examples = (t['speech_examples'] as List?)?.join('\n') ?? '';
    final emotions = (t['emotions'] as List?)?.join('\n') ?? '';
    return [
      '【${t['name'] ?? ''}】',
      '身份：${t['identity'] ?? ''}',
      '性格特质：${t['traits'] ?? ''}',
      '外貌：${t['appearance'] ?? ''}',
      '性格与经历：${t['personality'] ?? ''}',
      '说话风格：${t['speech_style'] ?? ''}',
      if (examples.isNotEmpty) '说话示例：\n$examples',
      if (emotions.isNotEmpty) '情绪表达：\n$emotions',
      '与学习者的关系：${t['relation'] ?? ''}',
    ].join('\n');
  }

  String _learnerBlock(Map<String, dynamic> l) {
    return [
      '【学习者】',
      '称呼：${l['name'] ?? ''}',
      '身份：${l['identity'] ?? ''}',
      '学习动机：${l['motivation'] ?? ''}',
      '故事：${l['story'] ?? ''}',
      if ((l['extra'] as String? ?? '').isNotEmpty) '补充：${l['extra']}',
    ].join('\n');
  }

  String _stateBlock(Map<String, dynamic> state) {
    return [
      '【课程状态】',
      '当前讲授位置：${state['position'] ?? ''}',
      '下一节课授课导师：${state['next_tutor'] ?? ''}',
      '累计课时：${state['lessons'] ?? 0}',
      '最近上课日期：${state['last_date'] ?? ''}',
    ].join('\n');
  }

  //教学用：知识点清单（短名 + 最新状态块）
  String _progressBlock(List<Map<String, dynamic>> rows) {
    if (rows.isEmpty) return '【知识点进度】\n（暂无，尚未登记任何知识点）';
    final lines = <String>[];
    for (final row in rows) {
      final records = row['records'] as List? ?? const [];
      final latest = records.isNotEmpty ? records.last as Map<String, dynamic> : null;
      if (latest == null) continue;
      final status = latest['status'] ?? '?';
      final date = latest['date'] ?? '';
      final mistakeText = latest['mistake'] as String?;
      lines.add('$status ${row['name']}（最近 $date${mistakeText != null && mistakeText.isNotEmpty ? '，错因：$mistakeText' : ''}）');
    }
    return ['【知识点进度】', ...lines].join('\n');
  }

  //课后更新用：现有知识点短名清单（供 LLM 沿用短名，不重命名）
  String _progressNamesBlock(List<Map<String, dynamic>> rows) {
    final names = rows.map((r) => r['name']).whereType<String>().toList();
    return '【现有知识点】\n${names.isEmpty ? '（暂无）' : names.join('、')}';
  }

  // —— 教材当前节（④）——

  //标题行 →（# 数量，标题文本）
  (int, String) _headingInfo(String line) {
    final s = line.trim();
    var n = 0;
    var rest = s;
    while (rest.startsWith('#')) {
      n++;
      rest = rest.substring(1);
    }
    return (n, rest.trim());
  }

  //position 格式：TEXTBOOK/文件名.md > 节标题；取节标题行到下一个同级标题行之间的内容
  Future<String?> _textbookBlock(String courseDir, Object? position) async {
    final pos = position as String? ?? '';
    if (pos.isEmpty) return null;
    final sep = pos.indexOf(' > ');
    if (sep < 0) return null;
    final fileRel = pos.substring(0, sep).replaceFirst('TEXTBOOK/', '');
    final section = pos.substring(sep + 3).trim();
    if (fileRel.isEmpty || section.isEmpty) return null;

    final file = File('$courseDir/TEXTBOOK/$fileRel');
    if (!file.existsSync()) return null;
    final lines = await file.readAsLines();

    int? start;
    var level = 0;
    for (var i = 0; i < lines.length; i++) {
      if (!lines[i].trim().startsWith('#')) continue;
      final (hashes, title) = _headingInfo(lines[i]);
      if (start == null) {
        if (title == section || title.contains(section)) {
          start = i;
          level = hashes;
        }
      } else if (hashes <= level) {
        break; //下一个同级或更高级标题 → 本节结束
      }
    }
    if (start == null) return null;

    var end = lines.length;
    for (var i = start + 1; i < lines.length; i++) {
      if (!lines[i].trim().startsWith('#')) continue;
      final (hashes, _) = _headingInfo(lines[i]);
      if (hashes <= level) {
        end = i;
        break;
      }
    }
    var body = lines.sublist(start, end).join('\n').trim();
    if (body.length > _textbookLimit) {
      body = '${body.substring(0, _textbookLimit)}\n……本节内容过长，已截断';
    }
    return '今日教材进度：$pos\n$body';
  }

  // —— CHAT 历史映射 ——

  //meta 行不映射；user→user（time 并入头部）、tutor→assistant，原文原样；连续 user 合并（\n）
  //message 行映射：meta 不映射（其余字段如 auto 标记渲染/映射均忽略）
  Future<List<PromptMessage>> _mapHistory(String chatPath) async {
    final file = File(chatPath);
    if (!file.existsSync()) return [];
    final mapped = <PromptMessage>[];
    for (final line in await file.readAsLines()) {
      if (line.trim().isEmpty) continue;
      final row = jsonDecode(line) as Map<String, dynamic>;
      if (row['type'] != 'message') continue; //meta 不映射
      final isUser = row['role'] == 'user';
      var content = row['content'] as String? ?? '';
      if (isUser) {
        final time = row['time'] as String?;
        if (time != null && time.length >= 16) {
          content = '[${time.substring(5, 16)}] $content'; //MM-DD HH:mm，跨天节奏锚点
        }
      }
      final role = isUser ? 'user' : 'assistant';
      if (mapped.isNotEmpty && mapped.last.role == 'user' && role == 'user') {
        mapped[mapped.length - 1] = PromptMessage('user', '${mapped.last.content}\n$content');
      } else {
        mapped.add(PromptMessage(role, content));
      }
    }
    return mapped;
  }

  List<Map<String, String>> _compose(String system, List<PromptMessage> history) {
    return [
      {'role': 'system', 'content': system},
      ...history.map((m) => m.toMap()),
    ];
  }

  //system 尾部拼装工具：非空段以空行连接
  String _join(List<String?> parts) => parts.whereType<String>().where((s) => s.isNotEmpty).join('\n\n');

  // —— 场景拼装 ——

  ///教学（上课对话 / 课前问候 / 下课总结）：全量注入。
  ///dispatch 非空时（课前问候/下课总结）追加一条 user 调度指令，不写入 CHAT。
  Future<List<Map<String, String>>> teaching({
    required String courseDir,
    required String chatPath,
    required String tutorName,
    String? dispatch,
  }) async {
    final rule = await _prompt('teaching.md');
    final tutorFile = await _tutorFile(courseDir, tutorName);
    final tutor = tutorFile != null ? await _readJson(tutorFile.path) : <String, dynamic>{};
    final learner = await _readJson('$courseDir/LEARNER.json');
    final state = await _readJson('$courseDir/STATE.json');
    final progress = await _readProgress('$courseDir/PROGRESS.jsonl');
    final today = DateTime.now();
    final date = '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';

    final system = _join([
      rule,
      _identity(tutorName),
      _tutorBlock(tutor),
      _learnerBlock(learner),
      _stateBlock(state),
      _progressBlock(progress),
      '今天是$date。',
      await _textbookBlock(courseDir, state['position']),
    ]);
    final history = await _mapHistory(chatPath);
    if (dispatch != null && dispatch.isNotEmpty) {
      history.add(PromptMessage('user', dispatch));
    }
    return _compose(system, history);
  }

  ///问答（idle 期，含建课后首聊）：问答规则 + next_tutor 档案 + 学习者档案 + 教材；不注入状态与日期。
  ///写入目标为下一课文件（新开课区间的交流段），群聊总在上一课文件尾，历史天然不含群聊。
  Future<List<Map<String, String>>> qa({
    required String courseDir,
    required String chatPath,
    required String tutorName,
  }) async {
    final rule = await _prompt('qa.md');
    final tutorFile = await _tutorFile(courseDir, tutorName);
    final tutor = tutorFile != null ? await _readJson(tutorFile.path) : <String, dynamic>{};
    final learner = await _readJson('$courseDir/LEARNER.json');
    final state = await _readJson('$courseDir/STATE.json');

    final system = _join([
      rule,
      _identity(tutorName),
      _tutorBlock(tutor),
      _learnerBlock(learner),
      await _textbookBlock(courseDir, state['position']),
    ]);
    return _compose(system, await _mapHistory(chatPath));
  }

  ///聊天（idle + toggle 激活）：聊天规则 + 三位导师档案；不注入状态、日期与教材。
  ///chatPath 由调用方指向群聊讨论的落档文件（本课文件尾，含教学全程与群聊），历史即该文件全量。
  Future<List<Map<String, String>>> social({
    required String courseDir,
    required String chatPath,
  }) async {
    final rule = await _prompt('social.md');
    final profiles = await _tutorProfiles(courseDir);
    final blocks = profiles.values.map(_tutorBlock).toList();

    final system = _join([rule, ...blocks]);
    return _compose(system, await _mapHistory(chatPath));
  }

  ///「其他」字段提炼（关系页编辑入口按钮，非对话场景）：
  ///提炼规则作 system，最近课次留档全文作 user 消息。
  ///不注入导师身份/学习者档案——避免用旧 extra 与单一导师视角影响提炼。
  Future<List<Map<String, String>>> learnerExtra({required String chatPath}) async {
    final rule = await _prompt('learner_extra.md');
    final history = await File(chatPath).readAsString();
    return _compose(rule, [PromptMessage('user', history)]);
  }

  ///导师群聊生成（课后更新完成后自动）：群聊规范 + 三位导师档案 + 本课对话 + 调度指令。
  Future<List<Map<String, String>>> groupChat({
    required String courseDir,
    required String chatPath,
    String? dispatch,
  }) async {
    final rule = await _prompt('group.md');
    final profiles = await _tutorProfiles(courseDir);
    final blocks = profiles.values.map(_tutorBlock).toList();

    final system = _join([rule, ...blocks]);
    final history = await _mapHistory(chatPath);
    if (dispatch != null && dispatch.isNotEmpty) {
      history.add(PromptMessage('user', dispatch));
    }
    return _compose(system, history);
  }

  ///课后更新：更新指令（含 PROGRESS 规范）+ 现有知识点清单 + 本课导师档案 + 本课对话。
  Future<List<Map<String, String>>> update({
    required String courseDir,
    required String chatPath,
    required String tutorName,
  }) async {
    final rule = await _prompt('update.md');
    final tutorFile = await _tutorFile(courseDir, tutorName);
    final tutor = tutorFile != null ? await _readJson(tutorFile.path) : <String, dynamic>{};
    final progress = await _readProgress('$courseDir/PROGRESS.jsonl');

    final system = _join([
      rule.replaceAll('{导师名}', tutorName),
      _progressNamesBlock(progress),
      _tutorBlock(tutor),
    ]);
    return _compose(system, await _mapHistory(chatPath));
  }

  //按档案内 name 字段定位课程内档案文件（tutor_a/b/c.json）
  Future<File?> _tutorFile(String courseDir, String tutorName) async {
    final profiles = await _tutorProfiles(courseDir);
    for (final entry in profiles.entries) {
      if (entry.value['name'] == tutorName) return File(entry.key);
    }
    return null;
  }
}
