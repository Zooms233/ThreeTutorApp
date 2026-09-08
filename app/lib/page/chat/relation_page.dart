import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:three_tutor/service/storage.dart';
import 'package:three_tutor/service/three_tutor_service.dart';

//课程资料页（原关系页）：学习者信息 + 教学大纲/材料管理 + 导师关系
//建课字段的建后管理入口：学习者（称呼/动力/其他）与大纲/材料均与建课表单一致；
//导师关系段由课后更新维护，只读。数据来自课程内副本（课后更新后为最新版本）。
class RelationPage extends StatefulWidget {
  const RelationPage({super.key, required this.courseName});

  final String courseName;

  @override
  State<RelationPage> createState() => _RelationPageState();
}

class _RelationPageState extends State<RelationPage> {
  Map<String, dynamic> _learner = {}; //学习者档案（name/motivation/extra）
  List<Map<String, dynamic>> _relations = []; //导师 name + relation（tutor_a→b→c）
  Map<String, List<String>> _materials = {}; //教学材料：outline/textbook 文件名单
  bool _loading = true;

  @override
  void initState() {
    super.initState(); //先执行 Flutter 自身的初始化
    _load();
  }

  //读取学习者档案、导师关系与教学材料并刷新
  Future<void> _load() async {
    final learner = await StorageService().loadCourseLearner(widget.courseName);
    final relations = await StorageService().loadCourseTutorRelations(
      widget.courseName,
    );
    final materials = await StorageService().listCourseMaterials(
      widget.courseName,
    );
    if (!mounted) return; //await 等待期间页面可能已被销毁，先确认还活着再刷新
    setState(() {
      _learner = learner;
      _relations = relations;
      _materials = materials;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('课程资料')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                _buildLearnerCard(),
                _buildSyllabusCard(),
                _buildTextbookCard(),
                _buildRelationsCard(),
              ],
            ),
    );
  }

  // —— 教学大纲 / 教学材料（添加、删除）——

  //选择文件并导入指定分区；大纲仅一份（自动覆盖旧文件）
  Future<void> _addMaterial(String sub) async {
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
    final error = await StorageService().addCourseMaterial(
      widget.courseName,
      sub,
      file.path,
    );
    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error), duration: const Duration(seconds: 2)),
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已导入'),
        duration: Duration(seconds: 1),
      ),
    );
    _load();
  }

  //删除确认（破坏性操作，二次确认）
  Future<void> _confirmDelete(String sub, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除「$name」？'),
        content: const Text('删除后 AI 将无法再查阅该文件。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await StorageService().deleteCourseMaterial(
      widget.courseName,
      sub,
      name,
    );
    _load();
  }

  //教学大纲卡：仅一份，添加/更换
  Widget _buildSyllabusCard() {
    final names = _materials['outline'] ?? const [];
    final current = names.isEmpty ? null : names.first;
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
                '教学大纲',
                style: TextStyle(fontSize: 13, color: Color(0xFF808080)),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => _addMaterial('OUTLINE'),
                child: Text(current == null ? '添加' : '更换'),
              ),
            ],
          ),
          Text(
            current ?? '未设置（教学相长模式：师生共同商定学习方向）',
            style: const TextStyle(fontSize: 14, color: Color(0xFF191919)),
          ),
          const SizedBox(height: 4),
          const Text(
            '大纲定义教学范围，有则按大纲推进；文本文件（md/txt）',
            style: TextStyle(fontSize: 12, color: Color(0xFF999999)),
          ),
        ],
      ),
    );
  }

  //教学材料卡：多文件列表，可删除（二次确认）与添加
  Widget _buildTextbookCard() {
    final names = _materials['textbook'] ?? const [];
    return Container(
      color: Colors.white,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '教学材料',
                style: TextStyle(fontSize: 13, color: Color(0xFF808080)),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => _addMaterial('TEXTBOOK'),
                child: const Text('添加文件'),
              ),
            ],
          ),
          if (names.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 4),
              child: Text(
                '未添加（参考资料，AI 按需查阅；文本文件 md/txt）',
                style: TextStyle(fontSize: 12, color: Color(0xFF999999)),
              ),
            )
          else
            for (final name in names)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        name,
                        style: const TextStyle(
                          fontSize: 14,
                          color: Color(0xFF191919),
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    GestureDetector(
                      onTap: () => _confirmDelete('TEXTBOOK', name),
                      child: const Icon(
                        Icons.delete_outline,
                        size: 18,
                        color: Color(0xFF999999),
                      ),
                    ),
                  ],
                ),
              ),
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
                              final draft = await ThreeTutorService()
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

  //导师评价卡：三位导师对学习者的评价合并一块（导师名 + 评价，行间分隔线）
  Widget _buildRelationsCard() {
    return Container(
      color: Colors.white,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '导师对学习者的评价',
            style: TextStyle(fontSize: 13, color: Color(0xFF808080)),
          ),
          const SizedBox(height: 4),
          for (var i = 0; i < _relations.length; i++) ...[
            if (i > 0) const Divider(height: 24),
            Text(
              _relations[i]['name'] as String? ?? '',
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Color(0xFF191919),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              (_relations[i]['relation'] as String? ?? '').isEmpty
                  ? '尚未建立评价记录'
                  : _relations[i]['relation'] as String,
              style: const TextStyle(
                fontSize: 15,
                height: 1.5,
                color: Color(0xFF191919),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
