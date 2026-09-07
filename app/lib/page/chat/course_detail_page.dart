import 'package:flutter/cupertino.dart' show CupertinoPageRoute;
import 'package:flutter/material.dart';
import 'package:tutor_chat/page/chat/relation_page.dart';
import 'package:tutor_chat/service/storage.dart';
import 'package:tutor_chat/service/tutorchat_service.dart';

//课程详情页：状态四项 + 知识点进度 + 关系入口（原课程信息页与课程进度页合并）
class CourseDetailPage extends StatefulWidget {
  const CourseDetailPage({super.key, required this.courseName});

  final String courseName;

  @override
  State<CourseDetailPage> createState() => _CourseDetailPageState();
}

class _CourseDetailPageState extends State<CourseDetailPage> {
  Map<String, dynamic> _state = {};
  Map<String, dynamic>? _meta; //最新课次 meta（上课控制按钮状态判定；null=从未上课）
  List<Map<String, dynamic>> _progress = []; //知识点（新在前）
  final Set<int> _expanded = {}; //展开全部历史状态块的知识点索引
  bool _loading = true;

  @override
  void initState() {
    super.initState(); //先执行 Flutter 自身的初始化
    //监听共享 busy 表：课程生成中（上课/下课/群聊全程）按钮禁用，完成即恢复
    TutorChatService.busyVersion.addListener(_onBusyChanged);
    _load();
  }

  @override
  void dispose() {
    TutorChatService.busyVersion.removeListener(_onBusyChanged);
    super.dispose();
  }

  void _onBusyChanged() {
    if (mounted) setState(() {}); //busy 文案经 getter 即时读取
  }

  //本课程是否生成中（任何场景：上课/问答/问候/总结/更新/群聊全程）
  bool get _courseBusy => TutorChatService.busyLabelOf(widget.courseName).isNotEmpty;

  //读取 STATE、PROGRESS 与最新课次 meta 并刷新
  Future<void> _load() async {
    final state = await StorageService().loadCourseState(widget.courseName);
    final progress = await StorageService().loadCourseProgress(widget.courseName);
    final meta = await StorageService().loadLatestChatMeta(widget.courseName);
    if (!mounted) return; //await 等待期间页面可能已被销毁，先确认还活着再刷新
    setState(() {
      _state = state;
      _progress = progress;
      _meta = meta;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('课程详情'),
        actions: [
          //上课控制按钮：三态——生成中禁用（避免并发操作状态机）；
          //点击 pop 意图返回群聊页执行：start=开新课次建档，end=下课总结
          TextButton(
            onPressed: _courseBusy
                ? null
                : () => Navigator.pop(
                      context,
                      _meta?['status'] == 'ongoing' ? 'end' : 'start',
                    ),
            child: Text(
              //忙碌文案即状态：下课流程（总结→更新→群聊）全程禁用，
              //完成后 meta 已置 ended，按钮自动变「开始上课」
              _courseBusy
                  ? '正在处理中…'
                  : (_meta?['status'] == 'ongoing' ? '今天就到这里' : '开始上课'),
              style: TextStyle(
                color: _courseBusy
                    ? const Color(0xFFB0B0B0)
                    : const Color(0xFF07C160),
              ),
            ),
          ),
        ],
      ),
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
