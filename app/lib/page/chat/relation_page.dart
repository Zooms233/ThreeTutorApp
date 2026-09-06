import 'package:flutter/material.dart';
import 'package:tutor_chat/service/storage.dart';

//关系页：学习者信息 + 三位导师与学习者的关系
//数据来自课程内副本（课后更新后为最新版本），非世界目录的静态版本
class RelationPage extends StatefulWidget {
  const RelationPage({super.key, required this.courseName});

  final String courseName;

  @override
  State<RelationPage> createState() => _RelationPageState();
}

class _RelationPageState extends State<RelationPage> {
  Map<String, dynamic> _learner = {}; //学习者档案（name/motivation/extra）
  List<Map<String, dynamic>> _relations = []; //导师 name + relation（tutor_a→b→c）
  bool _loading = true;

  @override
  void initState() {
    super.initState(); //先执行 Flutter 自身的初始化
    _load();
  }

  //读取学习者档案与导师关系并刷新
  Future<void> _load() async {
    final learner = await StorageService().loadCourseLearner(widget.courseName);
    final relations = await StorageService().loadCourseTutorRelations(
      widget.courseName,
    );
    if (!mounted) return; //await 等待期间页面可能已被销毁，先确认还活着再刷新
    setState(() {
      _learner = learner;
      _relations = relations;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('和学习者的关系')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                _buildLearnerCard(),
                for (final tutor in _relations) _buildRelationBlock(tutor),
              ],
            ),
    );
  }

  //学习者信息卡（白底：称呼/学习动力/其他）
  Widget _buildLearnerCard() {
    final name = _learner['name'] as String? ?? '';
    final motivation = _learner['motivation'] as String? ?? '';
    final extra = _learner['extra'] as String? ?? '';

    return Container(
      color: Colors.white,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '学习者',
            style: TextStyle(fontSize: 13, color: Color(0xFF808080)),
          ),
          const SizedBox(height: 8),
          _buildInfoLine('称呼', name),
          _buildInfoLine('学习动力', motivation),
          if (extra.isNotEmpty) _buildInfoLine('其他', extra),
        ],
      ),
    );
  }

  //信息行：灰色标签固定宽 + 正文（长文本换行对齐）
  Widget _buildInfoLine(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: const TextStyle(fontSize: 14, color: Color(0xFF999999)),
            ),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? '—' : value,
              style: const TextStyle(
                fontSize: 14,
                height: 1.4,
                color: Color(0xFF191919),
              ),
            ),
          ),
        ],
      ),
    );
  }

  //导师关系块：导师名小字标签 + relation 段落（白底）
  Widget _buildRelationBlock(Map<String, dynamic> tutor) {
    final name = tutor['name'] as String? ?? '';
    final relation = tutor['relation'] as String? ?? '';

    return Container(
      color: Colors.white,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(name, style: const TextStyle(fontSize: 13, color: Color(0xFF808080))),
          const SizedBox(height: 8),
          Text(
            relation.isEmpty ? '尚未建立关系记录' : relation,
            style: const TextStyle(
              fontSize: 15,
              height: 1.5,
              color: Color(0xFF191919),
            ),
          ),
        ],
      ),
    );
  }
}
