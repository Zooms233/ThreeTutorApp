import 'package:flutter/cupertino.dart' show CupertinoPageRoute;

import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:tutor_chat/main.dart';
import 'package:tutor_chat/page/chat/course_detail_page.dart';
import 'package:tutor_chat/service/llm_client.dart' show LlmException;
import 'package:tutor_chat/service/storage.dart';
import 'package:tutor_chat/service/tutorchat_service.dart';
import 'package:tutor_chat/widget/tutor_avatar.dart';

//群聊页：课程对话与课后闲聊同一消息流
//按需加载：优先渲染最近课次，上滑到顶加载更早课次（微信行为）
//收发接线：judgeFlow 判定三态 → 对应服务方法；生成期间 Banner 替换为「正在输入中」并锁定输入框
class GroupChatPage extends StatefulWidget {
  const GroupChatPage({super.key, required this.courseName});

  final String courseName; //群名 = 课程名

  @override
  State<GroupChatPage> createState() => _GroupChatPageState();
}

//下划线斜体规范化：_文字_ → *文字*（gpt_markdown 的 ItalicMd 只认星号斜体，不认下划线）
//开/闭下划线不贴 ASCII 字母数字（保护 file_name 类英文词内下划线与数字下标），内容首尾非空白
final RegExp _underscoreItalic = RegExp(
  r'(?<![A-Za-z0-9])_(?!_)([^_\s](?:[^_\n]*[^_\s])?)_(?![A-Za-z0-9_])',
);

//渲染前调用：把非 LaTeX 区间的 _文字_ 转为 *文字*；公式段原样保留（_ 是 LaTeX 下标语法）
String _normalizeItalic(String text) {
  return text.splitMapJoin(
    RegExp(r'\$\$?[^$]*\$\$?'),
    onMatch: (m) => m.group(0)!,
    onNonMatch: (t) =>
        t.replaceAllMapped(_underscoreItalic, (m) => '*${m[1]}*'),
  );
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

  List<String> _files = []; //全部课次文件路径（旧 → 新，只查名单不读内容）
  List<Map<String, dynamic>> _entries = []; //已加载的消息条目（从最新往前）
  List<_ChatItem> _items = []; //渲染单元（分隔行 + 消息）
  int _loadedCount = 0; //已从最新往回加载的课次数
  bool _hasMore = false; //是否还有更早的课次未加载
  bool _loadingMore = false; //上滑加载中（防重复触发）
  Map<String, String> _tutorFiles = {}; //导师名 → 档案文件名（头像图片查找用）
  String _courseDirPath = ''; //课程目录路径（头像图片查找用）
  String _learnerName = ''; //用户称呼（用户消息显示与写档用）
  //生成中文案改由 service 静态 busy 表持有（跨实例共享，退出重进不丢）；
  //页面只读（getter），不再维护本地副本——避免双轨不同步
  String get _busyLabel => TutorChatService.busyLabelOf(widget.courseName);
  String _latestStatus = ''; //最新课次 meta.status（toggle 显示判定；''=无课次）
  int _lessons = 0; //累计课时（toggle 显示判定：idle 且 ≥1）
  bool _socialMode = false; //课后交流切换：false=问答（默认）/ true=群聊讨论；仅会话内存不落盘
  bool _loading = true;
  final _scrollController = ScrollController();
  final _inputController = TextEditingController(); //输入框
  final _service = TutorChatService(); //编排层：三态判定 + 各场景收发与上下课

  bool get _busy => _busyLabel.isNotEmpty; //LLM 生成进行中（Banner 提示 + 输入框暂锁）

  @override
  void initState() {
    super.initState(); //先执行 Flutter 自身的初始化
    _scrollController.addListener(_onScroll); //滑到顶部附近时加载更早课次
    TutorChatService.busyVersion.addListener(_onBusyChanged); //跨页面生成中状态同步
    _load();
  }

  @override
  void dispose() {
    TutorChatService.busyVersion.removeListener(_onBusyChanged); //移除生成中状态监听
    _scrollController.dispose(); //页面销毁时释放滚动控制器
    _inputController.dispose(); //释放输入控制器，避免内存泄漏
    super.dispose();
  }

  //跨页面生成中状态同步：busy 变更即重绘（含退出重进后的恢复）。
  //busy → 空闲时从文件重载：生成可能发生在本页面之外（如后台群聊），落档内容需拉回屏上。
  void _onBusyChanged() {
    if (!mounted) return;
    final wasBusy = _busy;
    setState(() {}); //文案经 getter 即时读静态表
    if (wasBusy && !_busy) _reload();
  }

  //初始加载：转圈后走同一套加载逻辑
  Future<void> _load() async {
    setState(() => _loading = true);
    await _reload();
    if (!mounted) return;
    setState(() => _loading = false);
  }

  //从文件重建消息流（不清空页面、不转圈）：生成完成后同步落档结果
  //同时刷新 toggle 显示所需的 meta.status 与 STATE.lessons
  Future<void> _reload() async {
    final files = await StorageService().listChatFiles(widget.courseName);
    final tutorFiles = await StorageService().loadCourseTutorFiles(
      widget.courseName,
    );
    final courseDir = await StorageService().getCourseDir(widget.courseName);
    final learner = await StorageService().loadCourseLearner(widget.courseName);
    final meta = await StorageService().loadLatestChatMeta(widget.courseName);
    final state = await StorageService().loadCourseState(widget.courseName);

    if (!mounted) return; //await 等待期间页面可能已被销毁，先确认还活着再刷新

    //恢复跨页面生成中状态：文案 getter 即时读静态表，无需手动恢复；本 setState 由 _reload 统一触发

    //从未上课：只显示加入群聊的系统行（此后不存在空白消息页，_buildItems 空条目即此行）
    if (files.isEmpty) {
      setState(() {
        _files = files;
        _tutorFiles = tutorFiles;
        _courseDirPath = courseDir.path;
        _learnerName = learner['name'] as String? ?? '我';
        _latestStatus = '';
        _lessons = state['lessons'] as int? ?? 0;
        _items = [const _ChatItem.divider('你加入了群聊，现在可以开始聊天了')];
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
      final messageCount = entries.where((e) => e['type'] == 'message').length;
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
      _latestStatus = meta?['status'] as String? ?? '';
      _lessons = state['lessons'] as int? ?? 0;
      _items = _buildItems(entries, hasMore: _hasMore).reversed.toList();
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

  //发送消息：judgeFlow 判定三态 → 走对应服务方法（先写后说由服务层完成）
  //入口即占 busy（通用文案，service 端拿到导师名后细化）：关闭判定期间连发两条、
  //并发写同一文件的竞态窗口；判定本身抛异常也由 finally 释放
  //失败时用户消息已留档（悬空），输入框解锁，重发时连续合并消化
  Future<void> _sendMessage() async {
    final text = _inputController.text.trim();
    if (text.isEmpty || _busy) return;
    _inputController.clear();

    TutorChatService.setBusyForCourse(widget.courseName, '正在输入中…');
    try {
      //三态判定：idle+未上过课 → 问答；idle+toggle 激活 → 群聊讨论；ongoing → 上课对话
      final flow = await _service.judgeFlow(
        widget.courseName,
        toggleActive: _socialMode,
      );
      //lesson/tutorName 不再在此使用：忙碌文案由 service 端各场景方法内部设置
      final social = flow == 'social';
      final phase = social
          ? 'social'
          : (flow == 'teaching' ? 'teaching' : 'qa');

      //乐观更新（optimistic update）：不等生成结果，先假定发送成功让消息立即上屏
      //（服务层此刻正把它写入文件，界面不重复落档）；若生成失败，
      //末尾 _reload 从文件重载校正，toast 提示重发
      final userMessage = {
        'type': 'message',
        'phase': phase,
        'role': 'user',
        'name': _learnerName,
        'time': _now(),
        'content': text,
      };
      if (!mounted) return;
      setState(() {
        _entries = [..._entries, userMessage];
        _items = _buildItems(_entries, hasMore: _hasMore).reversed.toList();
        //忙碌文案由 service._setBusy 统一设置，busyVersion 监听器触发重绘
      });
      _scrollToBottom();

      try {
        await (flow == 'teaching'
            ? _service.sendLessonMessage(
                courseName: widget.courseName,
                content: text,
              )
            : _service.sendUserMessage(
                courseName: widget.courseName,
                content: text,
                social: social,
              ));
      } on LlmException catch (e) {
        if (!mounted) return;
        _toast('发送失败：$e\n消息已保留，重新发送即可');
      }
      //无论成败都从文件重载：成功同步回复；失败同步悬空消息（含课次分隔行）；再解锁输入框
      //（busy 清除由 service 端 finally 统一负责，busyVersion 监听器触发重绘）
      if (!mounted) return;
      await _reload();
      _scrollToBottom();
    } finally {
      //正常路径由 service 端 finally 清；此处兜底判定阶段异常（_setBusy 幂等，重清无害）
      TutorChatService.setBusyForCourse(widget.courseName, '');
    }
  }

  //重新生成群聊（临时测试入口）：确认 → 清旧 auto 行并刷新 → busy → 逐条弹出新生成；
  //结束后 busy 清除由 finally 负责（busyVersion 触发重绘 + 全量重载，无需手动）
  Future<void> _regenerateGroupChat() async {
    if (_busy) {
      _toast('上一条生成还未完成，请稍候');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重新生成群聊'),
        content: const Text('将删除现有群聊并重新生成（覆盖式，不影响教学对话与进度）。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('重新生成'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    TutorChatService.setBusyForCourse(widget.courseName, '群里正在聊天…');
    try {
      final cleared = await _service.clearGroupChat(
        courseName: widget.courseName,
      );
      if (!cleared || !mounted) {
        _toast('没有已结束的课次');
        return;
      }
      await _reload(); //旧群聊从屏幕消失
      await _service.regenerateGroupChat(
        courseName: widget.courseName,
        onMessage: (m) {
          if (!mounted) return;
          setState(() {
            _entries = [..._entries, m];
            _items = _buildItems(_entries, hasMore: _hasMore).reversed.toList();
          });
          _scrollToBottom();
        },
      );
      _toast('群聊已重新生成');
    } on LlmException catch (e) {
      if (!mounted) return;
      _toast('群聊生成失败：$e');
    } finally {
      TutorChatService.setBusyForCourse(widget.courseName, '');
    }
  }

  //课程详情页按钮 pop 意图处理：start=开始上课（问候）/ end=今天就到这里（总结+课后更新）
  Future<void> _handleLessonAction(String action) async {
    if (_busy) {
      _toast('上一条生成还未完成，请稍候');
      return;
    }

    if (action == 'start') {
      //开启新课次建档（幂等，文件已存在则返回既有），随后生成课前问候
      final lesson = await StorageService().startNewLesson(widget.courseName);
      if (!mounted) return;
      //建档即占 busy：问候请求发出前输入框已锁（service.startLesson 内部再次设置同文案）
      TutorChatService.setBusyForCourse(
        widget.courseName,
        '${lesson['tutor']} 正在输入中…',
      );
      try {
        await _service.startLesson(courseName: widget.courseName);
      } on LlmException catch (e) {
        //问候失败：meta 保持 ongoing，用户直接发消息即走上课对话自然恢复
        if (!mounted) return;
        _toast('问候生成失败：$e\n可直接发消息继续上课');
      } catch (e) {
        //兜底：非 LlmException 的异常同样要可见（否则会静默失败：无 toast/无重载）
        if (!mounted) return;
        _toast('问候处理异常：$e\n可直接发消息继续上课');
      }
    } else {
      //action == 'end'：下课总结 → 课后更新 → 群聊生成（三段请求，全程锁定输入框）
      final lesson = await StorageService().getCurrentLesson(widget.courseName);
      if (!mounted) return;
      //建档即占 busy：总结请求发出前输入框已锁（service.endLesson 内部再次设置同文案）
      TutorChatService.setBusyForCourse(
        widget.courseName,
        '${lesson['tutor']} 正在输入中…',
      );
      try {
        await _service.endLesson(
          courseName: widget.courseName,
          //逐条落档即回调：总结先上屏（teaching），群聊消息逐条弹出（social）
          onMessage: (message) {
            if (!mounted) return;
            setState(() {
              _entries = [..._entries, message];
              _items = _buildItems(
                _entries,
                hasMore: _hasMore,
              ).reversed.toList();
              //群聊阶段文案由 service._setBusy 统一切换，busyVersion 监听器触发重绘
            });
            _scrollToBottom();
          },
        );
        //成功：下一课文件已建（含群聊消息），lessons ≥ 1，toggle 开始显示
        if (!mounted) return;
        _toast('今天到这里，好好休息～');
      } on LlmException catch (e) {
        //总结或更新失败：meta 保持 ongoing，按钮仍为「今天就到这里」，重新点击即重跑
        if (!mounted) return;
        _toast('下课总结失败：$e\n可重新点击「今天就到这里」重试');
      } catch (e) {
        //兜底：非 LlmException 的异常同样要可见，且继续走 reload（此前会静默：无 toast/
        //无重载/按钮不变——2026-09-08 遗传学「更新请求静默失败」即此路径）
        if (!mounted) return;
        _toast('下课处理异常：$e\n可重新点击「今天就到这里」重试');
      }
    }
    if (!mounted) return;
    //busy 清除由 service 端 finally 统一负责，busyVersion 监听器触发重绘
    await _reload();
    _scrollToBottom();
  }

  //轻提示（SnackBar，不阻断操作）
  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 4)),
    );
  }

  //当前时刻（用户消息 time 字段，乐观上屏用；落档以服务层写入为准）
  String _now() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${n.year}-${two(n.month)}-${two(n.day)} ${two(n.hour)}:${two(n.minute)}';
  }

  //按用户消息时间戳做块级稳定排序（渲染序）。
  //键 = user 自身 time；tutor 继承其前最近 user（回复随后渲染）；meta 锚定其文件内首条 user（分隔行贴住本课内容）。
  //同键保持原序（稳定）：文件内行序本就是时间序，排序只在跨文件交界处（qa 在下一课文件头、
  //讨论在上一课文件尾交错）生效，不影响正常顺序。
  List<Map<String, dynamic>> _sortByTimestamp(
    List<Map<String, dynamic>> entries,
  ) {
    final keys = List<String>.filled(entries.length, '');
    var last = ''; //向前最近 user 的 time（tutor 继承源）
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      if (e['type'] != 'message') continue; //meta 第二遍处理
      if (e['role'] == 'user') last = e['time'] as String? ?? last;
      keys[i] = last;
    }
    for (var i = 0; i < entries.length; i++) {
      if (entries[i]['type'] == 'meta') {
        //meta 锚定其文件内首条 user time；整文件无 user（纯教学文件）时继承上一文件尾的键
        var k = '';
        for (
          var j = i + 1;
          j < entries.length && entries[j]['type'] != 'meta';
          j++
        ) {
          final e = entries[j];
          if (e['type'] == 'message' && e['role'] == 'user') {
            k = e['time'] as String? ?? '';
            break;
          }
        }
        keys[i] = k.isNotEmpty ? k : (i > 0 ? keys[i - 1] : '');
      }
    }
    final order = [for (var i = 0; i < entries.length; i++) i]
      ..sort((a, b) {
        final ka = keys[a], kb = keys[b];
        if (ka == kb) return a.compareTo(b); //同键稳定：保持物理行序
        if (ka.isEmpty) return -1; //无锚点（极边界）排最前
        if (kb.isEmpty) return 1;
        return ka.compareTo(kb); //time 字典序即时间序（YYYY-MM-DD HH:mm）
      });
    return [for (final i in order) entries[i]];
  }

  //滚动到最底部（最新消息；reverse 列表的 offset 0 即底部）
  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
  }

  //把消息流条目转成渲染单元（插入课次分隔行与「下课后」分隔行）
  List<_ChatItem> _buildItems(
    List<Map<String, dynamic>> rawEntries, {
    required bool hasMore,
  }) {
    //先按时间戳归序：qa 写下一课文件头、讨论写上一课文件尾交错使用时，修正渲染时序
    final entries = _sortByTimestamp(rawEntries);
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
    //返回统一切回聊天 tab：无论从聊天列表、导师资料页还是创建课程进入，
    //pop 后都落在聊天 tab（而非进入前的通讯录 tab）；PopScope 覆盖
    //返回按钮、侧滑手势、系统返回键全部路径
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) HomePage.pageIndex.value = 0;
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.courseName),
          actions: [
            //课后交流切换：仅 idle 且上过课（lessons ≥ 1）显示；默认问答，激活为群聊讨论
            if (_latestStatus == 'idle' && _lessons >= 1)
              IconButton(
                icon: const Icon(Icons.groups, size: 24),
                tooltip: _socialMode
                    ? '课后交流：群聊讨论（点此切回问答）'
                    : '课后交流：问答（点此切为群聊讨论）',
                color: _socialMode
                    ? const Color(0xFF07C160)
                    : const Color(0xFF999999),
                onPressed: () => setState(() => _socialMode = !_socialMode),
              ),
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: '重新生成群聊（临时测试）',
              //存在 ended 课次即可重生成（lessons≥1 ⇔ 有已结束课次；最新课次可能是 idle）
              onPressed: _lessons >= 1 ? _regenerateGroupChat : null,
            ),
            IconButton(
              icon: const Icon(Icons.query_stats),
              tooltip: '课程详情',
              onPressed: () async {
                //详情页上课控制按钮 pop 意图回传：start=开始上课 / end=今天就到这里 / null=普通返回
                final action = await Navigator.push<String>(
                  context,
                  CupertinoPageRoute(
                    builder: (context) =>
                        CourseDetailPage(courseName: widget.courseName),
                  ),
                );
                if (action == null || !mounted) return;
                await _handleLessonAction(action);
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
      ),
    );
  }

  Widget _buildMessageList() {
    //SelectionArea：消息可长按选择复制（LaTeX 等自绘部分不可选，正文可选）
    return SelectionArea(
      child: ListView.builder(
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
      ),
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
    final content = message['content'] as String? ?? '';

    return role == 'user'
        ? _buildUserMessage(name, content)
        : _buildTutorMessage(name, content);
  }

  //消息正文用 GptMarkdown 渲染：支持斜体旁白（*...* 与 _..._，后者渲染前规范化为前者）、标题、列表与 LaTeX 公式（$...$ 行内、$$...$$ 独立行）

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
                child: GptMarkdown(
                  _normalizeItalic(content),
                  style: const TextStyle(fontSize: 15, height: 1.4),
                  useDollarSignsForLatex:
                      true, //$...$ 与 $$...$$ 定界的 LaTeX 需显式开启（默认只认 \(...\)/\[...\]）
                  //行内公式与正文同字号；块公式超宽时横向滚动，避免溢出气泡
                  styleSheet: const GptMarkdownStyleSheet(
                    latex: LatexStyle(
                      textStyle: TextStyle(fontSize: 15),
                      scrollBlockHorizontally: true,
                    ),
                  ),
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
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: const BoxDecoration(
                color: Color(0xFF95EC69),
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(12),
                  topRight: Radius.circular(12),
                  bottomLeft: Radius.circular(12),
                  bottomRight: Radius.circular(4), //靠头像侧小圆角（微信细节）
                ),
              ),
              child: GptMarkdown(
                _normalizeItalic(content),
                style: const TextStyle(fontSize: 15, height: 1.4),
                useDollarSignsForLatex: true,
                styleSheet: const GptMarkdownStyleSheet(
                  latex: LatexStyle(
                    textStyle: TextStyle(fontSize: 15),
                    scrollBlockHorizontally: true,
                  ),
                ),
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
            child: TextField(
              controller: _inputController,
              enabled: !_busy, //LLM 生成期间暂锁，回复落档后解锁
              minLines: 1,
              maxLines: 6, //多行输入，超过 6 行内部滚动
              keyboardType: TextInputType.multiline,
              decoration: InputDecoration(
                //生成期间输入框即状态位：文案显示 + 禁用（微信同款，替代顶部 Banner）
                hintText: _busy ? _busyLabel : '输入消息…',
                hintStyle: const TextStyle(fontSize: 13),
                border: InputBorder.none,
                isDense: true,
              ),
              style: const TextStyle(fontSize: 15),
            ),
          ),
          const SizedBox(width: 8),
          //监听输入内容变化，实时启停发送按钮（微信式圆形绿底纸飞机）
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _inputController,
            builder: (context, value, _) {
              final canSend = value.text.trim().isNotEmpty && !_busy;
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
