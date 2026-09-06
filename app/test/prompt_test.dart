import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tutor_chat/service/prompt.dart';

//组装层单测：构造临时课程目录 fixture，断言五场景的 system 顺序/内容与 CHAT 映射。
//运行：cd app && flutter test test/prompt_test.dart
void main() {
  TestWidgetsFlutterBinding.ensureInitialized(); //rootBundle 可用（读 assets/prompts）

  late Directory tmp;
  late String chatPath;
  const tutorName = '纳西妲';

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tutorchat_prompt_test');
    //STATE：position 指向教材 3-2 节
    File('${tmp.path}/STATE.json').writeAsStringSync(jsonEncode({
      'position': 'TEXTBOOK/化学.md > 3-2 化学平衡移动',
      'next_tutor': '芙宁娜',
      'lessons': 2,
      'last_date': '2026-08-04',
    }));
    //PROGRESS：两行，每行含历史状态块（取最后一项为最新）
    File('${tmp.path}/PROGRESS.jsonl').writeAsStringSync(
      '${jsonEncode({
        'name': '氧化还原反应',
        'records': [
          {'status': '✓', 'date': '2026-03-15', 'review': '2026-03-22'}
        ],
      })}\n${jsonEncode({
        'name': '化学平衡移动',
        'records': [
          {'status': '△', 'date': '2026-03-18', 'review': '2026-03-21', 'mistake': '混淆常数与速率'},
          {'status': '✓', 'date': '2026-03-25', 'review': '2026-04-01'},
        ],
      })}\n',
    );
    //LEARNER
    File('${tmp.path}/LEARNER.json').writeAsStringSync(jsonEncode({
      'name': 'zooms',
      'identity': '异域旅者',
      'motivation': '想搞懂身边的一切',
      'story': '天天泡图书馆的旅者',
      'extra': '',
    }));
    //三位导师档案（relations 字段验证档案块拼装）
    File('${tmp.path}/tutor_a.json').writeAsStringSync(jsonEncode({
      'name': '纳西妲',
      'identity': '荣誉教授',
      'traits': '温柔',
      'appearance': '白色长发',
      'personality': '喜爱知识',
      'speech_style': '简短上扬',
      'speech_examples': ['你有没有想过……'],
      'emotions': ['思考时轻闭眼'],
      'relation': '与学习者的关系段落',
    }));
    File('${tmp.path}/tutor_b.json').writeAsStringSync(jsonEncode({
      'name': '芙宁娜',
      'identity': '教授',
      'relation': '芙宁娜的关系段',
    }));
    File('${tmp.path}/tutor_c.json').writeAsStringSync(jsonEncode({
      'name': '哥伦比娅',
      'identity': '教授',
      'relation': '哥伦比娅的关系段',
    }));
    //TEXTBOOK：3-2 节内含更深一级标题（### 应留在本节内），以同级 ## 3-3 结束
    final textbook = Directory('${tmp.path}/TEXTBOOK')..createSync();
    File('${textbook.path}/化学.md').writeAsStringSync(
      '# 第一章 化学反应\n## 3-1 氧化还原\n内容A\n## 3-2 化学平衡移动\n内容B开头\n### 平衡常数\n内容B2\n## 3-3 电化学\n内容C\n',
    );
    //CHAT：meta + user(带time) + assistant + 连续两条 user（应合并）
    Directory('${tmp.path}/CHAT').createSync();    File('${tmp.path}/CHAT/第2课.jsonl').writeAsStringSync(
      '${jsonEncode({'type': 'meta', 'lesson': 2, 'date': '2026-08-04', 'tutor': '芙宁娜', 'status': 'idle'})}\n'
      '${jsonEncode({'type': 'message', 'phase': 'qa', 'role': 'user', 'name': 'zooms', 'time': '2026-08-06 20:00', 'content': '常数和速率分不清'})}\n'
      '${jsonEncode({'type': 'message', 'phase': 'qa', 'role': 'tutor', 'name': '芙宁娜', 'content': '常数只认识平衡！'})}\n'
      '${jsonEncode({'type': 'message', 'phase': 'qa', 'role': 'user', 'name': 'zooms', 'time': '2026-08-06 21:00', 'content': '那再讲讲'})}\n'
      '${jsonEncode({'type': 'message', 'phase': 'qa', 'role': 'user', 'name': 'zooms', 'time': '2026-08-06 21:01', 'content': '用个例子'})}\n',
    );
    chatPath = '${tmp.path}/CHAT/第2课.jsonl'.replaceAll('/', Platform.pathSeparator);
  });

  tearDown(() async => tmp.deleteSync(recursive: true));


  test('教学：system 顺序完整（规则→身份→档案→状态→进度→日期→教材），含调度指令', () async {
    final msgs = await PromptBuilder().teaching(
      courseDir: tmp.path,
      chatPath: chatPath,
      tutorName: tutorName,
      dispatch: '（课程开始。打招呼。）',
    );
    expect(msgs.first['role'], 'system');
    final system = msgs.first['content']!;

    //顺序断言：四段依次出现
    final iRule = system.indexOf('教学规则');
    final iIdentity = system.indexOf('你是$tutorName');
    final iTutor = system.indexOf('【$tutorName】');
    final iLearner = system.indexOf('【学习者】');
    final iState = system.indexOf('【课程状态】');
    final iProgress = system.indexOf('【知识点进度】');
    final iDate = system.indexOf('今天是');
    final iBook = system.indexOf('今日教材进度：');
    expect([iRule, iIdentity, iTutor, iLearner, iState, iProgress, iDate, iBook],
        everyElement(greaterThanOrEqualTo(0)));
    expect(iRule < iIdentity && iIdentity < iTutor && iTutor < iLearner, isTrue);
    expect(iLearner < iState && iState < iProgress && iProgress < iDate && iDate < iBook, isTrue);

    //档案内容进 system
    expect(system, contains('说话示例'));
    expect(system, contains('你有没有想过……'));
    //进度取最新状态块（化学平衡移动应为 ✓ 而非 △）
    expect(system, contains('✓ 化学平衡移动'));
    expect(system, isNot(contains('△ 化学平衡移动')));
    //教材切节：3-2 全节（含 ### 子标题），不含邻节
    expect(system, contains('内容B开头'));
    expect(system, contains('内容B2'));
    expect(system, isNot(contains('内容A')));
    expect(system, isNot(contains('内容C')));

    //历史映射 + 调度指令在尾部
    expect(msgs.length, 5); //system + 合并后3条历史 + 调度指令
    expect(msgs.last['content'], '（课程开始。打招呼。）');
  });

  test('CHAT 映射：meta 不映射、time 头、连续 user 合并', () async {
    final msgs = await PromptBuilder().teaching(courseDir: tmp.path, chatPath: chatPath, tutorName: tutorName);
    final body = msgs.skip(1).toList();
    expect(body[0]['role'], 'user');
    expect(body[0]['content'], '[08-06 20:00] 常数和速率分不清'); //time 头
    expect(body[1]['role'], 'assistant');
    expect(body[1]['content'], '常数只认识平衡！'); //原文
    expect(body[2]['role'], 'user');
    expect(body[2]['content'], '[08-06 21:00] 那再讲讲\n[08-06 21:01] 用个例子'); //连续合并
    expect(body.length, 3);
  });

  test('问答：无状态注入，有教材', () async {
    final msgs = await PromptBuilder().qa(courseDir: tmp.path, chatPath: chatPath, tutorName: '芙宁娜');
    final system = msgs.first['content']!;
    expect(system, contains('你是芙宁娜')); //next_tutor 单人
    expect(system, contains('芙宁娜的关系段'));
    expect(system, isNot(contains('【课程状态】')));
    expect(system, isNot(contains('【知识点进度】')));
    expect(system, isNot(contains('今天是')));
    expect(system, contains('今日教材进度：')); //教材注入
    expect(system, contains('【学习者】')); //学习者档案
  });

  test('聊天：三档案齐注入，无状态无日期无教材', () async {
    final msgs = await PromptBuilder().social(courseDir: tmp.path, chatPath: chatPath);
    final system = msgs.first['content']!;
    for (final name in ['纳西妲', '芙宁娜', '哥伦比娅']) {
      expect(system, contains('【$name】'));
    }
    expect(system, isNot(contains('【课程状态】')));
    expect(system, isNot(contains('今日教材进度：')));
    expect(system, isNot(contains('今天是')));
  });

  test('群聊生成：规范 + 三档案 + 本课对话', () async {
    final msgs = await PromptBuilder().groupChat(courseDir: tmp.path, chatPath: chatPath);
    final system = msgs.first['content']!;
    expect(system, contains('导师群聊规范'));
    expect(system, contains('【纳西妲】'));
    expect(system, contains('【芙宁娜】'));
    expect(msgs.length, 4); //system + 3 条映射历史
  });

  test('课后更新：{导师名} 占位符替换、现有短名清单、本课档案', () async {
    final msgs = await PromptBuilder().update(courseDir: tmp.path, chatPath: chatPath, tutorName: '芙宁娜');
    final system = msgs.first['content']!;
    expect(system, isNot(contains('{导师名}')));
    expect(system, contains('你是芙宁娜')); //占位符替换后的身份声明
    expect(system, contains('【现有知识点】'));
    expect(system, contains('氧化还原反应、化学平衡移动'));
    expect(system, contains('【芙宁娜】')); //本课导师档案
  });
}
