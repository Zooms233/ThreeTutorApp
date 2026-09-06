import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:tutor_chat/service/storage.dart';

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
  String? _textbookPath; //选中的教材文件路径（可选）
  bool _submitting = false; //提交中：防重复建课

  //课程名 = 课程目录名，禁止文件系统非法字符
  static final _invalidChars = RegExp(r'[\\/:*?"<>|]');

  //选择教材文件：Windows 弹资源管理器，Android 走系统选择器（SAF）
  Future<void> _pickTextbook() async {
    final file = await openFile();
    if (file == null) return; //用户取消选择
    setState(() => _textbookPath = file.path);
  }

  //提交建课；成功后返回资料页（群聊页实现前的过渡）
  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _submitting = true);

    final error = await StorageService().createCourse(
      worldName: widget.worldName,
      courseName: _courseName.text.trim(),
      learnerName: _learnerName.text.trim(),
      motivation: _motivation.text.trim(),
      extra: _extra.text.trim(),
      textbookPath: _textbookPath,
    );

    if (!mounted) return;
    if (error != null) {
      //建课失败（如同名课程已存在）：提示并留在表单
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error), duration: const Duration(seconds: 1)),
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('课程已创建，群聊页待实现'),
        duration: Duration(seconds: 1),
      ),
    );
    Navigator.pop(context);
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
            _buildField('其他想向导师传达的内容', _extra, hint: '可选', maxLines: 3),
            _buildTextbookRow(),
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

  //白底输入块：灰色小字标签 + 无边框输入（微信表单风格）
  Widget _buildField(
    String label,
    TextEditingController controller, {
    String? hint,
    int maxLines = 1,
    String? Function(String?)? validator,
  }) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      margin: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 13, color: Color(0xFF808080))),
          TextFormField(
            controller: controller,
            maxLines: maxLines,
            style: const TextStyle(fontSize: 16),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: const TextStyle(fontSize: 15, color: Color(0xFFB0B0B0)),
              border: InputBorder.none,
            ),
            validator: validator,
          ),
        ],
      ),
    );
  }

  //教材行：标签 + 已选文件名（点按清除）或「选择文件」按钮
  Widget _buildTextbookRow() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      margin: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          const Text(
            '教材文件（可选）',
            style: TextStyle(fontSize: 13, color: Color(0xFF808080)),
          ),
          const Spacer(),
          if (_textbookPath != null)
            GestureDetector(
              onTap: () => setState(() => _textbookPath = null),
              child: Text(
                _fileNameOf(_textbookPath!),
                style: const TextStyle(fontSize: 14, color: Color(0xFF07C160)),
                overflow: TextOverflow.ellipsis,
              ),
            )
          else
            TextButton(
              onPressed: _pickTextbook,
              child: const Text('选择文件', style: TextStyle(fontSize: 14)),
            ),
        ],
      ),
    );
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
