import 'package:flutter/material.dart';
import 'package:tutor_chat/service/storage.dart';

//学习者档案页：滚动展示学习者档案
class LearnerProfilePage extends StatefulWidget {
  const LearnerProfilePage({super.key, required this.worldName});

  final String worldName;

  @override
  State<LearnerProfilePage> createState() => _LearnerProfilePageState();
}

class _LearnerProfilePageState extends State<LearnerProfilePage> {
  Map<String, dynamic>? _profile;
  bool _loading = true;

  @override
  void initState() {
    super.initState(); //先执行 Flutter 自身的初始化
    _loadProfile(); //进入页面时才读取档案（懒加载）
  }

  //读取学习者档案并刷新界面
  Future<void> _loadProfile() async {
    final profile = await StorageService().loadLearnerProfile(widget.worldName);
    if (!mounted) return; //await 等待期间页面可能已被销毁，先确认还活着再刷新
    setState(() {
      _profile = profile;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final profile = _profile;
    //称呼未填写时显示「学习者」
    final name = (profile?['name'] as String? ?? '').isEmpty
        ? '学习者'
        : profile!['name'] as String;
    return Scaffold(
      appBar: AppBar(title: Text(name)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _buildProfile(profile!),
    );
  }

  //档案内容：身份 + 故事背景
  Widget _buildProfile(Map<String, dynamic> profile) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _section('身份', Text(profile['identity'] as String)),
        _section('故事背景', Text(profile['story'] as String)),
      ],
    );
  }

  //通用：分区标题 + 内容
  Widget _section(String title, Widget child) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}