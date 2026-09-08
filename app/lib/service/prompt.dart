import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

//组装层：把场景所需的提示词/档案/状态/教材/对话拼成 client 可用的 messages。
//system 按缓存顺序排列：①规则 → ②档案 → ③状态 → ④本次注入 → 对话历史（04-LLM调用.md）。
//IO 只发生在读取资源时；拼装本身为纯字符串运算。

///一条请求消息。role: system/user/assistant/tool。
class PromptMessage {
  final String role;
  final String? content; //null 仅用于带 tool_calls 的 assistant 消息（OpenAI 约定）
  final List<Map<String, dynamic>>? toolCalls; //assistant 的 tool_calls 数组（agent 翻书）；无则 null
  final String? toolCallId; //tool 消息的 tool_call_id

  const PromptMessage(this.role, [this.content, this.toolCalls, this.toolCallId]);

  Map<String, dynamic> toMap() => {
        'role': role,
        if (content != null) 'content': content,
        if (toolCalls != null) 'tool_calls': toolCalls,
        if (toolCallId != null) 'tool_call_id': toolCallId,
      };
}

const _textbookLimit = 8000; //教材当前节截断上限（注入与物化共用）
const _syllabusLimit = 4000; //教学大纲截断上限（大纲通常短，全文注入）

//教材按需载入的公共工具：切节/物化/@read 解析。
//物化与翻书回填共用同一模板与同一读盘路径——两处字节级一致是前缀命中的关键（doc/04）。

//切节：节标题行到下一个同级/更高级标题行之间（含子级标题内容）；未命中返回 null
String? readTextbookSection(String courseDir, String file, String section) {
  final fh = File('$courseDir/TEXTBOOK/$file');
  if (!fh.existsSync()) return null;
  final lines = fh.readAsLinesSync();

  int? start;
  var level = 0;
  for (var i = 0; i < lines.length; i++) {
    if (!lines[i].trim().startsWith('#')) continue;
    final (hashes, title) = _headingInfoOf(lines[i]);
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
    final (hashes, _) = _headingInfoOf(lines[i]);
    if (hashes <= level) {
      end = i;
      break;
    }
  }
  return lines.sublist(start, end).join('\n').trim();
}

//标题行 →（# 数量，标题文本）
(int, String) _headingInfoOf(String line) {
  final s = line.trim();
  var n = 0;
  var rest = s;
  while (rest.startsWith('#')) {
    n++;
    rest = rest.substring(1);
  }
  return (n, rest.trim());
}

//教材物化模板：历史重放物化（_mapHistory）与翻书回填（service）共用——禁止两处手写
String textbookMaterialization(String file, String section, String body) =>
    '【教材 · $file > $section】\n$body';

//物化一条：读盘→截断→模板，一条龙；未命中返回 null（重放时跳过该指针）
String? materializeTextbookSection(
  String courseDir,
  String file,
  String section,
) {
  final body = readTextbookSection(courseDir, file, section);
  if (body == null) return null;
  var trimmed = body;
  if (trimmed.length > _textbookLimit) {
    trimmed = '${trimmed.substring(0, _textbookLimit)}\n……本节内容过长，已截断';
  }
  return textbookMaterialization(file, section, trimmed);
}

//导师档案注入档位：full=教学/问答全量；light=聊天/群聊轻量；minimal=课后更新精简
enum _TutorBlockLevel { full, light, minimal }

class PromptBuilder {
  static const _promptsRoot = 'assets/prompts';

  // —— 提示词资产 ——

  Future<String> _prompt(String name) =>
      rootBundle.loadString('$_promptsRoot/$name');

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
  Future<Map<String, Map<String, dynamic>>> _tutorProfiles(
    String courseDir,
  ) async {
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

  //档案注入档位：教学/问答全量；聊天/群聊轻量（省性格与动机——群聊只需语气区分度）；
  //课后更新精简（保性格与动机供 relation 演进判断，省风格示例）。
  //聊天/群聊/更新为独立请求不命中缓存，裁剪直接省 token
  String _tutorBlock(
    Map<String, dynamic> t, {
    _TutorBlockLevel level = _TutorBlockLevel.full,
  }) {
    final light = level == _TutorBlockLevel.light;
    final minimal = level == _TutorBlockLevel.minimal;
    final examples = (t['speech_examples'] as List?)?.join('\n') ?? '';
    return [
      '【${t['name'] ?? ''}】',
      '身份：${t['identity'] ?? ''}',
      '性格特质：${t['traits'] ?? ''}',
      if (!light) '性格与动机：${t['personality'] ?? ''}', //轻量档省略（群聊只需语气区分度）
      '说话风格：${t['speech_style'] ?? ''}',
      if (!minimal && examples.isNotEmpty) '说话示例：\n$examples',
      '与学习者的关系：${t['relation'] ?? ''}',
    ].join('\n');
  }

  String _learnerBlock(Map<String, dynamic> l) {
    return [
      '【学习者】',
      '称呼：${l['name'] ?? ''}',
      '学习动机：${l['motivation'] ?? ''}',
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
      final latest = records.isNotEmpty
          ? records.last as Map<String, dynamic>
          : null;
      if (latest == null) continue;
      final status = latest['status'] ?? '?';
      final date = latest['date'] ?? '';
      final mistakeText = latest['mistake'] as String?;
      lines.add(
        '$status ${row['name']}（最近 $date${mistakeText != null && mistakeText.isNotEmpty ? '，错因：$mistakeText' : ''}）',
      );
    }
    return ['【知识点进度】', ...lines].join('\n');
  }

  //课后更新用：现有知识点短名清单（供 LLM 沿用短名，不重命名）
  String _progressNamesBlock(List<Map<String, dynamic>> rows) {
    final names = rows.map((r) => r['name']).whereType<String>().toList();
    return '【现有知识点】\n${names.isEmpty ? '（暂无）' : names.join('、')}';
  }

  // —— 教学范围与材料（④）——
  //OUTLINE/=教学范围（大纲，短，全文注入）；TEXTBOOK/=教学材料（参考数据库，长，read 按需查阅）。

  //文本文件判定（目录/read 只认可读文本；docx/pdf 等二进制不纳入，避免乱码注入）
  static bool _isTextFile(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.md') ||
        lower.endsWith('.markdown') ||
        lower.endsWith('.txt') ||
        lower.endsWith('.text') ||
        lower.endsWith('.log');
  }

  //教学范围：OUTLINE/ 下文件全文注入（标注【教学范围】；大纲通常短，模型以此定教学主线）
  Future<String?> _syllabusBlock(String courseDir) async {
    final dir = Directory('$courseDir/OUTLINE');
    if (!dir.existsSync()) return null;
    final files =
        dir
            .listSync()
            .whereType<File>()
            .where((e) => _isTextFile(e.path))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    if (files.isEmpty) return null;
    final parts = <String>[];
    for (final f in files) {
      var text = await f.readAsString();
      if (text.length > _syllabusLimit) {
        text = '${text.substring(0, _syllabusLimit)}\n……大纲内容过长，已截断';
      }
      parts.add('【教学范围 · ${f.uri.pathSegments.last}】\n$text');
    }
    return parts.join('\n\n');
  }

  //教学材料目录：OUTLINE/ + TEXTBOOK/ 全部文本文件的「标题 + 起始行号」清单
  //（read 工具的行号寻址簿；无标题文件按 200 行一段列块）。
  Future<String?> _materialToc(String courseDir) async {
    final entries = <String>[];
    for (final sub in const ['OUTLINE', 'TEXTBOOK']) {
      final dir = Directory('$courseDir/$sub');
      if (!dir.existsSync()) continue;
      final files =
          dir
              .listSync()
              .whereType<File>()
              .where((e) => _isTextFile(e.path))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      if (files.isEmpty) continue;
      for (final f in files) {
        final name = f.uri.pathSegments.last;
        final rel = '$sub/$name';
        final lines = await f.readAsLines();
        entries.add('- $rel（共 ${lines.length} 行）');
        //标题行 + 行号（限制条数防目录过大）
        final headingLines = <String>[];
        for (var i = 0; i < lines.length && headingLines.length < 200; i++) {
          if (!lines[i].trim().startsWith('#')) continue;
          final (_, title) = _headingInfoOf(lines[i]);
          if (title.isEmpty) continue;
          headingLines.add('  · $title …… 第 ${i + 1} 行');
        }
        if (headingLines.isEmpty) {
          //无标题：按 200 行一段列块（read 用 offset 定位）
          final blocks = (lines.length + 199) ~/ 200;
          for (var b = 0; b < blocks && b < 50; b++) {
            final start = b * 200 + 1;
            final end = start + 199 > lines.length ? lines.length : start + 199;
            entries.add('  · 第${b + 1}段（$start-$end 行）…… 第 $start 行');
          }
        } else {
          entries.addAll(headingLines);
        }
      }
    }
    if (entries.isEmpty) return null;
    return ['【教学材料目录】', ...entries].join('\n');
  }

  //position →（相对路径, 起始行, 结束行[含]）；找不到返回 null。
  //支持旧格式「TEXTBOOK/xxx.md > 节标题」与纯标题（在全部材料里模糊匹配）。
  Future<(String, int, int)?> _resolvePosition(
    String courseDir,
    String pos,
  ) async {
    final sep = pos.indexOf(' > ');
    if (sep >= 0) {
      final fileRel = pos.substring(0, sep).trim();
      final section = pos.substring(sep + 3).trim();
      if (fileRel.isEmpty || section.isEmpty) return null;
      return _headingRange(courseDir, fileRel, section);
    }
    for (final sub in const ['OUTLINE', 'TEXTBOOK']) {
      final dir = Directory('$courseDir/$sub');
      if (!dir.existsSync()) continue;
      final files =
          dir
              .listSync()
              .whereType<File>()
              .where((e) => _isTextFile(e.path))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      for (final f in files) {
        final rel = '$sub/${f.uri.pathSegments.last}';
        final r = await _headingRange(courseDir, rel, pos);
        if (r != null) return r;
      }
    }
    return null;
  }

  //在某文件按标题（全等或包含）定位行范围：标题行 → 下一个同级/更高级标题前
  Future<(String, int, int)?> _headingRange(
    String courseDir,
    String rel,
    String title,
  ) async {
    final file = File('$courseDir/$rel');
    if (!file.existsSync()) return null;
    final lines = await file.readAsLines();
    int? start;
    var level = 0;
    for (var i = 0; i < lines.length; i++) {
      if (!lines[i].trim().startsWith('#')) continue;
      final (hashes, t) = _headingInfoOf(lines[i]);
      if (start == null) {
        if (t == title || t.contains(title)) {
          start = i;
          level = hashes;
        }
      } else if (hashes <= level) {
        return (rel, start + 1, i); //下一个同级/更高级标题 → 本节结束
      }
    }
    if (start == null) return null;
    return (rel, start + 1, lines.length);
  }

  //按行范围读正文（1 起始，含 end）
  Future<String?> _readLines(
    String courseDir,
    String rel,
    int startLine,
    int endLine,
  ) async {
    final file = File('$courseDir/$rel');
    if (!file.existsSync()) return null;
    final lines = await file.readAsLines();
    if (startLine < 1 || startLine > lines.length) return null;
    final end = endLine > lines.length ? lines.length : endLine;
    return lines.sublist(startLine - 1, end).join('\n');
  }

  //今日教学位置：position 对应内容全文（按行读，超长截断）+ 目录（read 寻址簿）。
  //position 找不到时仍返回目录——目录是翻书寻址依据，必须可靠在场；仅目录模式传 withBody=false。
  Future<String?> _textbookBlock(
    String courseDir,
    Object? position, {
    bool withBody = true,
  }) async {
    if (!withBody) return _materialToc(courseDir);
    final pos = position as String? ?? '';
    final toc = await _materialToc(courseDir);
    if (pos.isEmpty) return toc;
    final hit = await _resolvePosition(courseDir, pos);
    if (hit == null) return toc;
    final body = await _readLines(courseDir, hit.$1, hit.$2, hit.$3);
    if (body == null) return toc;
    var trimmed = body;
    if (trimmed.length > _textbookLimit) {
      trimmed = '${trimmed.substring(0, _textbookLimit)}\n……本节内容过长，已截断';
    }
    return ['今日教材进度：$pos\n$trimmed', ?toc].join('\n\n');
  }

  // —— agent 翻书工具（通用 read，对齐 pi）——
  //只按行读取（path + offset/limit），不做任何格式解析——兼容任意文本教材；
  //行号寻址依据来自【教学材料目录】。static 常量保证各场景请求字节级一致。
  static const readToolDefs = [
    {
      'type': 'function',
      'function': {
        'name': 'read',
        'description': '读取教学材料或教学大纲中指定文件的某段内容并追加到对话。文件清单与行号范围见【教学材料目录】（没有目录或找不到文件时不要调用）。只读取目录中列出的文件。',
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {'type': 'string', 'description': '目录中的文件路径，如 TEXTBOOK/细胞生物学学习指南.md 或 OUTLINE/教学大纲.md'},
            'offset': {'type': 'integer', 'description': '起始行号（从 1 开始；省略则从文件开头）'},
            'limit': {'type': 'integer', 'description': '读取行数（默认 200，最多 500）'},
          },
          'required': ['path'],
        },
      },
    },
  ];

  //执行 read 工具：按行读取 → 截断 → 模板；未找到/参数非法返回 null（由调用方给错误提示）
  static String? executeReadTool(
    String courseDir,
    String path,
    int? offset,
    int? limit,
  ) {
    final file = File('$courseDir/$path');
    if (!file.existsSync()) return null;
    final lines = file.readAsLinesSync();
    if (lines.isEmpty) return null;
    final start = (offset ?? 1) - 1;
    if (start < 0 || start >= lines.length) return null;
    final n = limit ?? 200;
    final end = start + n > lines.length ? lines.length : start + n;
    var body = lines.sublist(start, end).join('\n');
    if (body.length > _textbookLimit) {
      body = '${body.substring(0, _textbookLimit)}\n……内容过长，已截断';
    }
    return '【教材 · $path 第 ${start + 1}-$end 行】\n$body';
  }


// —— CHAT 历史映射 ——

  //meta 行不映射；textbook 指针行物化为 user 消息（读盘现展开——同一指针 + 教材未改则字节级一致，
  //前缀命中沿历史延伸）；user→user（time 并入头部）、tutor→assistant，原文原样（含 @read 行）；
  //连续 user 合并（\n）
  Future<List<PromptMessage>> _mapHistory(
    String courseDir,
    String chatPath,
  ) async {
    final file = File(chatPath);
    if (!file.existsSync()) return [];
    final mapped = <PromptMessage>[];
    for (final line in await file.readAsLines()) {
      if (line.trim().isEmpty) continue;
      final row = jsonDecode(line) as Map<String, dynamic>;
      if (row['type'] == 'textbook') {
        final mat = materializeTextbookSection(
          courseDir,
          row['file'] as String? ?? '',
          row['section'] as String? ?? '',
        );
        if (mat != null) mapped.add(PromptMessage('user', mat));
        continue; //指针行本身不映射（物化消息替它登场）
      }
      if (row['type'] == 'tool_call') {
        //agent 翻书中间轮：assistant（content=null + tool_calls 原样）
        //——与首轮请求的 assistant 消息字节级一致，缓存前缀延续
        final toolCalls = (row['tool_calls'] as List<dynamic>?)
            ?.map((e) => e as Map<String, dynamic>)
            .toList();
        mapped.add(PromptMessage('assistant', null, toolCalls, null));
        continue;
      }
      if (row['type'] == 'tool') {
        //tool 消息：优先用行内快照 content（执行失败场景），否则按指针物化读盘
        //（成功场景只存指针不存正文——材料未改则物化结果与首轮一致，缓存延续）
        //新格式指针 = path/offset/limit（通用 read）；旧格式 = file/section（read_textbook）
        final snap = row['content'] as String?;
        String? content = snap;
        if (content == null) {
          final path = row['path'] as String?;
          if (path != null) {
            content = PromptBuilder.executeReadTool(
              courseDir,
              path,
              row['offset'] as int?,
              row['limit'] as int?,
            );
          } else {
            //旧格式指针（read_textbook 遗留）：走标题切节物化（materializeTextbookSection 仍保留）
            content = materializeTextbookSection(
              courseDir,
              row['file'] as String? ?? '',
              row['section'] as String? ?? '',
            );
          }
          content ??= '【教材】内容已不可用（文件可能被移除）';
        }
        mapped.add(
          PromptMessage('tool', content, null, row['tool_call_id'] as String?),
        );
        continue;
      }
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
        mapped[mapped.length - 1] = PromptMessage(
          'user',
          '${mapped.last.content}\n$content',
        );
      } else {
        mapped.add(PromptMessage(role, content));
      }
    }
    return mapped;
  }

  List<Map<String, dynamic>> _compose(
    String system,
    List<PromptMessage> history,
  ) {
    return [
      {'role': 'system', 'content': system},
      ...history.map((m) => m.toMap()),
    ];
  }

  //system 尾部拼装工具：非空段以空行连接
  String _join(List<String?> parts) =>
      parts.whereType<String>().where((s) => s.isNotEmpty).join('\n\n');

  // —— 场景拼装 ——

  ///教学（上课对话 / 课前问候 / 下课总结）：全量注入。
  ///dispatch 非空时（课前问候/下课总结）追加一条 user 调度指令，不写入 CHAT。
  Future<List<Map<String, dynamic>>> teaching({
    required String courseDir,
    required String chatPath,
    required String tutorName,
    String? dispatch,
  }) async {
    final rule = await _prompt('teaching.md');
    final tutorFile = await _tutorFile(courseDir, tutorName);
    final tutor = tutorFile != null
        ? await _readJson(tutorFile.path)
        : <String, dynamic>{};
    final learner = await _readJson('$courseDir/LEARNER.json');
    final state = await _readJson('$courseDir/STATE.json');
    final progress = await _readProgress('$courseDir/PROGRESS.jsonl');
    final today = DateTime.now();
    final date =
        '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';

    final system = _join([
      rule,
      _identity(tutorName),
      _tutorBlock(tutor),
      _learnerBlock(learner),
      _stateBlock(state),
      _progressBlock(progress),
      await _syllabusBlock(courseDir), //教学范围（大纲，可选）
      '今天是$date。',
      await _textbookBlock(courseDir, state['position']),
    ]);
    final history = await _mapHistory(courseDir, chatPath);
    if (dispatch != null && dispatch.isNotEmpty) {
      history.add(PromptMessage('user', dispatch));
    }
    return _compose(system, history);
  }

  ///问答（idle 期，含建课后首聊）：问答规则 + next_tutor 档案 + 学习者档案 + 教学范围（大纲，可选）
  ///+ 材料目录（仅目录，需要内容时 read 按需载入，成本从每轮 8k 降到几百）；不注入状态与日期。
  ///写入目标为下一课文件（新开课区间的交流段），群聊总在上一课文件尾，历史天然不含群聊。
  Future<List<Map<String, dynamic>>> qa({
    required String courseDir,
    required String chatPath,
    required String tutorName,
  }) async {
    final rule = await _prompt('qa.md');
    final tutorFile = await _tutorFile(courseDir, tutorName);
    final tutor = tutorFile != null
        ? await _readJson(tutorFile.path)
        : <String, dynamic>{};
    final learner = await _readJson('$courseDir/LEARNER.json');
    final state = await _readJson('$courseDir/STATE.json');

    final system = _join([
      rule,
      _identity(tutorName),
      _tutorBlock(tutor),
      _learnerBlock(learner),
      await _syllabusBlock(courseDir), //教学范围（大纲，可选）
      await _textbookBlock(
        courseDir,
        state['position'],
        withBody: false, //问答仅注入目录（read 寻址簿），需要哪段 read 哪段
      ),
    ]);
    return _compose(system, await _mapHistory(courseDir, chatPath));
  }

  ///聊天（idle + toggle 激活）：聊天规则 + 三位导师档案；不注入状态、日期与教材。
  ///chatPath 由调用方指向群聊讨论的落档文件（本课文件尾，含教学全程与群聊），历史即该文件全量。
  Future<List<Map<String, dynamic>>> social({
    required String courseDir,
    required String chatPath,
  }) async {
    final rule = await _prompt('social.md');
    final profiles = await _tutorProfiles(courseDir);
    final blocks = profiles.values
        .map((t) => _tutorBlock(t, level: _TutorBlockLevel.light))
        .toList();

    final system = _join([rule, ...blocks]);
    return _compose(system, await _mapHistory(courseDir, chatPath));
  }

  ///「其他」字段提炼（关系页编辑入口按钮，非对话场景）：
  ///提炼规则作 system，最近课次留档全文作 user 消息。
  ///不注入导师身份/学习者档案——避免用旧 extra 与单一导师视角影响提炼。
  Future<List<Map<String, dynamic>>> learnerExtra({
    required String chatPath,
  }) async {
    final rule = await _prompt('learner_extra.md');
    final history = await File(chatPath).readAsString();
    return _compose(rule, [PromptMessage('user', history)]);
  }

  ///导师群聊生成（课后更新完成后自动）：群聊规范 + 三位导师档案 + 本课对话 + 调度指令。
  Future<List<Map<String, dynamic>>> groupChat({
    required String courseDir,
    required String chatPath,
    String? dispatch,
  }) async {
    final rule = await _prompt('group.md');
    final profiles = await _tutorProfiles(courseDir);
    final blocks = profiles.values
        .map((t) => _tutorBlock(t, level: _TutorBlockLevel.light))
        .toList();

    final system = _join([rule, ...blocks]);
    final history = await _mapHistory(courseDir, chatPath);
    if (dispatch != null && dispatch.isNotEmpty) {
      history.add(PromptMessage('user', dispatch));
    }
    return _compose(system, history);
  }

  ///课后更新：更新指令（含 PROGRESS 规范）+ 现有知识点清单 + 本课导师档案 + 本课对话。
  Future<List<Map<String, dynamic>>> update({
    required String courseDir,
    required String chatPath,
    required String tutorName,
  }) async {
    final rule = await _prompt('update.md');
    final tutorFile = await _tutorFile(courseDir, tutorName);
    final tutor = tutorFile != null
        ? await _readJson(tutorFile.path)
        : <String, dynamic>{};
    final progress = await _readProgress('$courseDir/PROGRESS.jsonl');

    final system = _join([
      rule.replaceAll('{导师名}', tutorName),
      _progressNamesBlock(progress),
      _tutorBlock(tutor, level: _TutorBlockLevel.minimal),
    ]);
    return _compose(system, await _mapHistory(courseDir, chatPath));
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
