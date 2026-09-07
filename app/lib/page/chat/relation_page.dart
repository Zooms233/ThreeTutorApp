import 'package:flutter/material.dart';
import 'package:tutor_chat/service/storage.dart';
import 'package:tutor_chat/service/tutorchat_service.dart';

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

  //学习者信息卡（白底：称呼/学习动力/其他）；标题行尾随编辑按钮 →
  //打开编辑对话框（三个可编辑字段的唯一入口；导师关系段由课后更新维护，不可编辑）
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
          Row(
            children: [
              const Text(
                '学习者',
                style: TextStyle(fontSize: 13, color: Color(0xFF808080)),
              ),
              const Spacer(),
              GestureDetector(
                onTap: _showLearnerEditDialog,
                child: const Icon(
                  Icons.edit_outlined,
                  size: 18,
                  color: Color(0xFF999999),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _buildInfoLine('称呼', name),
          _buildInfoLine('学习动力', motivation),
          _buildInfoLine('其他', extra),
        ],
      ),
    );
  }

  //学习者档案编辑对话框：称呼/学习动力必填，其他选填（留空存空串，展示为 —）；
  //保存后 _load() 刷新卡片；prompt 每次请求现读 LEARNER.json，下一句话即生效。
  //「从最近课次提炼」：LLM 读最新课次留档提炼草稿，整段替换「其他」输入框（只预填，
  //保存才落盘，用户把关）；无课次时按钮置灰；提炼消耗入 USAGE.jsonl（scene=提炼）。
  Future<void> _showLearnerEditDialog() async {
    final nameC = TextEditingController(
      text: _learner['name'] as String? ?? '',
    );
    final motivationC = TextEditingController(
      text: _learner['motivation'] as String? ?? '',
    );
    final extraC = TextEditingController(
      text: _learner['extra'] as String? ?? '',
    );
    bool? saved; //对话框返回值（true=保存）；放在 try 外供 finally 后续判断
    try {
      final hasLessons = (await StorageService().listChatFiles(
        widget.courseName,
      )).isNotEmpty;
      if (!mounted) return;
      var extracting = false; //提炼请求进行中（对话框内局部态，不走全局 busy Banner）
      saved = await showDialog<bool>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Text('编辑学习者档案'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameC,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: '称呼'),
                ),
                TextField(
                  controller: motivationC,
                  decoration: const InputDecoration(labelText: '学习动力'),
                ),
                TextField(
                  controller: extraC,
                  decoration: const InputDecoration(
                    labelText: '其他',
                    hintText: '选填，导师可见的补充信息',
                  ),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    //置灰：无课次记录（无材料）或提炼中；结果整段替换「其他」输入框，
                    //用户看过/改过随保存落盘（LLM 只预填草稿，不直接写档案）
                    onPressed: !hasLessons || extracting
                        ? null
                        : () async {
                            setDialogState(() => extracting = true);
                            try {
                              final draft = await TutorChatService()
                                  .extractLearnerExtra(
                                    courseName: widget.courseName,
                                  );
                              if (!context.mounted) return;
                              setDialogState(() => extracting = false);
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
                              setDialogState(() => extraC.text = draft);
                            } catch (e) {
                              if (!context.mounted) return;
                              setDialogState(() => extracting = false);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('提炼失败：$e'),
                                  duration: const Duration(seconds: 3),
                                ),
                              );
                            }
                          },
                    icon: extracting
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.auto_awesome, size: 16),
                    label: Text(extracting ? '提炼中…' : '从最近课次提炼'),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('保存'),
              ),
            ],
          ),
        ),
      );
    } finally {
      //对话框关闭（无论取消/保存/中途返回）都释放控制器，避免内存泄漏
      nameC.dispose();
      motivationC.dispose();
      extraC.dispose();
    }
    if (saved != true || !mounted) return; //取消即丢弃
    final name = nameC.text.trim();
    final motivation = motivationC.text.trim();
    if (name.isEmpty || motivation.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('称呼与学习动力不能为空'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    await StorageService().saveLearnerFields(
      widget.courseName,
      name: name,
      motivation: motivation,
      extra: extraC.text.trim(),
    );
    _load(); //重新读档刷新卡片
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
          Text(
            name,
            style: const TextStyle(fontSize: 13, color: Color(0xFF808080)),
          ),
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
