import 'dart:convert';
import 'dart:io';
import 'dart:ui' show ImageByteFormat;

import 'package:flutter/cupertino.dart' show CupertinoPageRoute;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, LogicalKeyboardKey;
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:three_tutor/main.dart';
import 'package:three_tutor/page/chat/course_detail_page.dart';
import 'package:three_tutor/service/llm_client.dart' show LlmException;
import 'package:three_tutor/service/storage.dart';
import 'package:three_tutor/service/three_tutor_service.dart';
import 'package:three_tutor/theme/app_colors.dart';
import 'package:three_tutor/widget/chat_card.dart'
    show ChatCardView, normalizeItalic;
import 'package:three_tutor/widget/tutor_avatar.dart';

//群聊页：课程对话与课后闲聊同一消息流
//按需加载：优先渲染最近课次，上滑到顶加载更早课次（主流 IM 行为）
//收发接线：judgeFlow 判定三态 → 对应服务方法；生成期间输入框 hint 显示忙碌文案并锁定输入框，
//会话列表预览同步显示（busy 静态表，见 ThreeTutorService）
class GroupChatPage extends StatefulWidget {
  const GroupChatPage({super.key, required this.courseName});

  final String courseName; //群名 = 课程名

  @override
  State<GroupChatPage> createState() => _GroupChatPageState();
}

//消息流渲染单元：系统分隔行或消息行
class _ChatItem {
  const _ChatItem.divider(this.text, {this.linkText, this.linkPath})
    : message = null;
  const _ChatItem.message(this.message)
    : text = null,
      linkText = null,
      linkPath = null;

  final String? text; //分隔行文本
  final Map<String, dynamic>? message; //消息行数据
  final String? linkText; //分隔行中可点部分的文本（翻书行链接，其余部分灰色）
  final String? linkPath; //链接目标：材料文件绝对路径（外部应用打开）
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
  String get _busyLabel => ThreeTutorService.busyLabelOf(widget.courseName);
  String _latestStatus = ''; //最新课次 meta.status（toggle 显示判定；''=无课次）
  int _lessons = 0; //累计课时（toggle 显示判定：idle 且 ≥1）
  bool _socialMode = false; //课后交流切换：false=问答（默认）/ true=群聊讨论；仅会话内存不落盘
  bool _editing = false; //修改模式：输入框内容将替换当前流最后一条用户消息并重生成回复
  String _editFlow = ''; //修改定流（点「修改」时判定的 flow，提交沿用防中途切 toggle 漂移）
  Map<String, dynamic>? _selectCopyTarget; //部分复制模式：正在选择文本的消息（null=普通模式）
  bool _loading = true;
  final _scrollController = ScrollController();
  final _inputController = TextEditingController(); //输入框
  final _service = ThreeTutorService(); //编排层：三态判定 + 各场景收发与上下课
  final _cardKey = GlobalKey(); //离屏聊天卡片截图锚点
  Widget? _shareCard; //待截图的卡片（非空时挂屏外渲染，截完即卸）
  bool _sharing = false; //导出进行中（按钮转圈防重复点击）

  //群聊逐条上屏队列：onMessage 只入队，消费循环按固定间隔逐条显示（模拟真实聊天节奏）。
  //落档仍由 service 实时完成——队列仅控制 UI 呈现；退出重进走 _reload 全量显示（历史消息本就一次呈现）
  final List<Map<String, dynamic>> _socialQueue = [];
  bool _flushingQueue = false; //消费循环进行中（防重入 + busy 变更时 reload 避让判断）
  static const _socialGap = Duration(seconds: 3); //逐条显示间隔

  bool get _busy => _busyLabel.isNotEmpty; //LLM 生成进行中（Banner 提示 + 输入框暂锁）

  @override
  void initState() {
    super.initState(); //先执行 Flutter 自身的初始化
    _scrollController.addListener(_onScroll); //滑到顶部附近时加载更早课次
    ThreeTutorService.busyVersion.addListener(_onBusyChanged); //跨页面生成中状态同步
    _load();
  }

  @override
  void dispose() {
    ThreeTutorService.busyVersion.removeListener(_onBusyChanged); //移除生成中状态监听
    _scrollController.dispose(); //页面销毁时释放滚动控制器
    _inputController.dispose(); //释放输入控制器，避免内存泄漏
    super.dispose();
  }

  //跨页面生成中状态同步：busy 变更即重绘（含退出重进后的恢复）。
  //busy → 空闲时从文件重载：生成可能发生在本页面之外（如后台群聊），落档内容需拉回屏上。
  //本页群聊队列消费中则跳过：未显示消息正逐条上屏，reload 会把它们一次性提前揭示。
  void _onBusyChanged() {
    if (!mounted) return;
    final wasBusy = _busy;
    setState(() {}); //文案经 getter 即时读静态表
    if (wasBusy && !_busy && !_flushingQueue) _reload();
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
      _validateSelectCopy(); //消息全清，部分复制目标必失效
      return;
    }

    //从最新课次往前加载，直到凑够约一屏消息或加载完全部课次
    var entries = <Map<String, dynamic>>[];
    var loaded = 0;
    while (loaded < files.length) {
      final path = files[files.length - 1 - loaded];
      final chunk = await StorageService().loadChatFile(path);
      //标记来源文件（「修改」判定用：定位当前流目标文件的最后一条用户行）
      entries = [
        for (final e in chunk) {...e, '_file': path},
        ...entries,
      ];
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
    _validateSelectCopy(); //_entries 全量重建，部分复制目标可能失效
  }

  //上滑到顶：加载更早的课次（每次 1 个）
  //reverse 列表中更早内容在远端，插入后当前视口天然不动，无需手动锚定
  Future<void> _loadEarlier() async {
    if (!_hasMore || _loadingMore || _loading) return;
    _loadingMore = true;

    final index = _files.length - _loadedCount - 1; //下一个要加载的更早课次
    final path = _files[index];
    final earlier = await StorageService().loadChatFile(path);

    if (!mounted) return;
    setState(() {
      //更早条目插入头部（保持旧→新顺序），同样带来源文件标记
      _entries = [
        for (final e in earlier) {...e, '_file': path},
        ..._entries,
      ];
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
    if (_editing) {
      await _submitEdit(); //修改模式：发送即提交修改
      return;
    }
    final text = _inputController.text.trim();
    if (text.isEmpty || _busy) return;
    _inputController.clear();
    _flushSocialQueueNow(); //插话前把队列剩余群聊一次性上屏：聊天记录需完整呈现

    ThreeTutorService.setBusyForCourse(widget.courseName, '正在输入中…');
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
      ThreeTutorService.setBusyForCourse(widget.courseName, '');
    }
  }

  //提交修改（修改模式下点发送）：乐观更新（气泡立即改内容、旧回复链从屏上消失）
  //→ service 改写落档并按原流重生成回复（flow 在点「修改」时已定死）→ reload 兑底校正。
  //失败：toast 后内容放回输入框保持修改模式可重试（改写已发生时重试幂等）
  Future<void> _submitEdit() async {
    final text = _inputController.text.trim();
    if (text.isEmpty || _busy) return;
    _inputController.clear();
    final flow = _editFlow;
    final social = flow == 'social';

    ThreeTutorService.setBusyForCourse(widget.courseName, '正在输入中…');
    try {
      //乐观更新：目标流文件最后一条 user 行改内容，其后同文件条目（本轮回复链）从屏上移除
      final files = await StorageService().listChatFiles(widget.courseName);
      final targetPath = social
          ? files[files.length - 2] //修改入口已保证 ≥2 文件
          : files.last;
      final idx = _lastUserIndexOf(targetPath);
      if (idx < 0) {
        _toast('未找到可修改的消息');
        return;
      }
      if (!mounted) return;
      setState(() {
        _entries = [
          ..._entries.sublist(0, idx),
          {..._entries[idx], 'content': text, 'time': _now()},
          //其后同文件条目删除；跨文件条目（如最新文件的 qa 段）保留不受影响
          ..._entries.sublist(idx + 1).where((e) => e['_file'] != targetPath),
        ];
        _items = _buildItems(_entries, hasMore: _hasMore).reversed.toList();
        _editing = false;
        _editFlow = '';
      });
      _scrollToBottom();

      try {
        await (flow == 'teaching'
            ? _service.sendLessonMessage(
                courseName: widget.courseName,
                content: text,
                edit: true,
              )
            : _service.sendUserMessage(
                courseName: widget.courseName,
                content: text,
                social: social,
                edit: true,
              ));
      } on LlmException catch (e) {
        if (!mounted) return;
        _toast('重新生成失败：$e\n内容已放回输入框，可重试');
        setState(() {
          _editing = true;
          _editFlow = flow;
          _inputController.text = text;
          _inputController.selection = TextSelection.collapsed(
            offset: _inputController.text.length,
          );
        });
      }
      //成功与否都从文件重载：成功同步新回复；失败校正屏显为文件实际内容
      if (!mounted) return;
      await _reload();
      _scrollToBottom();
    } finally {
      //正常路径由 service 端 finally 清；此处兜底异常（_setBusy 幂等，重清无害）
      ThreeTutorService.setBusyForCourse(widget.courseName, '');
    }
  }

  //重新生成群聊（调试入口，默认注释）：用途与恢复方法见 doc/05-调试.md
  /*
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
    ThreeTutorService.setBusyForCourse(widget.courseName, '群里正在聊天…');
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
      ThreeTutorService.setBusyForCourse(widget.courseName, '');
    }
  }
  */

  //课程详情页按钮 pop 意图处理：start=开始上课（问候）/ end=今天就到这里（课后更新+群聊）
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
      ThreeTutorService.setBusyForCourse(
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
      //action == 'end'：课后更新 → 群聊生成（两段请求，全程锁定输入框）
      //占 busy：更新请求发出前输入框已锁（service.endLesson 内部维持同文案）
      ThreeTutorService.setBusyForCourse(widget.courseName, '整理课程进度中…');
      try {
        await _service.endLesson(
          courseName: widget.courseName,
          //群聊消息逐条落档即回调：入队逐条弹出（当前不再有 teaching 回调，分支留作防御）
          onMessage: (message) {
            if (!mounted) return;
            if (message['phase'] != 'social') {
              setState(() {
                _entries = [..._entries, message];
                _items = _buildItems(
                  _entries,
                  hasMore: _hasMore,
                ).reversed.toList();
              });
              _scrollToBottom();
              return;
            }
            _enqueueSocial(message);
          },
        );
        //成功：下一课文件已建（含群聊消息），lessons ≥ 1，toggle 开始显示
        if (!mounted) return;
        _toast('今天到这里，好好休息～');
      } on LlmException catch (e) {
        //更新失败：meta 保持 ongoing，按钮仍为「今天就到这里」，重新点击即重跑
        if (!mounted) return;
        _toast('课后更新失败：$e\n可重新点击「今天就到这里」重试');
      } catch (e) {
        //兜底：非 LlmException 的异常同样要可见，且继续走 reload（此前会静默：无 toast/
        //无重载/按钮不变——2026-09-08 遗传学「更新请求静默失败」即此路径）
        if (!mounted) return;
        _toast('下课处理异常：$e\n可重新点击「今天就到这里」重试');
      }
    }
    if (!mounted) return;
    //busy 清除由 service 端 finally 统一负责，busyVersion 监听器触发重绘；
    //群聊队列消费完再重载：避免 reload 把尚未显示的消息一次性提前揭示
    await _waitSocialFlushed();
    await _reload();
    _scrollToBottom();
  }

  //群聊消息入队并确保消费循环在跑（循环进行中则由其顺带消费，防重入）
  void _enqueueSocial(Map<String, dynamic> message) {
    _socialQueue.add(message);
    if (_flushingQueue) return;
    _flushingQueue = true;
    _flushSocialLoop();
  }

  //消费循环：每 _socialGap 显示一条，队列清空即退出；期间新入队消息由循环顺带消费
  Future<void> _flushSocialLoop() async {
    try {
      while (_socialQueue.isNotEmpty) {
        await Future<void>.delayed(_socialGap);
        if (!mounted) return;
        if (_socialQueue.isEmpty) continue; //等待期间被 _flushSocialQueueNow 清空
        setState(() {
          _entries = [..._entries, _socialQueue.removeAt(0)];
          _items = _buildItems(_entries, hasMore: _hasMore).reversed.toList();
        });
        _scrollToBottom();
      }
    } finally {
      _flushingQueue = false;
    }
  }

  //把队列剩余群聊一次性全部上屏（发消息前调用：插话时聊天记录需完整呈现）
  void _flushSocialQueueNow() {
    if (_socialQueue.isEmpty) return;
    final rest = List<Map<String, dynamic>>.of(_socialQueue);
    _socialQueue.clear();
    setState(() {
      _entries = [..._entries, ...rest];
      _items = _buildItems(_entries, hasMore: _hasMore).reversed.toList();
    });
    _scrollToBottom();
  }

  //等待群聊队列消费完成（轮询：收尾 reload 前调用，避免提前揭示未显示消息）
  Future<void> _waitSocialFlushed() async {
    while (_socialQueue.isNotEmpty || _flushingQueue) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  //轻提示（SnackBar，不阻断操作）；duration 可定制（如复制提示用短时长）
  void _toast(String message, {Duration? duration}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: duration ?? const Duration(seconds: 4),
      ),
    );
  }

  //导出聊天卡片：定位最新已完成课次 → 离屏渲染长图 → 截图 → 系统分享（推广入口）
  Future<void> _exportLessonCard() async {
    if (_sharing) return;
    setState(() => _sharing = true);
    try {
      //最新 ended 课次：从最新文件往前找首个 meta.status=ended（最新 idle 文件是
      //新开课区间的 qa 交流段，不算一节课）；上课中按钮隐藏，此处在 idle 时进入
      final files = await StorageService().listChatFiles(widget.courseName);
      String? target;
      Map<String, dynamic> meta = {};
      for (var i = files.length - 1; i >= 0; i--) {
        final first = File(files[i]).readAsLinesSync().first;
        final m = jsonDecode(first) as Map<String, dynamic>;
        if (m['status'] == 'ended') {
          target = files[i];
          meta = m;
          break;
        }
      }
      if (target == null) {
        _toast('没有已完成的课次可分享');
        return;
      }
      //卡片只渲染消息与翻书提示行（meta / tool_call 中间轮不渲染）
      final entries = (await StorageService().loadChatFile(
        target,
      )).where((e) => e['type'] == 'message' || e['type'] == 'tool').toList();
      if (entries.isEmpty) {
        _toast('本课没有可分享的消息');
        return;
      }
      final date = meta['date'] as String? ?? '';
      //挂载离屏卡片（屏外 OverflowBox：高度不设限，长图按内容完整布局）
      //→ 等渲染与头像图解码 → 截图
      setState(() {
        _shareCard = ChatCardView(
          courseName: widget.courseName,
          lesson: meta['lesson'] as int? ?? 0,
          tutor: meta['tutor'] as String? ?? '',
          date: date.length >= 10 ? date.substring(5) : date,
          entries: entries,
          courseDirPath: _courseDirPath,
          tutorFiles: _tutorFiles,
          learnerName: _learnerName,
        );
      });
      await Future<void>.delayed(const Duration(milliseconds: 350));
      if (!mounted) return;
      final boundary =
          _cardKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null || !boundary.hasSize || boundary.size.isEmpty) {
        _toast('卡片渲染失败，请重试');
        return;
      }
      final image = await boundary.toImage(pixelRatio: 3);
      final byteData = await image.toByteData(format: ImageByteFormat.png);
      image.dispose();
      if (byteData == null) {
        _toast('截图失败，请重试');
        return;
      }
      final dir = await getTemporaryDirectory();
      final lesson = meta['lesson'] as int? ?? 0;
      final tmpFile = File('${dir.path}/chat_card_$lesson.png');
      final bytes = byteData.buffer.asUint8List();
      await tmpFile.writeAsBytes(bytes);
      if (!mounted) return;
      //保存：仅桌面端弹保存对话框选位置（file_selector 的 getSaveLocation 在
      //Android/iOS 未实现，抛 UnimplementedError）；移动端直接用临时目录文件，
      //用系统查看器打开预览——转发/发送交给系统应用，
      //（share_plus 在 Windows 端 MissingPluginException，弃用；仅生成图片更简单可靠）
      var savedPath = tmpFile.path;
      if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
        try {
          final location = await getSaveLocation(
            suggestedName: '第$lesson课_${widget.courseName}_聊天卡片.png',
            acceptedTypeGroups: const [
              XTypeGroup(label: 'PNG 图片', extensions: <String>['png']),
            ],
          );
          if (location != null) {
            savedPath = location.path;
            await File(savedPath).writeAsBytes(bytes);
          }
        } catch (_) {
          //保存对话框异常：沿用临时目录方案
        }
      }
      if (!mounted) return;
      final result = await OpenFilex.open(savedPath);
      if (!mounted) return;
      if (savedPath != tmpFile.path) {
        _toast('已保存：$savedPath');
      } else if (result.type == ResultType.done) {
        _toast('卡片已生成，转发请用系统查看器的分享/保存功能');
      } else {
        _toast('卡片已生成：$savedPath');
      }
    } catch (e) {
      if (!mounted) return;
      _toast('分享失败：$e');
    } finally {
      if (mounted) {
        setState(() {
          _shareCard = null;
          _sharing = false;
        });
      }
    }
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
    var last = ''; //向前最近 user 的 time（tutor/辅助行继承源）
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      if (e['type'] == 'meta') continue; //meta 第二遍处理
      if (e['type'] == 'message' && e['role'] == 'user') {
        last = e['time'] as String? ?? last;
      }
      keys[i] = last; //tutor 与 tool_call/tool 辅助行继承最近 user 锚点（保持物理行序）
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
      items.add(const _ChatItem.divider('你加入了群聊，右上角切换上课/下课状态'));
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
      } else if (entry['type'] == 'tool_call') {
        //agent 翻书中间轮：不渲染（可见提示由随后的 tool 行承载）
      } else if (entry['type'] == 'tool') {
        //翻书记录：轻量系统提示（成功指针行与失败快照行都渲染；兼容旧 file/section 行）
        //成功行整段可点 → 调系统「打开方式」用外部应用打开材料文件（本应用不预览）
        final name = entry['name'] as String? ?? '';
        final path = entry['path'] as String?;
        final offset = entry['offset'] as int?;
        final file = entry['file'] as String?;
        final section = entry['section'] as String?;
        if (path != null) {
          final label = '查阅材料：$path${offset != null ? ' 第$offset行起' : ''}';
          items.add(
            _ChatItem.divider(
              '📖 $name $label',
              linkText: label,
              linkPath: '$_courseDirPath/$path', //新格式 path 为课程目录下相对路径
            ),
          );
        } else if (file != null && section != null) {
          final label = '翻阅教材：$file > $section';
          items.add(
            _ChatItem.divider(
              '📖 $name $label',
              linkText: label,
              linkPath:
                  '$_courseDirPath/TEXTBOOK/$file', //旧格式 file 为 TEXTBOOK/ 下文件名
            ),
          );
        } else {
          items.add(_ChatItem.divider('📖 $name 查阅材料（内容暂不可用）'));
        }
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
            //分享本课聊天卡片：完成一节课后显示（idle + lessons ≥ 1），上课中/从未上课隐藏；
            //位于课后交流切换按钮左侧（导出图片 → 系统分享，推广入口）
            if (_latestStatus == 'idle' && _lessons >= 1)
              _sharing
                  ? const Padding(
                      padding: EdgeInsets.fromLTRB(14, 12, 14, 12),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : IconButton(
                      icon: const Icon(Icons.share, size: 22),
                      tooltip: '分享本课聊天卡片',
                      onPressed: _exportLessonCard,
                    ),
            //课后交流切换：仅 idle 且上过课（lessons ≥ 1）显示；默认问答，激活为群聊讨论
            if (_latestStatus == 'idle' && _lessons >= 1)
              IconButton(
                icon: const Icon(Icons.groups, size: 24),
                tooltip: _socialMode
                    ? '课后交流：群聊讨论（点此切回问答）'
                    : '课后交流：问答（点此切为群聊讨论）',
                color: _socialMode
                    ? AppColors.of(context).accent
                    : AppColors.of(context).textSecondary,
                onPressed: () => setState(() => _socialMode = !_socialMode),
              ),
            //重新生成群聊按钮已注释（调试入口，见 doc/05-调试.md）
            // IconButton(
            //   icon: const Icon(Icons.refresh),
            //   tooltip: '重新生成群聊（临时测试）',
            //   onPressed: _lessons >= 1 ? _regenerateGroupChat : null,
            // ),
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
        body: Stack(
          clipBehavior: Clip.none,
          children: [
            _loading
                ? const Center(child: CircularProgressIndicator())
                : SafeArea(
                    child: Column(
                      children: [
                        Expanded(child: _buildMessageList()),
                        //部分复制模式：输入条换提示条（复制所选 / 退出）
                        if (_selectCopyTarget != null)
                          _buildSelectCopyBar()
                        else
                          _buildInputBar(), //只读阶段的完整形态预览：禁用
                      ],
                    ),
                  ),
            //离屏聊天卡片：屏外布局（OverflowBox 高度不设限，长图按内容完整渲染不被
            //视口裁剪），仅导出时挂载，截图完成即卸载（Clip.none 保险：不裁溢出部分）
            if (_shareCard != null)
              Positioned(
                left: -10000,
                top: 0,
                child: SizedBox(
                  width: ChatCardView.width,
                  height: 0,
                  child: OverflowBox(
                    maxWidth: ChatCardView.width,
                    maxHeight: double.infinity,
                    alignment: Alignment.topLeft,
                    child: RepaintBoundary(key: _cardKey, child: _shareCard),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageList() {
    //长按/右键消息弹出操作菜单（部分复制/全部复制/修改，见 _showMessageMenu）；
    //部分复制模式下目标消息临时改由 SelectionArea 接管，拖选后复制渲染文本
    return ListView.builder(
      controller: _scrollController,
      reverse: true, //从底部（最新消息）开始渲染：进入无跳屏，上滑加载天然锚定
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _items.length,
      itemBuilder: (context, index) {
        final item = _items[index];
        return item.text != null
            ? _buildDivider(item)
            : _buildMessage(item.message!);
      },
    );
  }

  //系统分隔行：两侧细线 + 居中小字（课次分隔 / 下课后 / 加入群聊 / 没有更多了）
  //带 linkPath 的行（翻书行）：linkText 部分染链接蓝可点，点击用外部应用打开材料文件
  Widget _buildDivider(_ChatItem item) {
    final c = AppColors.of(context);
    final grey = TextStyle(fontSize: 12, color: c.textTertiary);
    final link = item.linkPath;
    final Widget center;
    if (link != null && item.linkText != null) {
      final head = item.text!.substring(
        0,
        item.text!.length - item.linkText!.length,
      );
      center = GestureDetector(
        onTap: () => _openMaterial(link),
        child: Text.rich(
          TextSpan(
            style: grey,
            children: [
              TextSpan(text: head),
              TextSpan(
                text: item.linkText!,
                style: TextStyle(color: c.link), //链接蓝
              ),
            ],
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis, //长路径不撑破行
        ),
      );
    } else {
      center = Text(
        item.text!,
        style: grey,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 24),
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          children: [
            Expanded(child: Divider(color: c.divider)),
            //中间按内容宽（短文本时两侧平分 → 居中）；长文本限宽截断不撑破
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.6),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: center,
              ),
            ),
            Expanded(child: Divider(color: c.divider)),
          ],
        ),
      ),
    );
  }

  //翻书行点击：把材料文件交给系统「打开方式」（外部应用打开，本应用不预览）
  Future<void> _openMaterial(String path) async {
    if (!File(path).existsSync()) {
      _toast('文件已移除');
      return;
    }
    try {
      final result = await OpenFilex.open(path);
      if (!mounted) return;
      if (result.type != ResultType.done) {
        _toast(
          result.type == ResultType.noAppToOpen
              ? '未找到可打开该文件的应用'
              : '打开失败，请检查该文件类型的默认应用',
        );
      }
    } catch (e) {
      if (!mounted) return;
      _toast('打开失败：$e');
    }
  }

  // —— 消息长按/右键菜单（复制 / 修改）——

  //长按或右键消息：底部弹出操作菜单（深色半透明）。
  //部分复制：全部消息可用（进入选择模式，拖选后复制渲染文本）；
  //全部复制：全部消息可用（复制 content 源文本）；修改：当前流最后一条用户消息额外可用
  Future<void> _showMessageMenu(Map<String, dynamic> message) async {
    final editFlow = await _editableFlowOf(message);
    if (!mounted) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xE6484848), //深灰半透明（长按菜单风格）
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 18),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _menuItem(
                Icons.copy_rounded,
                '部分复制',
                () => Navigator.pop(context, 'select'),
              ),
              const SizedBox(width: 36),
              _menuItem(
                Icons.copy_all_rounded,
                '全部复制',
                () => Navigator.pop(context, 'copy'),
              ),
              if (editFlow != null) ...[
                const SizedBox(width: 36),
                _menuItem(
                  Icons.edit_rounded,
                  '修改',
                  () => Navigator.pop(context, 'edit'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'copy') {
      await Clipboard.setData(
        ClipboardData(text: message['content'] as String? ?? ''),
      );
      if (mounted) _toast('已全部复制', duration: const Duration(seconds: 1));
    } else if (action == 'select') {
      //进入部分复制模式：目标消息换 SelectionArea，输入条换提示条
      setState(() => _selectCopyTarget = message);
    } else if (action == 'edit' && editFlow != null) {
      _startEdit(message, editFlow);
    }
  }

  // —— 部分复制（选择模式）——

  //退出部分复制模式：清目标，恢复输入条与长按菜单
  void _exitSelectCopy() {
    setState(() => _selectCopyTarget = null);
  }

  //消息重载后验证部分复制目标：_entries 全量重建（identical 失效）即自动退出，
  //避免提示条残留、选择挂在已重建的消息上
  void _validateSelectCopy() {
    if (_selectCopyTarget == null) return;
    final alive = _entries.any((e) => identical(e, _selectCopyTarget));
    if (alive) return;
    _selectCopyTarget = null;
    if (mounted) setState(() {}); //提示条 → 输入条，目标消息行恢复长按菜单
  }

  //部分复制提示条：替换输入条。复制本身走 SelectionArea 内置的系统能力
  //（移动端选中后弹系统工具条点「复制」，桌面端右键菜单或 Ctrl+C），
  //这里只负责引导与退出
  Widget _buildSelectCopyBar() {
    final c = AppColors.of(context);
    return Container(
      color: c.surface,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '拖选要复制的文本，选中后用弹出菜单复制',
              style: TextStyle(fontSize: 13, color: c.textSecondary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: _exitSelectCopy,
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 36),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              textStyle: const TextStyle(fontSize: 13),
            ),
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }

  //菜单项：图标 + 文字（白色，深色菜单样式）
  Widget _menuItem(IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 26, color: Colors.white),
            const SizedBox(height: 6),
            Text(
              label,
              style: const TextStyle(fontSize: 12, color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }

  //「修改」可用性：返回当前流（teaching/qa/social，与发送同源 judgeFlow），不可用返回 null。
  //条件：非 busy、非修改模式中、非部分复制模式中（选择期间输入条被提示条占据）、
  //长按消息 = 当前流目标文件的物理最后一条用户行。
  //目标流文件：teaching/qa → 最新课次文件；social → 倒数第二文件尾。
  //该行之后只可能是本轮回复链（tool_call/tool/tutor），改写截断不波及 auto 群聊行
  //（见 service._rewriteLastUser）
  Future<String?> _editableFlowOf(Map<String, dynamic> message) async {
    if (_busy || _editing || _selectCopyTarget != null) return null;
    final flow = await _service.judgeFlow(
      widget.courseName,
      toggleActive: _socialMode,
    );
    final files = await StorageService().listChatFiles(widget.courseName);
    final String targetPath;
    if (flow == 'social') {
      if (files.length < 2) return null; //不足两课时无 social 目标文件
      targetPath = files[files.length - 2];
    } else {
      targetPath = files.last;
    }
    final idx = _lastUserIndexOf(targetPath);
    return (idx >= 0 && identical(_entries[idx], message)) ? flow : null;
  }

  //_entries（物理序）中目标文件的最后一条 user 行下标；-1 = 未找到
  int _lastUserIndexOf(String filePath) {
    var idx = -1;
    for (var i = 0; i < _entries.length; i++) {
      final e = _entries[i];
      if (e['_file'] != filePath) continue;
      if (e['type'] == 'message' && e['role'] == 'user') idx = i;
    }
    return idx;
  }

  //进入修改模式：输入框继承原文（全选便于直接覆盖），flow 定死提交时沿用
  void _startEdit(Map<String, dynamic> message, String flow) {
    setState(() {
      _editing = true;
      _editFlow = flow;
      _inputController.text = message['content'] as String? ?? '';
      _inputController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _inputController.text.length,
      );
    });
  }

  //退出修改模式：清空输入框恢复普通发送
  void _cancelEdit() {
    setState(() {
      _editing = false;
      _editFlow = '';
      _inputController.clear();
    });
  }

  //消息行：导师消息左对齐（头像+名字+白气泡），用户消息右对齐（绿气泡+头像）；
  //长按/右键弹操作菜单（复制，末条用户消息另有修改）
  Widget _buildMessage(Map<String, dynamic> message) {
    final role = message['role'] as String? ?? 'tutor';
    final name = message['name'] as String? ?? '';
    final content = message['content'] as String? ?? '';
    final bubble = role == 'user'
        ? _buildUserMessage(name, content)
        : _buildTutorMessage(name, content);

    //部分复制模式：目标消息改由 SelectionArea 接管——长按从选择开始（不再弹菜单），
    //复制走其内置系统菜单/快捷键（复制的是渲染后文本，所见即所得）；
    //其余消息照常长按/右键弹菜单
    if (identical(message, _selectCopyTarget)) {
      return SelectionArea(child: bubble);
    }

    return GestureDetector(
      onLongPress: () => _showMessageMenu(message),
      onSecondaryTapUp: (_) => _showMessageMenu(message), //桌面端右键同菜单
      child: bubble,
    );
  }

  //消息正文用 GptMarkdown 渲染：支持斜体旁白（*...* 与 _..._，后者渲染前规范化为前者）、标题、列表与 LaTeX 公式（$...$ 行内、$$...$$ 独立行）

  //导师消息：头像 + 名字 + 白色气泡，左对齐；气泡最大宽度约屏宽 72%
  Widget _buildTutorMessage(String name, String content) {
    final c = AppColors.of(context);
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
                style: TextStyle(fontSize: 12, color: c.textSecondary),
              ),
              const SizedBox(height: 2),
              Container(
                constraints: BoxConstraints(maxWidth: maxWidth),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(12),
                    topRight: Radius.circular(12),
                    bottomLeft: Radius.circular(4), //靠头像侧小圆角（气泡细节）
                    bottomRight: Radius.circular(12),
                  ),
                ),
                child: GptMarkdown(
                  normalizeItalic(content),
                  style: const TextStyle(fontSize: 15, height: 1.4),
                  useDollarSignsForLatex:
                      true, //$...$ 与 $$...$$ 定界的 LaTeX 需显式开启（默认只认 \(...\)/\[...\]）
                  //行内公式与正文同字号；块公式超宽时横向滚动，避免溢出气泡
                  styleSheet: GptMarkdownStyleSheet(
                    latex: const LatexStyle(
                      textStyle: TextStyle(fontSize: 15),
                      scrollBlockHorizontally: true,
                    ),
                    link: LinkStyle(color: c.link), //链接色随主题（深浅两套）
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  //用户消息：绿色气泡（绿 #95EC69）+ 头像，右对齐；群聊里自己消息不显示名字
  Widget _buildUserMessage(String name, String content) {
    final c = AppColors.of(context);
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
              decoration: BoxDecoration(
                color: c.userBubble,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(12),
                  topRight: Radius.circular(12),
                  bottomLeft: Radius.circular(12),
                  bottomRight: Radius.circular(4), //靠头像侧小圆角（气泡细节）
                ),
              ),
              child: GptMarkdown(
                normalizeItalic(content),
                style: TextStyle(
                  fontSize: 15,
                  height: 1.4,
                  color: c.userBubbleText,
                ),
                useDollarSignsForLatex: true,
                styleSheet: GptMarkdownStyleSheet(
                  latex: const LatexStyle(
                    textStyle: TextStyle(fontSize: 15),
                    scrollBlockHorizontally: true,
                  ),
                  link: LinkStyle(color: c.link), //链接色随主题（深浅两套）
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

  //输入条：输入可用（发送按钮随内容与发送状态启停）；
  //修改模式时顶部显示提示条（发送即替换原消息，× 退出修改模式）
  Widget _buildInputBar() {
    final c = AppColors.of(context);
    return Container(
      color: c.surface,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        children: [
          if (_editing)
            Container(
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.fromLTRB(10, 4, 6, 4),
              decoration: BoxDecoration(
                color: c.editBarBg,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '正在修改，发送后替换原消息并重新生成回复',
                      style: TextStyle(fontSize: 12, color: c.textSecondary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  GestureDetector(
                    onTap: _cancelEdit,
                    child: Icon(Icons.cancel, size: 16, color: c.textSecondary),
                  ),
                ],
              ),
            ),
          Row(
            children: [
              Expanded(
                //桌面端快捷发送：Ctrl+Enter（mac 桌面端 ⌘+Enter）；
                //TextField 自身不消费这两个组合键，事件冒泡到这里触发发送；
                //不带修饰键的 Enter 仍走 TextField 默认行为——插入换行
                child: CallbackShortcuts(
                  bindings: {
                    const SingleActivator(
                      LogicalKeyboardKey.enter,
                      control: true,
                    ): _sendMessage,
                    const SingleActivator(
                      LogicalKeyboardKey.numpadEnter,
                      control: true,
                    ): _sendMessage,
                    const SingleActivator(LogicalKeyboardKey.enter, meta: true):
                        _sendMessage,
                    const SingleActivator(
                      LogicalKeyboardKey.numpadEnter,
                      meta: true,
                    ): _sendMessage,
                  },
                  child: TextField(
                    controller: _inputController,
                    enabled: !_busy, //LLM 生成期间暂锁，回复落档后解锁
                    minLines: 1,
                    maxLines: 6, //多行输入，超过 6 行内部滚动
                    keyboardType: TextInputType.multiline,
                    decoration: InputDecoration(
                      //生成期间输入框即状态位：文案显示 + 禁用（替代顶部 Banner）
                      hintText: _busy ? _busyLabel : '输入消息…',
                      hintStyle: const TextStyle(fontSize: 13),
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    style: const TextStyle(fontSize: 15),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              //监听输入内容变化，实时启停发送按钮（圆形绿底纸飞机）
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
                          ? c.accentSolid
                          : c.disabledSurface,
                      minimumSize: const Size(40, 40),
                    ),
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}
