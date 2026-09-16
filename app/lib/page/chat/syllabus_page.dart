import 'package:flutter/material.dart';
import 'package:three_tutor/service/outline.dart';
import 'package:three_tutor/service/storage.dart';
import 'package:three_tutor/theme/app_colors.dart';

//教学进度清单页：渲染大纲（大纲即进度文件，doc/06）——章/节/知识点三层的 ✓/▢ 清单，
//高亮第一个待学知识点作为参考焦点。v1 只读：勾选由课后结算自动维护，
//手动勾选会绕过结算一致性（勾了 [x] 但 PROGRESS 无对应记录），不做；
//纠正状态可在外部直接编辑大纲文件（逃生门），本页重新进入即重读
class SyllabusPage extends StatefulWidget {
  const SyllabusPage({super.key, required this.courseName});

  final String courseName;

  @override
  State<SyllabusPage> createState() => _SyllabusPageState();
}

class _SyllabusPageState extends State<SyllabusPage> {
  bool _loading = true;
  OutlineDoc? _doc; //null = 无大纲或校验失败
  bool _invalid = false; //true = 存在大纲但格式不合规（旧格式/被外部改坏）

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final text = await StorageService().loadCourseOutline(widget.courseName);
    OutlineDoc? doc;
    var invalid = false;
    if (text != null) {
      final (parsed, errors) = Outline.parse(text);
      if (errors.isEmpty) {
        doc = parsed;
      } else {
        invalid = true; //课程内大纲理应导入时已过校验：被外部改坏才会走到这
      }
    }
    if (!mounted) return;
    setState(() {
      _doc = doc;
      _invalid = invalid;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('教学进度')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _buildBody(),
    );
  }

  Widget _buildBody() {
    final c = AppColors.of(context);
    if (_doc == null) {
      return Padding(
        padding: const EdgeInsets.all(32),
        child: Center(
          child: Text(
            _invalid
                ? '大纲格式不合规（可能被外部修改），请在课程资料中重新导入'
                : '未设置教学大纲（教学相长模式：师生共同商定学习方向）',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: c.textSecondary),
          ),
        ),
      );
    }

    final doc = _doc!;
    final pending = doc.firstPending; //null = 结课
    return ListView(
      children: [
        //顶部进度摘要：进行中显示当前节与计数；全 [x] 即结课态
        Container(
          color: c.surface,
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Text(
            pending == null
                ? '已学完全部大纲内容'
                : '当前：${_sectionTitleOf(doc, pending)}（已学 ${doc.doneItems}/${doc.totalItems}）',
            style: TextStyle(fontSize: 14, color: c.textPrimary),
          ),
        ),
        for (final ch in doc.chapters) _buildChapter(ch, pending),
      ],
    );
  }

  //知识点所在节标题（顶部摘要用）
  String _sectionTitleOf(OutlineDoc doc, OutlineItem item) {
    for (final ch in doc.chapters) {
      for (final sec in ch.sections) {
        if (sec.items.contains(item)) return sec.title;
      }
    }
    return '';
  }

  Widget _buildChapter(OutlineChapter ch, OutlineItem? pending) {
    final c = AppColors.of(context);
    return Container(
      color: c.surface,
      margin: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              ch.title,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: c.textPrimary,
              ),
            ),
          ),
          for (final sec in ch.sections) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
              child: Text(
                sec.title,
                style: TextStyle(fontSize: 14, color: c.textSecondary),
              ),
            ),
            for (final item in sec.items) _buildItemRow(item, pending),
          ],
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  //知识点行：✓/▢ + 文本；第一个待学行高亮（参考焦点——乱序学习时以实际对话为准）
  Widget _buildItemRow(OutlineItem item, OutlineItem? pending) {
    final c = AppColors.of(context);
    final isFocus = pending != null && identical(item, pending);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Row(
        children: [
          Text(
            item.done ? '✓' : '▢',
            style: TextStyle(
              fontSize: 14,
              color: item.done ? c.accent : c.textTertiary,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              isFocus ? '${item.text}（进行中）' : item.text,
              style: TextStyle(
                fontSize: 14,
                color: isFocus ? c.accent : c.textPrimary,
                fontWeight: isFocus ? FontWeight.bold : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
