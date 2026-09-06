import 'package:flutter/cupertino.dart' show CupertinoPageRoute;
import 'package:flutter/material.dart';
import 'package:tutor_chat/page/chat/group_chat_page.dart';
import 'package:tutor_chat/service/storage.dart';
import 'package:tutor_chat/widget/tutor_avatar.dart';

//聊天页 = 会话列表：每行一个课程群聊（微信会话样式）
//群名 + 最后一条消息预览 + 时间；点击进入群聊页（待实现）
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
    _loadConversations();
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
      appBar: AppBar(title: const Text('TutorChat')), //无右上按钮：建课入口在通讯录
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
      //行间细分割线：从头像右侧起（微信样式）
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
    //日期格式：2026-08-04 → 08-04（当年显示，往年补年份）
    final timeText = date.isEmpty ? '' : date.substring(5);

    return Material(
      color: Colors.white, //白底同时是按压水波纹的载体
      child: InkWell(
        onTap: () {
          Navigator.push(
            context,
            CupertinoPageRoute(
              builder: (context) => GroupChatPage(courseName: name),
            ),
          );
        },
        onLongPress: () => _showConversationMenu(name),
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
                    Text(
                      preview,
                      style: const TextStyle(fontSize: 14, color: Color(0xFF999999)),
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

  //长按会话：更名 / 删除课程（微信长按会话交互）
  Future<void> _showConversationMenu(String courseName) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('更名'),
              onTap: () => Navigator.pop(context, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: const Text(
                '删除课程',
                style: TextStyle(color: Colors.red),
              ),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return; //用户取消
    if (action == 'rename') await _renameCourse(courseName);
    if (action == 'delete') await _deleteCourse(courseName);
  }

  //更名课程：弹重命名对话框，成功后刷新列表
  Future<void> _renameCourse(String oldName) async {
    final controller = TextEditingController(text: oldName);
    final newName = await showDialog<String>(
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

  //删除课程：红字二次确认后删除整个课程目录
  Future<void> _deleteCourse(String courseName) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除「$courseName」？'),
        content: const Text('删除后不可恢复，确定删除？'),
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
    await StorageService().deleteCourse(courseName);
    if (!mounted) return;
    _loadConversations();
  }
}
