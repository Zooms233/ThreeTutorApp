import 'package:flutter/cupertino.dart' show CupertinoPageRoute;
import 'package:flutter/material.dart';
import 'package:tutor_chat/page/chat/relation_page.dart';
import 'package:tutor_chat/service/storage.dart';

//课程详情页：状态四项 + 知识点进度 + 关系入口（原课程信息页与课程进度页合并）
class CourseDetailPage extends StatefulWidget {
  const CourseDetailPage({super.key, required this.courseName});

  final String courseName;

  @override
  State<CourseDetailPage> createState() => _CourseDetailPageState();
}

class _CourseDetailPageState extends State<CourseDetailPage> {
  Map<String, dynamic> _state = {};
  List<Map<String, dynamic>> _progress = []; //知识点（新在前）
  final Set<int> _expanded = {}; //展开全部历史状态块的知识点索引
  bool _loading = true;

  @override
  void initState() {
    super.initState(); //先执行 Flutter 自身的初始化
    _load();
  }

  //读取 STATE 与 PROGRESS 并刷新
  Future<void> _load() async {
    final state = await StorageService().loadCourseState(widget.courseName);
    final progress = await StorageService().loadCourseProgress(widget.courseName);
    if (!mounted) return; //await 等待期间页面可能已被销毁，先确认还活着再刷新
    setState(() {
      _state = state;
      _progress = progress;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('课程详情')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                _buildStateCard(),
                _buildRelationRow(),
                _buildProgressSection(),
              ],
            ),
    );
  }

  //状态四项（读 STATE）
  Widget _buildStateCard() {
    final position = _state['position'] as String? ?? '';
    final nextTutor = _state['next_tutor'] as String? ?? '';
    final lessons = _state['lessons'] as int? ?? 0;
    final lastDate = _state['last_date'] as String? ?? '';

    return Container(
      color: Colors.white,
      margin: const EdgeInsets.only(bottom: 8),
      child: Column(
        children: [
          _buildStateRow('当前讲授位置', position.isEmpty ? '—' : position),
          _buildStateRow('下一节课授课导师', nextTutor.isEmpty ? '—' : nextTutor),
          _buildStateRow('累计课时', '$lessons'),
          _buildStateRow('最近上课日期', lastDate.isEmpty ? '—' : lastDate),
        ],
      ),
    );
  }

  //状态行：灰色标签左 + 值右
  Widget _buildStateRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 14, color: Color(0xFF999999)),
          ),
          const Spacer(),
          Text(value, style: const TextStyle(fontSize: 14, color: Color(0xFF191919))),
        ],
      ),
    );
  }

  //和导师的关系入口 → 关系页
  Widget _buildRelationRow() {
    return Container(
      color: Colors.white,
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        title: const Text('和导师的关系'),
        trailing: const Icon(Icons.chevron_right, color: Color(0xFFC8C8C8)),
        onTap: () {
          Navigator.push(
            context,
            CupertinoPageRoute(
              builder: (context) => RelationPage(courseName: widget.courseName),
            ),
          );
        },
      ),
    );
  }

  //知识点进度区（课程详情页主体）
  Widget _buildProgressSection() {
    //空进度提示
    if (_progress.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(32),
        child: Center(
          child: Text(
            '暂无学习进度，完成第一节课后自动生成',
            style: const TextStyle(fontSize: 14, color: Color(0xFF999999)),
          ),
        ),
      );
    }

    return Container(
      color: Colors.white,
      child: Column(
        children: [
          for (var i = 0; i < _progress.length; i++)
            _buildKnowledgeItem(i, _progress[i]),
        ],
      ),
    );
  }

  //知识点行：默认显示最新状态块，点击展开全部历史状态块
  Widget _buildKnowledgeItem(int index, Map<String, dynamic> knowledge) {
    final name = knowledge['name'] as String? ?? '';
    final records = (knowledge['records'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    if (records.isEmpty) return const SizedBox.shrink();

    final latest = records.last;
    final expanded = _expanded.contains(index);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () {
            setState(() {
              if (expanded) {
                _expanded.remove(index);
              } else {
                _expanded.add(index);
              }
            });
          },
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${latest['status']} $name',
                  style: const TextStyle(fontSize: 15, color: Color(0xFF191919)),
                ),
                const SizedBox(height: 4),
                Text(
                  '最近 ${latest['date'] ?? ''} → 复习 ${latest['review'] ?? ''}',
                  style: const TextStyle(fontSize: 12, color: Color(0xFF999999)),
                ),
                if (_hasMistake(latest))
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '【${latest['mistake']}】',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFFFA5151),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        //展开的历史状态块（除最新外，从新到旧）
        if (expanded)
          for (var j = records.length - 2; j >= 0; j--)
            Padding(
              padding: const EdgeInsets.fromLTRB(32, 0, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${records[j]['status']} ${records[j]['date'] ?? ''} → 复习 ${records[j]['review'] ?? ''}',
                    style: const TextStyle(fontSize: 12, color: Color(0xFF999999)),
                  ),
                  if (_hasMistake(records[j]))
                    Text(
                      '【${records[j]['mistake']}】',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFFFA5151),
                      ),
                    ),
                ],
              ),
            ),
        const Divider(height: 0.5, indent: 16),
      ],
    );
  }

  //状态块是否有错因（仅 △/✗ 存在）
  static bool _hasMistake(Map<String, dynamic> record) =>
      record['mistake'] != null && (record['mistake'] as String).isNotEmpty;
}
