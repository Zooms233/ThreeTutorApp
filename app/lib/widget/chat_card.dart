import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:three_tutor/widget/tutor_avatar.dart';

//导出聊天卡片：单课次消息流的静态长图视图（离屏渲染 → RepaintBoundary 截图 → 系统分享）。
//气泡样式与群聊页一致（微信风格），尾部带推广 footer；纯静态无交互。

//下划线斜体规范化：_文字_ → *文字*（gpt_markdown 的 ItalicMd 只认星号斜体，不认下划线）
//开/闭下划线不贴 ASCII 字母数字（保护 file_name 类英文词内下划线与数字下标），内容首尾非空白
final RegExp _underscoreItalic = RegExp(
  r'(?<![A-Za-z0-9])_(?!_)([^_\s](?:[^_\n]*[^_\s])?)_(?![A-Za-z0-9_])',
);

//渲染前调用：把非 LaTeX 区间的 _文字_ 转为 *文字*；公式段原样保留（_ 是 LaTeX 下标语法）
String normalizeItalic(String text) {
  return text.splitMapJoin(
    RegExp(r'\$\$?[^$]*\$\$?'),
    onMatch: (m) => m.group(0)!,
    onNonMatch: (t) =>
        t.replaceAllMapped(_underscoreItalic, (m) => '*${m[1]}*'),
  );
}

//聊天卡片：固定宽度，高度按内容自适应（长图）
class ChatCardView extends StatelessWidget {
  const ChatCardView({
    super.key,
    required this.courseName,
    required this.lesson,
    required this.tutor,
    required this.date,
    required this.entries,
    required this.courseDirPath,
    required this.tutorFiles,
    required this.learnerName,
  });

  final String courseName;
  final int lesson; //课次号（meta.lesson）
  final String tutor; //授课导师（meta.tutor）
  final String date; //上课日期（meta.date）
  final List<Map<String, dynamic>> entries; //本课消息条目（message + tool 行）
  final String courseDirPath; //课程目录（头像图片查找用）
  final Map<String, String> tutorFiles; //导师名 → 档案文件名（头像查找用）
  final String learnerName; //学习者称呼（右侧气泡头像占位字）

  //卡片宽度：导出长图的逻辑像素宽（截图时按 pixelRatio 放大）
  static const double width = 400;

  @override
  Widget build(BuildContext context) {
    final items = <Widget>[
      //标题头：课程名 + 课次信息
      Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(0, 0, 0, 10),
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          children: [
            Text(
              courseName,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              '第 $lesson 课 · $tutor · $date',
              style: const TextStyle(fontSize: 12, color: Color(0xFF999999)),
            ),
          ],
        ),
      ),
      //消息流
      ..._buildEntries(),
      //推广 footer：应用名 + 一句话介绍（分享传播的核心钩子）
      Container(
        margin: const EdgeInsets.only(top: 10),
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: const Column(
          children: [
            Text('—— 由 ThreeTutor 生成 ——',
                style: TextStyle(fontSize: 12, color: Color(0xFF999999))),
            SizedBox(height: 4),
            Text('三位 AI 导师 · 一对一教学',
                style: TextStyle(fontSize: 12, color: Color(0xFF576B95))),
          ],
        ),
      ),
    ];

    return Container(
      width: width,
      padding: const EdgeInsets.all(14),
      color: const Color(0xFFEDEDED), //微信聊天背景灰
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: items,
      ),
    );
  }

  List<Widget> _buildEntries() {
    final widgets = <Widget>[];
    var seenSocial = false; //「下课后」分隔行只插一次（首个 social 消息前）
    for (final e in entries) {
      if (e['type'] == 'tool') {
        //翻书记录：灰字系统行（不渲染正文）
        final name = e['name'] as String? ?? '';
        widgets.add(_divider('📖 $name 查阅了教材'));
        continue;
      }
      if (e['type'] != 'message') continue; //meta / tool_call 不渲染
      final phase = e['phase'] as String? ?? 'teaching';
      if (phase == 'social' && !seenSocial) {
        widgets.add(_divider('下课后'));
        seenSocial = true;
      }
      widgets.add(
        (e['role'] as String? ?? 'tutor') == 'user'
            ? _userBubble(e['content'] as String? ?? '')
            : _tutorBubble(
                e['name'] as String? ?? '',
                e['content'] as String? ?? '',
              ),
      );
    }
    return widgets;
  }

  //系统分隔行（下课后 / 翻书提示）：居中灰字
  Widget _divider(String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: Text(
            text,
            style: const TextStyle(fontSize: 11, color: Color(0xFFB0B0B0)),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );

  //导师消息：头像 + 名字 + 白气泡，左对齐
  Widget _tutorBubble(String name, String content) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TutorAvatar(
            name: name,
            size: 28,
            imageDir: courseDirPath,
            fileName: tutorFiles[name],
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    style: const TextStyle(
                        fontSize: 11, color: Color(0xFF999999))),
                const SizedBox(height: 2),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 7),
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(10),
                      topRight: Radius.circular(10),
                      bottomLeft: Radius.circular(3),
                      bottomRight: Radius.circular(10),
                    ),
                  ),
                  child: _content(content),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  //用户消息：绿气泡右对齐（群聊风格：不显示名字）
  Widget _userBubble(String content) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flexible(
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: const Color(0xFF95EC69),
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(10),
                  topRight: Radius.circular(10),
                  bottomLeft: Radius.circular(10),
                  bottomRight: Radius.circular(3),
                ),
              ),
              child: _content(content),
            ),
          ),
          const SizedBox(width: 8),
          TutorAvatar(name: learnerName, size: 28),
        ],
      ),
    );
  }

  //消息正文：GptMarkdown 渲染（与聊天页一致：斜体规范化 + $...$ LaTeX）
  Widget _content(String content) {
    return GptMarkdown(
      normalizeItalic(content),
      style: const TextStyle(fontSize: 13, height: 1.4),
      useDollarSignsForLatex: true,
      styleSheet: const GptMarkdownStyleSheet(
        latex: LatexStyle(
          textStyle: TextStyle(fontSize: 13),
          scrollBlockHorizontally: false, //静态长图无滚动：块公式按宽度折行/收缩
        ),
      ),
    );
  }
}
