import 'package:flutter/cupertino.dart' show CupertinoPageRoute;
import 'package:flutter/material.dart';
import 'package:three_tutor/page/contact/tutor_intro_page.dart';
import 'package:three_tutor/service/storage.dart';
import 'package:three_tutor/theme/app_colors.dart';
import 'package:three_tutor/widget/paste_dialog.dart';
import 'package:three_tutor/widget/tutor_avatar.dart';

class TabContact extends StatefulWidget {
  const TabContact({super.key});

  @override
  State<TabContact> createState() => _TabContactState();
}

class _TabContactState extends State<TabContact> {
  //世界名 → 该世界导师名单（file + name）；平铺列表一次加载全量（世界数量少）
  Map<String, List<Map<String, dynamic>>> _worldTutors = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState(); //先执行 Flutter 自身的初始化
    _loadWorlds(); //页面出生时读取一次数据，之后 setState 只刷新界面不再重读
  }

  //读取所有世界与各世界的导师名单并刷新界面
  Future<void> _loadWorlds() async {
    final worlds = await StorageService().listWorlds();
    final worldTutors = <String, List<Map<String, dynamic>>>{};
    for (final world in worlds) {
      worldTutors[world] = await StorageService().loadWorldTutors(world);
    }
    if (!mounted) return; //await 等待期间页面可能已被销毁，先确认还活着再刷新
    setState(() {
      _worldTutors = worldTutors;
      _loading = false;
    });
  }

  //导入内置导师（3 个内置世界）并刷新界面
  Future<void> _importBuiltin() async {
    final message = await StorageService().importBuiltinWorlds();
    if (!mounted) return; //同上：页面销毁后 context 与 setState 都不能再用
    //底部弹出提示条，1 秒后自动消失，告知导入结果
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 1)),
    );
    _loadWorlds();
  }

  //导入外部导师：AI 生成的单份标记文本（主入口=粘贴剪贴板，次入口=选 .txt 回填）
  //→ 解析校验 → 命名 → 写成新世界。生成的世界与内置世界同权（建课拷贝快照、教学注入零差异）
  Future<void> _importCustomWorld() async {
    //1. 取文本：粘贴或选文件（选择器不可用不影响粘贴主路径）
    final text = await _pasteDialog();
    if (text == null || !mounted) return; //取消即不动

    //2. 解析校验（失败提示面向用户的消息，不中断流程）
    String parsedName;
    List<Map<String, dynamic>> tutors;
    try {
      final parsed = StorageService.parseTutorTemplate(text);
      parsedName = parsed.$1;
      tutors = parsed.$2;
    } on FormatException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.message),
          duration: const Duration(seconds: 3),
        ),
      );
      return;
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('读取失败：$e'),
          duration: const Duration(seconds: 3),
        ),
      );
      return;
    }

    //3. 世界名（预填模板内值）→ 落盘 → 刷新
    if (!mounted) return;
    final name = await _worldNameDialog(initial: parsedName);
    if (name == null || !mounted) return; //取消即不动
    try {
      await StorageService().saveTutorWorld(name, tutors);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e'), duration: const Duration(seconds: 2)),
      );
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('导师组「$name」已导入'),
        duration: const Duration(seconds: 1),
      ),
    );
    _loadWorlds();
  }

  //粘贴对话框（已抽为共享组件 widget/paste_dialog.dart，与教学大纲导入共用交互）
  Future<String?> _pasteDialog() {
    return showPasteImportDialog(
      context,
      title: '导入外部导师',
      hint: '粘贴按「导师参考提示词」生成的全文…',
    );
  }

  //世界名弹窗：预填模板内世界名（可改）；必填 + 重名校验（确定时异步查，错误显示在框内）
  Future<String?> _worldNameDialog({String initial = ''}) {
    final nameC = TextEditingController(text: initial);
    String? error;
    return showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('导师组命名'),
          content: TextField(
            controller: nameC,
            autofocus: true,
            decoration: InputDecoration(
              labelText: '世界名',
              hintText: '将出现在通讯录与建课流程中',
              errorText: error,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                final name = nameC.text.trim();
                if (name.isEmpty) {
                  setDialogState(() => error = '不能为空');
                  return;
                }
                if (await (await StorageService().getWorldDir(name)).exists()) {
                  setDialogState(() => error = '同名世界已存在');
                  return;
                }
                if (context.mounted) Navigator.pop(context, name);
              },
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
  }

  //删除世界：第 1 步弹出对话框选择要删的世界，第 2 步红字二次确认
  Future<void> _showDeleteWorldDialog() async {
    //没有世界可删时直接提示返回
    if (_worldTutors.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('当前没有世界可删除'),
          duration: Duration(seconds: 1),
        ),
      );
      return;
    }

    //第 1 步：列出所有世界供选择，点选后返回所选世界名
    final world = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('选择要删除的世界'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: _worldTutors.length,
            itemBuilder: (context, i) => ListTile(
              title: Text(_worldTutors.keys.elementAt(i)),
              onTap: () => Navigator.pop(context, _worldTutors.keys.elementAt(i)),
            ),
          ),
        ),
      ),
    );
    if (world == null || !mounted) return; //取消选择

    //第 2 步：红字二次确认
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除「$world」？'),
        content: const Text('删除后不可恢复，确定删除？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: AppColors.of(context).danger,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await StorageService().deleteWorld(world);
    if (!mounted) return;
    _loadWorlds(); //重读全量数据刷新列表
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        //背景与滚动行为继承全局 appBarTheme（浅灰顶栏）
        title: const Text('三人师'),
        actions: [
          PopupMenuButton(
            icon: const Icon(Icons.settings),
            onSelected: (value) async {
              switch (value) {
                case 'builtin':
                  await _importBuiltin();
                case 'custom':
                  await _importCustomWorld();
                case 'delete':
                  await _showDeleteWorldDialog();
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'builtin', child: Text('导入内置导师')),
              PopupMenuItem(value: 'custom', child: Text('导入外部导师')),
              PopupMenuItem(value: 'delete', child: Text('删除某个世界')),
            ],
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    //加载中
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    //空状态：提示待导入，并提供导入入口
    if (_worldTutors.isEmpty) {
      final c = AppColors.of(context);
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min, //只占内容大小，才能被外层 Center 居中（默认 max 会撑满全屏）
          children: [
            Icon(Icons.public, size: 64, color: c.iconFaint),
            const SizedBox(height: 12),
            Text('待导入', style: TextStyle(fontSize: 18, color: c.textFaint)),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _importBuiltin,
              icon: const Icon(Icons.download),
              label: const Text('导入内置导师'),
            ),
          ],
        ),
      );
    }

    //平铺列表：每个世界一个灰色小字分组标题，下面平铺该世界全部导师
    return ListView.builder(
      itemCount: _worldTutors.length,
      itemBuilder: (context, index) {
        final world = _worldTutors.keys.elementAt(index);
        return Column(
          children: [
            _buildGroupTitle(world),
            for (final tutor in _worldTutors[world]!) _buildTutorRow(world, tutor),
          ],
        );
      },
    );
  }

  //灰色小字分组标题（与页面同底色，只靠小号灰字区分层级）
  //SizedBox 强制占满整行：ListView 子项默认按内容收缩并居中，不占满宽度文字就会居中
  Widget _buildGroupTitle(String world) {
    return SizedBox(
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Text(
          world,
          style: TextStyle(
            fontSize: 13,
            color: AppColors.of(context).textFaint,
          ),
        ),
      ),
    );
  }

  //导师行：头像 + 导师名，点击进入导师资料页
  //头像自然把名字推到右侧，与贴左的分组标题形成层级（无需额外缩进）
  //分割线从头像右侧起（16+40+16=72），细线风格
  Widget _buildTutorRow(String world, Map<String, dynamic> tutor) {
    return Material(
      color: AppColors.of(context).surface,
      child: Column(
        children: [
          ListTile(
            leading: TutorAvatar(
              name: tutor['name'] as String,
              size: 40,
              imageDir: tutor['dir'] as String?,
              fileName: tutor['file'] as String?,
            ),
            title: Text(tutor['name'] as String),
            onTap: () {
              Navigator.push(
                context,
                CupertinoPageRoute(
                  builder: (context) => TutorIntroPage(
                    worldName: world,
                    fileName: tutor['file'] as String,
                  ),
                ),
              );
            },
          ),
          const Divider(height: 1, indent: 72), //颜色与粗细继承全局 dividerTheme
        ],
      ),
    );
  }
}
