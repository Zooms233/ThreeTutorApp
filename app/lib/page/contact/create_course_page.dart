import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageRoute;
import 'package:flutter/material.dart';
import 'package:three_tutor/page/chat/group_chat_page.dart';
import 'package:three_tutor/service/outline.dart';
import 'package:three_tutor/service/storage.dart';
import 'package:three_tutor/service/three_tutor_service.dart';
import 'package:three_tutor/theme/app_colors.dart';
import 'package:three_tutor/widget/paste_dialog.dart';

//创建课程表单：从导师资料页「创建群聊」进入
//导师世界由发起的导师决定（不提供选择），完成即建课
class CreateCoursePage extends StatefulWidget {
  const CreateCoursePage({super.key, required this.worldName});

  final String worldName;

  @override
  State<CreateCoursePage> createState() => _CreateCoursePageState();
}

class _CreateCoursePageState extends State<CreateCoursePage> {
  final _formKey = GlobalKey<FormState>();
  final _courseName = TextEditingController();
  final _learnerName = TextEditingController();
  final _motivation = TextEditingController();
  final _extra = TextEditingController();
  String? _syllabusText; //教学大纲全文（可选，教学范围，仅一份；粘贴/文件两条路径统一持文本）
  String? _syllabusSource; //来源显示名（文件名或「粘贴内容」），点按清除
  final List<String> _textbookPaths = []; //选中的教学材料文件路径（可选，可多份）
  bool _submitting = false; //提交中：防重复建课
  bool _extracting = false; //提炼中：防重复触发提炼请求
  bool _hasAnyLessons = false; //全应用是否有课次（无则「从最近课程提炼」置灰）

  //课程名 = 课程目录名，禁止文件系统非法字符
  static final _invalidChars = RegExp(r'[\\/:*?"<>|]');

  //粘贴导入大纲（主入口，与导师组导入同模式）：校验通过后持有全文，提交时统一文本入库
  Future<void> _pasteSyllabus() async {
    final text = await showPasteImportDialog(
      context,
      title: '导入教学大纲',
      hint: '粘贴按「大纲生成提示词」生成的全文…',
    );
    if (text == null || !mounted) return; //取消即不动
    final (_, errors) = Outline.parse(text);
    if (!mounted) return;
    if (errors.isNotEmpty) {
      await _showOutlineErrors(errors);
      return;
    }
    setState(() {
      _syllabusText = text;
      _syllabusSource = '粘贴内容（${text.trim().split('\n').length} 行）';
    });
  }

  //选择大纲文件（次入口，已有存档文件的用户）：读出全文持有，路径只作取文本手段
  Future<void> _pickSyllabus() async {
    final XFile? file;
    try {
      file = await openFile();
    } catch (e) {
      //选择器不可用：多半是新加的原生插件未注册（加依赖后需完全重启应用）
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('文件选择器不可用：$e'),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }
    if (file == null) return; //用户取消选择
    final path = file.path; //先取出路径（闭包内无法使用可空变量的类型提升）
    //大纲即进度文件（doc/00）：选定即校验，格式错误当场暴露并展示行号清单，
    //而非等到建课才拦截；不通过则不记录选择
    final text = await file.readAsString();
    final (_, errors) = Outline.parse(text);
    if (!mounted) return;
    if (errors.isNotEmpty) {
      await _showOutlineErrors(errors);
      return;
    }
    setState(() {
      _syllabusText = text;
      _syllabusSource = _fileNameOf(path);
    });
  }

  //大纲校验错误清单：对话框逐条展示（SnackBar 容不下多条且一闪即逝）
  Future<void> _showOutlineErrors(List<OutlineError> errors) {
    return showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('大纲格式校验未通过'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final e in errors)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    e.lineNo > 0 ? '第 ${e.lineNo} 行：${e.message}' : e.message,
                    style: const TextStyle(fontSize: 13, height: 1.4),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  //选择多个文件（教学材料，可多份）
  Future<void> _pickTextbooks() async {
    final List<XFile> files;
    try {
      files = await openFiles();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('文件选择器不可用：$e'),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }
    if (files.isEmpty) return; //用户取消选择
    setState(() {
      for (final f in files) {
        final path = f.path;
        if (!_textbookPaths.contains(path)) _textbookPaths.add(path);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    //置灰判断：跨课程收素材（每门课忽略最新 1 篇，取最新 3 篇；不看课程类别）
    StorageService().recentLessonsAcrossCourses().then((lessons) {
      if (mounted) setState(() => _hasAnyLessons = lessons.isNotEmpty);
    });
  }

  //提交建课；成功后清栈直达新建课程的群聊页（返回时不倒回表单/资料页）
  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _submitting = true);

    final courseName = _courseName.text.trim();
    final error = await StorageService().createCourse(
      worldName: widget.worldName,
      courseName: courseName,
      learnerName: _learnerName.text.trim(),
      motivation: _motivation.text.trim(),
      extra: _extra.text.trim(),
      textbookPaths: _textbookPaths,
      syllabusText: _syllabusText,
    );

    if (!mounted) return;
    if (error != null) {
      //建课失败（同名已存在/大纲校验未通过）：提示并留在表单；错误可能多行，延长展示
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error), duration: const Duration(seconds: 3)),
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('课程已创建'),
        duration: Duration(seconds: 1),
      ),
    );
    //直接进入新建课程的群聊页：清掉群聊页以下的全部路由（表单页、导师资料页），
    //只留根 HomePage —— 返回群聊页时不会倒回导师资料页，
    //配合群聊页 PopScope 切回聊天 tab，正好落在会话列表
    Navigator.pushAndRemoveUntil(
      context,
      CupertinoPageRoute(
        builder: (_) => GroupChatPage(courseName: courseName),
      ),
      (route) => route.isFirst, //保留栈底（HomePage），其余全清
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('创建群聊')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _buildField(
              '课程名',
              _courseName,
              hint: '即群聊名称',
              validator: _validateCourseName,
            ),
            _buildField(
              '称呼',
              _learnerName,
              hint: '导师如何称呼你',
              validator: _validateRequired,
            ),
            _buildField(
              '学习动力',
              _motivation,
              hint: '你为什么想学这门课',
              maxLines: 3,
              validator: _validateRequired,
            ),
            _buildField(
              '其他想向导师传达的内容',
              _extra,
              hint: '可选，可从最近课程提炼',
              maxLines: 3,
              trailing: _buildExtractButton(),
            ),
            _buildSyllabusRow(),
            _buildTextbooksRow(),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _submitting ? null : _submit,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              child: Text(_submitting ? '创建中…' : '完成'),
            ),
          ],
        ),
      ),
    );
  }

  //白底输入块：灰色小字标签 + 无边框输入（无边框表单风格）；trailing 为 label 行右侧动作
  Widget _buildField(
    String label,
    TextEditingController controller, {
    String? hint,
    int maxLines = 1,
    String? Function(String?)? validator,
    Widget? trailing,
  }) {
    final c = AppColors.of(context);
    return Container(
      color: c.surface,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      margin: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(label, style: TextStyle(fontSize: 13, color: c.textFaint)),
              if (trailing != null) ...[const Spacer(), trailing],
            ],
          ),
          TextFormField(
            controller: controller,
            maxLines: maxLines,
            style: const TextStyle(fontSize: 16),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: TextStyle(fontSize: 15, color: c.textTertiary),
              border: InputBorder.none,
            ),
            validator: validator,
          ),
        ],
      ),
    );
  }

  //教学大纲行（仅一份）：标签 + 粘贴导入（主）/选择文件（次），已选显示来源（点按清除）
  Widget _buildSyllabusRow() {
    final c = AppColors.of(context);
    return Container(
      color: c.surface,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      margin: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Text(
            '教学大纲（可选）',
            style: TextStyle(fontSize: 13, color: c.textFaint),
          ),
          const Spacer(),
          if (_syllabusText != null)
            GestureDetector(
              onTap: () => setState(() {
                _syllabusText = null;
                _syllabusSource = null;
              }),
              child: Text(
                _syllabusSource!,
                style: TextStyle(fontSize: 14, color: c.accent),
                overflow: TextOverflow.ellipsis,
              ),
            )
          else ...[
            TextButton(
              onPressed: _pasteSyllabus,
              child: const Text('粘贴导入', style: TextStyle(fontSize: 14)),
            ),
            TextButton(
              onPressed: _pickSyllabus,
              child: const Text('选择文件', style: TextStyle(fontSize: 14)),
            ),
          ],
        ],
      ),
    );
  }

  //教学材料行（可多份）：标签 + 已选文件列表（点按移除）或「选择文件」按钮
  Widget _buildTextbooksRow() {
    final c = AppColors.of(context);
    return Container(
      color: c.surface,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      margin: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '教学材料（可选，可多份）',
                style: TextStyle(fontSize: 13, color: c.textFaint),
              ),
              const Spacer(),
              TextButton(
                onPressed: _pickTextbooks,
                child: const Text('选择文件', style: TextStyle(fontSize: 14)),
              ),
            ],
          ),
          for (final path in _textbookPaths)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _fileNameOf(path),
                      style: TextStyle(
                        fontSize: 14,
                        color: c.accent,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  //移除该份教材
                  GestureDetector(
                    onTap: () =>
                        setState(() => _textbookPaths.remove(path)),
                    child: Icon(
                      Icons.delete_outline,
                      size: 18,
                      color: c.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  //「从最近课程提炼」：跨课程扫全部课次、按文件创建时间取最新，提炼通用画像预填「其他」
  //置灰：全应用无课次（无材料）或提炼中；结果整段替换输入框（用户看过/改过随建课落盘）
  Widget _buildExtractButton() {
    return TextButton.icon(
      onPressed: !_hasAnyLessons || _extracting ? null : _extractExtra,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: _extracting
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.auto_awesome, size: 16),
      label: Text(
        _extracting ? '提炼中…' : '从最近课程提炼',
        style: const TextStyle(fontSize: 13),
      ),
    );
  }

  Future<void> _extractExtra() async {
    setState(() => _extracting = true);
    try {
      final draft = await ThreeTutorService().extractLearnerExtraAnyCourse();
      if (!mounted) return;
      setState(() => _extracting = false);
      if (draft == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('暂无课次记录'),
            duration: Duration(seconds: 2),
          ),
        );
        return;
      }
      if (draft.isEmpty || draft == '无') {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('最近课次中没有值得记录的学习者特征'),
            duration: Duration(seconds: 2),
          ),
        );
        return;
      }
      setState(() => _extra.text = draft);
    } catch (e) {
      if (!mounted) return;
      setState(() => _extracting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('提炼失败：$e'),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  String _fileNameOf(String path) => path.split(Platform.pathSeparator).last;

  //必填校验
  String? _validateRequired(String? value) {
    if (value == null || value.trim().isEmpty) return '必填';
    return null;
  }

  //课程名校验：必填 + 无目录名非法字符
  String? _validateCourseName(String? value) {
    if (value == null || value.trim().isEmpty) return '必填';
    if (_invalidChars.hasMatch(value)) return '包含不能用于文件夹名的字符';
    return null;
  }

  @override
  void dispose() {
    //页面销毁时释放输入控制器，避免内存泄漏
    _courseName.dispose();
    _learnerName.dispose();
    _motivation.dispose();
    _extra.dispose();
    super.dispose();
  }
}
