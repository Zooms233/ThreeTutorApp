import 'package:flutter/cupertino.dart' show CupertinoPageRoute;
import 'package:flutter/material.dart';
import 'package:three_tutor/page/chat/group_chat_page.dart';
import 'package:three_tutor/page/contact/create_course_page.dart';
import 'package:three_tutor/widget/tutor_avatar.dart';
import 'package:three_tutor/page/contact/tutor_profile_page.dart';
import 'package:three_tutor/service/storage.dart';

//导师资料页：联系人资料样式，从这里进档案、创建课程或进入已有课程群聊
class TutorIntroPage extends StatefulWidget {
  const TutorIntroPage({
    super.key,
    required this.worldName,
    required this.fileName,
  });

  final String worldName;
  final String fileName; //如 tutor_a.json

  @override
  State<TutorIntroPage> createState() => _TutorIntroPageState();
}

class _TutorIntroPageState extends State<TutorIntroPage> {
  Map<String, dynamic>? _profile; //导师档案（名字与身份）
  String? _imageDir; //世界目录路径（头像图片查找用）
  bool _loading = true;
  List<String> _courses = []; //该导师参与的课程名单
  bool _coursesLoading = true;

  @override
  void initState() {
    super.initState(); //先执行 Flutter 自身的初始化
    _loadProfile();
    _loadCourses();
  }

  //读取导师档案并刷新界面（同时记下世界目录路径供头像查找图片）
  Future<void> _loadProfile() async {
    final profile = await StorageService().loadTutorProfile(
      widget.worldName,
      widget.fileName,
    );
    final worldDir = await StorageService().getWorldDir(widget.worldName);
    if (!mounted) return; //await 等待期间页面可能已被销毁，先确认还活着再刷新
    setState(() {
      _profile = profile;
      _imageDir = worldDir.path;
      _loading = false;
    });
  }

  //扫描该导师参与的课程列表
  Future<void> _loadCourses() async {
    final courses = await StorageService().findCoursesByTutor(
      widget.worldName,
      widget.fileName,
    );
    if (!mounted) return;
    setState(() {
      _courses = courses;
      _coursesLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('')), //Banner 仅返回按钮（设计如此）
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    //档案未加载完成
    if (_loading || _profile == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final name = _profile!['name'] as String? ?? '未知导师';
    final identity = _profile!['identity'] as String? ?? '';

    return ListView(
      children: [
        //头部：白底块，头像左 + 名字/身份右（资料页头部样式）
        Container(
          width: double.infinity,
          color: Colors.white,
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              TutorAvatar(
                name: name,
                size: 64,
                imageDir: _imageDir,
                fileName: widget.fileName,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (identity.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        identity,
                        style: const TextStyle(
                          fontSize: 14,
                          color: Color(0xFF999999),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8), //灰色分组间隙
        //导师资料行：进入导师档案详情页
        _buildRow(
          '导师资料',
          onTap: () {
            Navigator.push(
              context,
              CupertinoPageRoute(
                builder: (context) => TutorProfilePage(
                  worldName: widget.worldName,
                  fileName: widget.fileName,
                ),
              ),
            );
          },
        ),
        //创建群聊行：始终显示（一个世界可建多个群聊）
        _buildRow('创建群聊', onTap: _openCreateCourse),
        //进入群聊行：无课程提示先创建；仅一个直达；多个弹出选择菜单
        _buildRow('进入群聊', onTap: _openGroupChat),
      ],
    );
  }

  //白色行按钮：标题左对齐 + 右侧箭头（资料页行样式）
  Widget _buildRow(String title, {VoidCallback? onTap}) {
    return Material(
      color: Colors.white, //白底同时是按压水波纹的载体
      child: ListTile(
        title: Text(title),
        trailing: const Icon(Icons.chevron_right, color: Color(0xFFC8C8C8)),
        onTap: onTap,
      ),
    );
  }

  //进入创建课程表单；返回后刷新课程列表（可能已建课）
  Future<void> _openCreateCourse() async {
    await Navigator.push(
      context,
      CupertinoPageRoute(
        builder: (context) => CreateCoursePage(worldName: widget.worldName),
      ),
    );
    if (!mounted) return;
    _loadCourses();
  }

  //进入群聊：按课程数量分流——无课程提示、单课程直达、多课程弹底部菜单
  Future<void> _openGroupChat() async {
    //课程名单还在扫描中
    if (_coursesLoading) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('正在扫描课程…'),
          duration: Duration(seconds: 1),
        ),
      );
      return;
    }

    //该导师暂无课程
    if (_courses.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('该导师暂无群聊，可先「创建群聊」'),
          duration: Duration(seconds: 1),
        ),
      );
      return;
    }

    //仅一个课程：直接进入（清栈，只留 HomePage：返回时落聊天页会话列表）
    if (_courses.length == 1) {
      Navigator.pushAndRemoveUntil(
        context,
        CupertinoPageRoute(
          builder: (_) => GroupChatPage(courseName: _courses.first),
        ),
        (route) => route.isFirst, //保留栈底 HomePage，其余全清
      );
      return;
    }

    //多个课程：底部菜单选择
    final selected = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final c in _courses)
              ListTile(title: Text(c), onTap: () => Navigator.pop(context, c)),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) return; //用户取消选择
    //直接进入该课程群聊页（清栈，只留 HomePage：返回时落聊天页会话列表）
    Navigator.pushAndRemoveUntil(
      context,
      CupertinoPageRoute(
        builder: (_) => GroupChatPage(courseName: selected),
      ),
      (route) => route.isFirst, //保留栈底 HomePage，其余全清
    );
  }
}
