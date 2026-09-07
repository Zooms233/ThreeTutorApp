import 'package:flutter/material.dart';
import 'package:tutor_chat/service/storage.dart';

//导师档案页：滚动展示导师完整档案
class TutorProfilePage extends StatefulWidget {
  const TutorProfilePage({
    super.key,
    required this.worldName,
    required this.fileName,
  });

  final String worldName;
  final String fileName; //如 tutor_a.json

  @override
  State<TutorProfilePage> createState() => _TutorProfilePageState();
}

class _TutorProfilePageState extends State<TutorProfilePage> {
  Map<String, dynamic>? _profile;
  bool _loading = true;

  @override
  void initState() {
    super.initState(); //先执行 Flutter 自身的初始化
    _loadProfile(); //进入页面时才读取完整档案（懒加载）
  }

  //读取导师完整档案并刷新界面
  Future<void> _loadProfile() async {
    final profile = await StorageService()
        .loadTutorProfile(widget.worldName, widget.fileName);
    if (!mounted) return; //await 等待期间页面可能已被销毁，先确认还活着再刷新
    setState(() {
      _profile = profile;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final profile = _profile;
    return Scaffold(
      appBar: AppBar(title: Text(profile?['name'] as String? ?? '')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _buildProfile(profile!),
    );
  }

  //档案内容：按文档分区展示
  Widget _buildProfile(Map<String, dynamic> profile) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _section('基本信息', _buildBasicInfo(profile)),
        _section('性格与动机', Text(profile['personality'] as String)),
        _section('说话风格与示例', _buildSpeech(profile)),
        _section('与学习者的关系', Text(profile['relation'] as String)),
      ],
    );
  }

  //基本信息：身份、性格关键词（gender 字段已废——不进对话，纯档案冗余）
  Widget _buildBasicInfo(Map<String, dynamic> profile) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _infoRow('身份', profile['identity']),
        _infoRow('性格关键词', profile['traits']),
      ],
    );
  }

  //说话风格：概括 + 示例引用列表
  Widget _buildSpeech(Map<String, dynamic> profile) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(profile['speech_style'] as String),
        const SizedBox(height: 8),
        ..._buildListItems(profile['speech_examples'] as List?),
      ],
    );
  }

  List<Widget> _buildListItems(List? items) {
    return [
      for (final item in items ?? [])
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text('· $item'),
        ),
    ];
  }

  //通用：[标签：值] 文本行，标签加粗
  Widget _infoRow(String label, Object? value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$label：',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            TextSpan(text: '$value'),
          ],
        ),
      ),
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