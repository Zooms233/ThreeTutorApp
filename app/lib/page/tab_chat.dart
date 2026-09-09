import 'package:flutter/cupertino.dart' show CupertinoPageRoute;
import 'package:flutter/material.dart';
import 'package:three_tutor/main.dart';
import 'package:three_tutor/page/chat/group_chat_page.dart';
import 'package:three_tutor/service/storage.dart';
import 'package:three_tutor/service/three_tutor_service.dart';
import 'package:three_tutor/widget/tutor_avatar.dart';

//聊天页 = 会话列表：每行一个课程群聊（会话列表样式）
//群名 + 最后一条消息预览 + 时间；点击进入群聊页；更名/删除入口在 AppBar 齿轮菜单
class TabChat extends StatefulWidget {
  const TabChat({super.key});

  @override
  State<TabChat> createState() => _TabChatState();
}

class _TabChatState extends State<TabChat> {
  List<Map<String, dynamic>> _conversations = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState(); //先执行 Flutter 自身的初始化
    //监听共享 busy 表：任一课程生成中，对应会话行预览位置显示绿色小字
    ThreeTutorService.busyVersion.addListener(_onBusyChanged);
    //IndexedStack 保活后本页 State 不随 tab 切换重建，需自行监听 tab 索引：
    //切回聊天 tab 即重扫（通讯录建课/更名后回来列表才不会是旧数据）
    HomePage.pageIndex.addListener(_onTabChanged);
    _loadConversations();
  }

  @override
  void dispose() {
    ThreeTutorService.busyVersion.removeListener(_onBusyChanged);
    HomePage.pageIndex.removeListener(_onTabChanged);
    super.dispose();
  }

  //切回聊天 tab 时重扫会话列表（目录轻，重扫毫秒级）
  void _onTabChanged() {
    if (HomePage.pageIndex.value == 0 && mounted) _loadConversations();
  }

  void _onBusyChanged() {
    if (mounted) setState(() {}); //busy 文案经 busyLabelOf 即时读取
  }

  //扫描课程目录并刷新会话列表
  Future<void> _loadConversations() async {
    final conversations = await StorageService().listConversations();
    if (!mounted) return; //await 等待期间页面可能已被销毁，先确认还活着再刷新
    setState(() {
      _conversations = conversations;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('三人师'),
        actions: [
          //管理菜单（与通讯录页同款齿轮）：更名 / 删除群聊；建课入口仍在通讯录
          PopupMenuButton(
            icon: const Icon(Icons.settings),
            onSelected: (value) async {
              switch (value) {
                case 'rename':
                  await _showRenameCourseDialog();
                case 'delete':
                  await _showDeleteCourseDialog();
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'rename', child: Text('更名群聊')),
              PopupMenuItem(value: 'delete', child: Text('删除群聊')),
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

    //空状态：引导去通讯录建课
    if (_conversations.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min, //只占内容大小，才能被外层 Center 居中
          children: [
            Icon(Icons.forum, size: 64, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text(
              '前往通讯录，选择导师创建群聊',
              style: TextStyle(fontSize: 16, color: Colors.grey.shade600),
            ),
          ],
        ),
      );
    }

    //会话列表
    return ListView.separated(
      itemCount: _conversations.length,
      //行间细分割线：从头像右侧起（细线风格）
      separatorBuilder: (_, _) => const Divider(height: 0.5, indent: 72),
      itemBuilder: (context, index) {
        final conversation = _conversations[index];
        return _buildRow(conversation);
      },
    );
  }

  //会话行：白底 + 头像 + 群名/预览 + 时间
  Widget _buildRow(Map<String, dynamic> conversation) {
    final name = conversation['name'] as String;
    final preview = conversation['preview'] as String;
    final date = conversation['date'] as String;
    //日期恒显示 MM-DD（与预览同行，年份不展示；date 格式由 listConversations 保证）
    final timeText = date.isEmpty ? '' : date.substring(5);

    return Material(
      color: Colors.white, //白底同时是按压水波纹的载体
      child: InkWell(
        onTap: () async {
          //从群聊页返回即刷新列表：预览/排序跟随最新落档（群聊页内生成的新消息）
          await Navigator.push(
            context,
            CupertinoPageRoute(
              builder: (context) => GroupChatPage(courseName: name),
            ),
          );
          _loadConversations();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              //群头像：课程名首字占位（待导师头像就位后升级九宫格）
              TutorAvatar(name: name),
              const SizedBox(width: 12),
              //群名 + 预览
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(fontSize: 16, color: Color(0xFF191919)),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    //生成中：预览位置显示绿色小字（「对方正在输入…」风格）
                    Text(
                      ThreeTutorService.busyLabelOf(name).isEmpty
                          ? preview
                          : ThreeTutorService.busyLabelOf(name),
                      style: TextStyle(
                        fontSize: 14,
                        color: ThreeTutorService.busyLabelOf(name).isEmpty
                            ? const Color(0xFF999999)
                            : const Color(0xFF07C160),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              //时间：右上方小字（与群名同高）
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(
                  timeText,
                  style: const TextStyle(fontSize: 12, color: Color(0xFFB0B0B0)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  //菜单第 1 步：列出全部群聊供选择；无群聊时提示并返回 null（取消）
  Future<String?> _pickCourse(String title) async {
    if (_conversations.isEmpty) {
      if (!mounted) return null;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('当前没有群聊'),
          duration: Duration(seconds: 1),
        ),
      );
      return null;
    }
    if (!mounted) return null;
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        //限高：群聊多时列表内滚动，避免对话框溢出屏幕
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 400),
          child: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _conversations.length,
              itemBuilder: (context, i) {
                final name = _conversations[i]['name'] as String;
                return ListTile(
                  title: Text(name),
                  onTap: () => Navigator.pop(context, name),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  //更名群聊：选课程 → 弹重命名对话框（预填旧名），成功后刷新列表
  Future<void> _showRenameCourseDialog() async {
    final oldName = await _pickCourse('选择要更名的群聊');
    if (oldName == null || !mounted) return; //取消选择
    final controller = TextEditingController(text: oldName);
    String? newName;
    try {
      newName = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('更名课程'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: '课程名（即群名）'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('确定'),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose(); //对话框关闭后释放控制器，避免内存泄漏
    }
    if (newName == null || newName.isEmpty || !mounted) return; //取消或空名
    final error = await StorageService().renameCourse(oldName, newName);
    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error), duration: const Duration(seconds: 1)),
      );
      return;
    }
    _loadConversations();
  }

  //删除群聊：选课程 → 红字二次确认 → 删除整个课程目录并刷新列表
  Future<void> _showDeleteCourseDialog() async {
    final course = await _pickCourse('选择要删除的群聊');
    if (course == null || !mounted) return; //取消选择
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除「$course」？'),
        content: const Text('将删除该群聊的全部对话与学习进度，删除后不可恢复。确定删除？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await StorageService().deleteCourse(course);
    if (!mounted) return;
    _loadConversations();
  }
}
