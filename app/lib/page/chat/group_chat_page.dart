import 'package:flutter/cupertino.dart' show CupertinoPageRoute;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tutor_chat/page/chat/course_detail_page.dart';
import 'package:tutor_chat/service/storage.dart';
import 'package:tutor_chat/widget/tutor_avatar.dart';

//群聊页：课程对话与课后闲聊同一消息流
//按需加载：优先渲染最近课次，上滑到顶加载更早课次（微信行为）
//本阶段为只读壳子：输入框禁用；收发与 ⋮ 菜单待实现
class GroupChatPage extends StatefulWidget {
  const GroupChatPage({super.key, required this.courseName});

  final String courseName; //群名 = 课程名

  @override
  State<GroupChatPage> createState() => _GroupChatPageState();
}

//消息流渲染单元：系统分隔行或消息行
class _ChatItem {
  const _ChatItem.divider(this.text) : message = null;
  const _ChatItem.message(this.message) : text = null;

  final String? text; //分隔行文本
  final Map<String, dynamic>? message; //消息行数据
}

class _GroupChatPageState extends State<GroupChatPage> {
  //初始补足阈值：已加载消息达到此数量即停止向前补（约一屏消息量）
  static const _initialMinMessages = 20;

  //是否桌面端（桌面支持 Ctrl+Enter 快捷发送；移动端软键盘 Enter 即换行）
  bool get _isDesktop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  List<String> _files = []; //全部课次文件路径（旧 → 新，只查名单不读内容）
  List<Map<String, dynamic>> _entries = []; //已加载的消息条目（从最新往前）
  List<_ChatItem> _items = []; //渲染单元（分隔行 + 消息）
  int _loadedCount = 0; //已从最新往回加载的课次数
  bool _hasMore = false; //是否还有更早的课次未加载
  bool _loadingMore = false; //上滑加载中（防重复触发）
  Map<String, String> _tutorFiles = {}; //导师名 → 档案文件名（头像图片查找用）
  String _courseDirPath = ''; //课程目录路径（头像图片查找用）
  String _learnerName = ''; //用户称呼（用户消息显示与写档用）
  String _currentTutor = ''; //当前课次授课导师（模拟回复与「正在输入中」用）
  bool _sending = false; //模拟回复进行中（Banner 提示 + 输入框暂锁）
  bool _loading = true;
  final _scrollController = ScrollController();
  final _inputController = TextEditingController(); //输入框

  @override
  void initState() {
    super.initState(); //先执行 Flutter 自身的初始化
    _scrollController.addListener(_onScroll); //滑到顶部附近时加载更早课次
    _load();
  }

  @override
  void dispose() {
    _scrollController.dispose(); //页面销毁时释放滚动控制器
    _inputController.dispose(); //释放输入控制器，避免内存泄漏
    super.dispose();
  }

  //初始加载：最近课次优先；内容不足一屏时继续向前补足
  //（否则内容顶死在顶部，上滑不会产生滚动事件，更早课次将永远无法触发加载）
  Future<void> _load() async {
    final files = await StorageService().listChatFiles(widget.courseName);
    final tutorFiles = await StorageService().loadCourseTutorFiles(
      widget.courseName,
    );
    final courseDir = await StorageService().getCourseDir(widget.courseName);
    final learner = await StorageService().loadCourseLearner(widget.courseName);

    if (!mounted) return; //await 等待期间页面可能已被销毁，先确认还活着再刷新

    //从未上课：只显示加入群聊的系统行（此后不存在空白消息页）
    if (files.isEmpty) {
      setState(() {
        _files = files;
        _tutorFiles = tutorFiles;
        _courseDirPath = courseDir.path;
        _learnerName = learner['name'] as String? ?? '我';
        _items = [const _ChatItem.divider('你加入了群聊，现在可以开始聊天了')];
        _loading = false;
      });
      return;
    }

    //从最新课次往前加载，直到凑够约一屏消息或加载完全部课次
    var entries = <Map<String, dynamic>>[];
    var loaded = 0;
    while (loaded < files.length) {
      final chunk = await StorageService().loadChatFile(
        files[files.length - 1 - loaded],
      );
      entries = [...chunk, ...entries];
      loaded++;
      final messageCount = entries
          .where((e) => e['type'] == 'message')
          .length;
      if (messageCount >= _initialMinMessages) break;
    }

    if (!mounted) return;
    setState(() {
      _files = files;
      _entries = entries;
      _loadedCount = loaded;
      _hasMore = loaded < files.length;
      _tutorFiles = tutorFiles;
      _courseDirPath = courseDir.path;
      _learnerName = learner['name'] as String? ?? '我';
      _items = _buildItems(entries, hasMore: _hasMore).reversed.toList();
      _loading = false;
    });
  }

  //上滑到顶：加载更早的课次（每次 1 个）
  //reverse 列表中更早内容在远端，插入后当前视口天然不动，无需手动锚定
  Future<void> _loadEarlier() async {
    if (!_hasMore || _loadingMore || _loading) return;
    _loadingMore = true;

    final index = _files.length - _loadedCount - 1; //下一个要加载的更早课次
    final earlier = await StorageService().loadChatFile(_files[index]);

    if (!mounted) return;
    setState(() {
      _entries = [...earlier, ..._entries]; //更早条目插入头部，保持旧→新顺序
      _loadedCount++;
      _hasMore = _loadedCount < _files.length;
      _items = _buildItems(_entries, hasMore: _hasMore).reversed.toList();
    });
    _loadingMore = false;
  }

  //滚动监听：接近更早内容端（reverse 列表的大 offset 方向）时加载更早课次
  void _onScroll() {
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 60) {
      _loadEarlier();
    }
  }

  //发送消息并生成模拟回复（后续替换为 LLM 调用，写入与 UI 逻辑不变）
  //写入规则：追加到最新课次文件（无课次时自动开第 1 课）；不做「开始上课」状态机触发
  Future<void> _sendMessage() async {
    final text = _inputController.text.trim();
    if (text.isEmpty || _sending) return;
    _inputController.clear();

    //定位当前课次（无课次时自动创建第 1 课 meta，tutor 取 STATE 的 next_tutor）
    final lesson = await StorageService().getCurrentLesson(widget.courseName);
    final filePath = lesson['path'] as String;
    final tutorName = lesson['tutor'] as String;

    //写入用户消息（先写后说）
    final userMessage = {
      'type': 'message',
      'phase': 'teaching',
      'role': 'user',
      'name': _learnerName,
      'content': text,
    };
    await StorageService().appendChatMessage(filePath, userMessage);
    if (!mounted) return;
    setState(() {
      _currentTutor = tutorName;
      _sending = true; //模拟回复生成中
      _entries = [..._entries, userMessage];
      _items = _buildItems(_entries, hasMore: _hasMore).reversed.toList();
    });
    _scrollToBottom();

    //模拟回复：「嗯，」+ 用户输入；本地短暂延迟模拟生成耗时
    final reply = {
      'type': 'message',
      'phase': 'teaching',
      'role': 'tutor',
      'name': tutorName,
      'content': '嗯，$text',
    };
    await Future.delayed(const Duration(milliseconds: 500));
    await StorageService().appendChatMessage(filePath, reply);
    if (!mounted) return;
    setState(() {
      _sending = false;
      _entries = [..._entries, reply];
      _items = _buildItems(_entries, hasMore: _hasMore).reversed.toList();
    });
    _scrollToBottom();
  }

  //滚动到最底部（最新消息；reverse 列表的 offset 0 即底部）
  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
  }

  //把消息流条目转成渲染单元（插入课次分隔行与「下课后」分隔行）
  List<_ChatItem> _buildItems(
    List<Map<String, dynamic>> entries, {
    required bool hasMore,
  }) {
    final items = <_ChatItem>[];

    //更早课次已全部加载：顶部提示没有更多
    if (entries.isNotEmpty && !hasMore) {
      items.add(const _ChatItem.divider('没有更多了'));
    }

    //从未上课：只显示加入群聊的系统行（此后不存在空白消息页）
    if (entries.isEmpty) {
      items.add(const _ChatItem.divider('你加入了群聊，现在可以开始聊天了'));
      return items;
    }

    var seenSocial = false; //当前课内是否已插入「下课后」（每个新课重置）
    for (final entry in entries) {
      if (entry['type'] == 'meta') {
        final date = entry['date'] as String? ?? '';
        final shortDate = date.length >= 10 ? date.substring(5) : date;
        items.add(
          _ChatItem.divider(
            '第 ${entry['lesson']} 课 · ${entry['tutor']} · $shortDate',
          ),
        );
        seenSocial = false; //新课开始，重置课后标记（每课的课后闲聊各自插入）
      } else {
        final phase = entry['phase'] as String? ?? 'teaching';
        if (phase == 'social' && !seenSocial) {
          items.add(const _ChatItem.divider('下课后'));
          seenSocial = true;
        }
        items.add(_ChatItem.message(entry));
      }
    }
    return items;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          //模拟回复生成期间显示「正在输入中」（后续接入 LLM 沿用同一逻辑）
          _sending && _currentTutor.isNotEmpty
              ? '$_currentTutor 正在输入中…'
              : widget.courseName,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.query_stats),
            tooltip: '课程详情',
            onPressed: () {
              Navigator.push(
                context,
                CupertinoPageRoute(
                  builder: (context) => CourseDetailPage(
                    courseName: widget.courseName,
                  ),
                ),
              );
            },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: Column(
                children: [
                  Expanded(child: _buildMessageList()),
                  _buildInputBar(), //只读阶段的完整形态预览：禁用
                ],
              ),
            ),
    );
  }

  Widget _buildMessageList() {
    return ListView.builder(
      controller: _scrollController,
      reverse: true, //从底部（最新消息）开始渲染：进入无跳屏，上滑加载天然锚定
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _items.length,
      itemBuilder: (context, index) {
        final item = _items[index];
        return item.text != null
            ? _buildDivider(item.text!)
            : _buildMessage(item.message!);
      },
    );
  }

  //系统分隔行：两侧细线 + 居中小字（课次分隔 / 下课后 / 加入群聊 / 没有更多了）
  Widget _buildDivider(String text) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 24),
      child: Row(
        children: [
          const Expanded(child: Divider(color: Color(0xFFDCDCDC))),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              text,
              style: const TextStyle(fontSize: 12, color: Color(0xFFB0B0B0)),
            ),
          ),
          const Expanded(child: Divider(color: Color(0xFFDCDCDC))),
        ],
      ),
    );
  }

  //消息行：导师消息左对齐（头像+名字+白气泡），用户消息右对齐（绿气泡+头像）
  Widget _buildMessage(Map<String, dynamic> message) {
    final role = message['role'] as String? ?? 'tutor';
    final name = message['name'] as String? ?? '';
    final content = _plainText(message['content'] as String? ?? '');

    return role == 'user'
        ? _buildUserMessage(name, content)
        : _buildTutorMessage(name, content);
  }

  //消息正文清洗：去斜体/加粗星号与标题#号；公式原样保留（待渲染包接入）
  static String _plainText(String text) {
    return text
        .replaceAll(RegExp(r'\*+'), '')
        .replaceAll(RegExp(r'^#+\s*', multiLine: true), '')
        .trim();
  }

  //导师消息：头像 + 名字 + 白色气泡，左对齐；气泡最大宽度约屏宽 72%
  Widget _buildTutorMessage(String name, String content) {
    final maxWidth = MediaQuery.sizeOf(context).width * 0.72;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TutorAvatar(
            name: name,
            size: 40,
            imageDir: _courseDirPath,
            fileName: _tutorFiles[name], //按导师名找到档案文件名 → 检测同名头像图片
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                style: const TextStyle(fontSize: 12, color: Color(0xFF999999)),
              ),
              const SizedBox(height: 2),
              Container(
                constraints: BoxConstraints(maxWidth: maxWidth),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(12),
                    topRight: Radius.circular(12),
                    bottomLeft: Radius.circular(4), //靠头像侧小圆角（微信细节）
                    bottomRight: Radius.circular(12),
                  ),
                ),
                child: Text(
                  content,
                  style: const TextStyle(fontSize: 15, height: 1.4),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  //用户消息：绿色气泡（微信 #95EC69）+ 头像，右对齐；群聊里自己消息不显示名字
  Widget _buildUserMessage(String name, String content) {
    final maxWidth = MediaQuery.sizeOf(context).width * 0.72;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flexible(
            child: Container(
              constraints: BoxConstraints(maxWidth: maxWidth),
              padding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 10,
              ),
              decoration: const BoxDecoration(
                color: Color(0xFF95EC69),
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(12),
                  topRight: Radius.circular(12),
                  bottomLeft: Radius.circular(12),
                  bottomRight: Radius.circular(4), //靠头像侧小圆角（微信细节）
                ),
              ),
              child: Text(
                content,
                style: const TextStyle(fontSize: 15, height: 1.4),
              ),
            ),
          ),
          const SizedBox(width: 8),
          TutorAvatar(name: name, size: 40), //用户头像：称呼首字占位
        ],
      ),
    );
  }

  //输入条：输入可用（发送按钮随内容与发送状态启停）
  Widget _buildInputBar() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: Focus(
              //桌面端：Ctrl+Enter 发送，Enter 换行；移动端不拦截（软键盘 Enter 即换行，靠按钮发送）
              onKeyEvent: (node, event) {
                if (!_isDesktop) return KeyEventResult.ignored;
                if (event is KeyDownEvent &&
                    event.logicalKey == LogicalKeyboardKey.enter &&
                    HardwareKeyboard.instance.isControlPressed) {
                  if (_inputController.text.trim().isNotEmpty && !_sending) {
                    _sendMessage();
                  }
                  return KeyEventResult.handled; //吞掉按键，避免插入换行
                }
                return KeyEventResult.ignored;
              },
              child: TextField(
                controller: _inputController,
                enabled: !_sending, //模拟回复期间暂锁
                minLines: 1,
                maxLines: 6, //多行输入，超过 6 行内部滚动
                keyboardType: TextInputType.multiline,
                decoration: InputDecoration(
                  hintText: _isDesktop
                      ? '输入消息…（Ctrl+Enter 发送，Enter 换行）'
                      : '输入消息…',
                  hintStyle: const TextStyle(fontSize: 13),
                  border: InputBorder.none,
                  isDense: true,
                ),
                style: const TextStyle(fontSize: 15),
              ),
            ),
          ),
          const SizedBox(width: 8),
          //监听输入内容变化，实时启停发送按钮（微信式圆形绿底纸飞机）
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _inputController,
            builder: (context, value, _) {
              final canSend = value.text.trim().isNotEmpty && !_sending;
              return IconButton(
                onPressed: canSend ? _sendMessage : null,
                icon: Icon(
                  Icons.send_rounded,
                  size: 20,
                  color: canSend ? Colors.white : const Color(0xFFFFFFFF),
                ),
                style: IconButton.styleFrom(
                  backgroundColor: canSend
                      ? const Color(0xFF07C160)
                      : const Color(0xFFD8D8D8),
                  minimumSize: const Size(40, 40),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
