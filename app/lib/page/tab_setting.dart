import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, rootBundle;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:three_tutor/page/usage_page.dart';
import 'package:three_tutor/service/key_cipher.dart';
import 'package:three_tutor/service/llm_client.dart';
import 'package:three_tutor/service/storage.dart';
import 'package:three_tutor/service/three_tutor_service.dart';
import 'package:three_tutor/theme/app_colors.dart';
import 'package:three_tutor/theme/app_theme.dart';

//设置页：API 配置
class TabSetting extends StatefulWidget {
  const TabSetting({super.key});

  @override
  State<TabSetting> createState() => _TabSettingState();
}

class _TabSettingState extends State<TabSetting> {
  Map<String, dynamic> _config = {}; //CONFIG.json 内容
  bool _loading = true;
  String _version = ''; //应用版本（运行时读 pubspec，与 release tag 校验同源）
  final _llm = LlmClient(); //连通性检验用（无状态，直接调协议层 ping）

  @override
  void initState() {
    super.initState(); //先执行 Flutter 自身的初始化
    _load();
  }

  //读取配置并刷新
  Future<void> _load() async {
    final config = await StorageService().loadConfig();
    final info = await PackageInfo.fromPlatform(); //运行时版本号（pubspec version）
    if (!mounted) return; //await 等待期间页面可能已被销毁，先确认还活着再刷新
    setState(() {
      //加载期间用户可能已切过主题（_setThemeMode 已写盘并更新内存）：
      //磁盘读回的结果若缺 themeMode，保留内存值，避免覆盖丢失
      if (config['themeMode'] == null && _config['themeMode'] != null) {
        config['themeMode'] = _config['themeMode'];
      }
      //思考档位同理：加载期间可能已切过，磁盘缺字段时保留内存值
      if (config['teachingThinkingEffort'] == null) {
        config['teachingThinkingEffort'] =
            ThreeTutorService.teachingThinkingEffort;
      }
      if (config['textThinkingEffort'] == null) {
        config['textThinkingEffort'] = ThreeTutorService.textThinkingEffort;
      }
      _config = config;
      _version = 'v${info.version}';
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
        //API 配置唯一入口 = 下方摘要卡（未配置时显示引导文案，同样可点进配置）
        actions: [
          //外观切换：明亮 / 深色 / 自动（跟随系统），选择即生效并落盘 CONFIG.json
          PopupMenuButton<ThemeMode>(
            icon: Icon(switch (themeModeNotifier.value) {
              ThemeMode.light => Icons.light_mode_outlined,
              ThemeMode.dark => Icons.dark_mode_outlined,
              ThemeMode.system => Icons.brightness_6_outlined,
            }),
            tooltip: '外观',
            onSelected: _setThemeMode,
            itemBuilder: (context) => [
              for (final m in ThemeMode.values)
                CheckedPopupMenuItem(
                  value: m,
                  checked: themeModeNotifier.value == m,
                  child: Text(_themeModeLabel(m)),
                ),
            ],
          ),
          //思考强度：教学组（上课/问答/问候，可翻教材）与日常组（群聊/闲聊/
          //更新/提炼）两段独立档位，选择即生效并落盘 CONFIG.json；
          //教学组开思考会存档并回传思考链（DeepSeek 硬约束），默认保持关闭
          PopupMenuButton<(String, String)>(
            icon: const Icon(Icons.psychology_outlined),
            tooltip: '思考强度',
            onSelected: _setThinkingEffort,
            itemBuilder: (context) => [
              const PopupMenuItem(
                enabled: false,
                child: Text('教学 / 问答（可翻教材）', style: TextStyle(fontSize: 12)),
              ),
              for (final e in _efforts)
                CheckedPopupMenuItem(
                  value: ('teaching', e),
                  checked: ThreeTutorService.teachingThinkingEffort == e,
                  child: Text(_effortLabel(e)),
                ),
              const PopupMenuItem(
                enabled: false,
                child: Text(
                  '群聊 / 闲聊 / 更新 / 提炼',
                  style: TextStyle(fontSize: 12),
                ),
              ),
              for (final e in _efforts)
                CheckedPopupMenuItem(
                  value: ('text', e),
                  checked: ThreeTutorService.textThinkingEffort == e,
                  child: Text(_effortLabel(e)),
                ),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                _buildApiSummary(), //当前 API 配置摘要（点击进入配置对话框）
                _buildUsageEntry(), //用量统计入口（往期课程 token 消耗）
                _buildTutorTemplateEntry(), //导师参考提示词（复制模板 → 应用外生成自定义导师组）
                _buildOutlinePromptEntry(), //大纲提示词（复制 → 应用外生成格式合规的教学大纲）
                const SizedBox(height: 32),
                Center(
                  //运行时读 pubspec version（package_info_plus），不再硬编码；
                  //与 release.yml 的 tag↔pubspec 校验同源，三处版本号单一来源
                  child: Text(
                    _version,
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.of(context).textTertiary,
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  //主题模式中文名（切换菜单展示）
  String _themeModeLabel(ThemeMode m) => switch (m) {
    ThemeMode.light => '明亮',
    ThemeMode.dark => '深色',
    ThemeMode.system => '自动（跟随系统）',
  };

  //思考档位：与请求参数 thinking/reasoning_effort 同值；仅三档（暂不支持 max）
  static const _efforts = ['disabled', 'low', 'high'];

  String _effortLabel(String e) => switch (e) {
    'disabled' => '无',
    'low' => '低',
    _ => '高',
  };

  //切换思考强度：内存静态值立即生效（下一次请求即用新档），再写入 CONFIG.json
  //（下次启动恢复）；先读磁盘最新配置再合并写入，同 _setThemeMode 的防覆盖逻辑
  Future<void> _setThinkingEffort((String, String) sel) async {
    final (group, effort) = sel;
    if (group == 'teaching') {
      if (ThreeTutorService.teachingThinkingEffort == effort) return;
      ThreeTutorService.teachingThinkingEffort = effort;
    } else {
      if (ThreeTutorService.textThinkingEffort == effort) return;
      ThreeTutorService.textThinkingEffort = effort;
    }
    final config = await StorageService().loadConfig();
    config['teachingThinkingEffort'] = ThreeTutorService.teachingThinkingEffort;
    config['textThinkingEffort'] = ThreeTutorService.textThinkingEffort;
    await StorageService().saveConfig(config);
    if (!mounted) return;
    setState(() => _config = config); //内存同步：后续 API 配置保存基于最新配置
  }

  //切换主题模式：全局通知重建 + 写入 CONFIG.json（下次启动恢复）
  //先读磁盘最新配置再合并写入：切换按钮在加载完成前即可点击，
  //直接改内存 _config 可能覆盖掉尚未加载的 profiles/active
  Future<void> _setThemeMode(ThemeMode mode) async {
    if (themeModeNotifier.value == mode) return;
    themeModeNotifier.value = mode;
    final config = await StorageService().loadConfig();
    config['themeMode'] = mode.name; //light / dark / system
    await StorageService().saveConfig(config);
    if (!mounted) return;
    setState(() => _config = config); //内存同步：后续 API 配置保存基于最新配置
  }

  //内置服务商表：DeepSeek 官方（接口+模型内置，实测可用组合，只填 Key）；OpenAI 兼容自填
  static const _providers = <String, (String, String, String)>{
    'deepseek': (
      'DeepSeek 官方',
      'https://api.deepseek.com',
      'deepseek-v4-flash',
    ),
    'openai': ('OpenAI 兼容', '', ''),
  };

  //配置档：id+名称+服务商+模型+Key 五件套（id 稳定标识，name 纯显示可随时改）。
  //读时解混淆 Key：内存态全明文，遮显/编辑/检验直接操作明文，落盘时才混淆
  List<Map<String, dynamic>> get _profiles {
    final list = [
      for (final p in (_config['profiles'] as List? ?? []))
        Map<String, dynamic>.from(p as Map),
    ];
    for (final p in list) {
      p['apiKey'] = deobfuscateKey(p['apiKey'] as String? ?? '');
    }
    return list;
  }

  //使用中配置档 id：直读 active 字段；null/悬空 = 未激活状态。
  //不回落首档——与 service._config() 保持同一语义（指针断了就是未配置），
  //避免摘要卡显示“在用某档”而聊天却报“API 未配置”的分叉
  String? get _activeId => _config['active'] as String?;

  //新配置档 id：毫秒时间戳 + 2 位随机后缀（本地唯一即可）
  String _newProfileId() =>
      '${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(90) + 10}';

  //当前 API 配置摘要卡：使用中档的 名称/模型/Key 遮显；点击进入配置对话框
  Widget _buildApiSummary() {
    if (_loading) return const SizedBox.shrink();
    final c = AppColors.of(context);
    final activeId = _activeId;
    final matched = _profiles.where((p) => p['id'] == activeId).toList();
    if (matched.isEmpty) {
      return Container(
        margin: const EdgeInsets.all(16),
        child: Material(
          color: c.surface,
          child: ListTile(
            leading: const Icon(Icons.vpn_key_outlined),
            title: const Text('API 未配置'),
            subtitle: const Text('点击设置服务商、模型与 Key'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _showApiConfigDialog, //未配置时同样可点进配置对话框
          ),
        ),
      );
    }
    final p = matched.first;
    return Container(
      margin: const EdgeInsets.all(16),
      child: Material(
        color: c.surface, //背景由 Material 承担，ListTile 水波纹可见（避免 ColoredBox 遮盖断言）
        child: ListTile(
          leading: const Icon(Icons.vpn_key_outlined),
          title: Text(p['name'] as String),
          subtitle: Text(
            '${p['model']} · ${_maskKey(p['apiKey'] as String? ?? '')}',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: _showApiConfigDialog,
        ),
      ),
    );
  }

  //用量统计入口卡：往期课程 token 消耗（输入/输出/缓存命中），点击进入统计页；
  //margin 顶部为 0——紧贴上方摘要卡，两卡视觉上成一组
  Widget _buildUsageEntry() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Material(
        color: AppColors.of(context).surface, //同上：水波纹可见
        child: ListTile(
          leading: const Icon(Icons.insights_outlined),
          title: const Text('用量统计'),
          subtitle: const Text('往期课程的 token 消耗与缓存命中'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const UsagePage()),
          ),
        ),
      ),
    );
  }

  //导师参考提示词入口卡：复制模板文本，在应用外用任意 AI 生成自定义导师组
  Widget _buildTutorTemplateEntry() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Material(
        color: AppColors.of(context).surface, //同上：水波纹可见
        child: ListTile(
          leading: const Icon(Icons.school_outlined),
          title: const Text('导师参考提示词'),
          subtitle: const Text('复制模板，应用外生成自定义导师组'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _showPromptDialog(
            '导师参考提示词',
            'assets/prompts/tutor_template.md',
          ),
        ),
      ),
    );
  }

  //大纲提示词入口卡：大纲即进度文件（doc/00），格式不合规则导入被拒——
  //用提示词在外部 AI 中生成，比手写更不容易出格式偏差
  Widget _buildOutlinePromptEntry() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Material(
        color: AppColors.of(context).surface,
        child: ListTile(
          leading: const Icon(Icons.checklist_outlined),
          title: const Text('大纲提示词'),
          subtitle: const Text('复制后应用外生成教学大纲'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _showPromptDialog(
            '大纲生成提示词',
            'assets/prompts/outline_gen.md',
          ),
        ),
      ),
    );
  }

  //提示词对话框：展示 assets/prompts 下的文本（可选可复制），一键复制全文
  //导师模板与大纲提示词共用（同一交互，只换标题与资产）
  Future<void> _showPromptDialog(String title, String asset) async {
    String text;
    try {
      text = await rootBundle.loadString(asset);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('提示词加载失败：$e'),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              text,
              style: const TextStyle(fontSize: 13, height: 1.5),
            ),
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('已复制'),
                  duration: Duration(seconds: 1),
                ),
              );
            },
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('复制全文'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  //API 配置对话框：配置档列表（服务商+模型+Key 三者配套，不可拆分管理）。
  //点击档即选用；添加/编辑走表单子对话框；检验连通性针对选中档。
  //所有改动在对话框内存态，点「保存」一次性落盘 CONFIG.json（取消即丢弃）。
  Future<void> _showApiConfigDialog() async {
    var profiles = _profiles;
    var active = _activeId; //null = 未选中任何档（空状态）
    var testing = false; //连通性检验进行中
    bool? testOk; //检验结果（null=未检验）
    String? testMsg; //检验结果描述

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('API 配置'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                //配置档列表：点击选用；尾随编辑/删除（删选中档则回落首档）
                for (final p in profiles)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      active == p['id']
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      size: 20,
                      color: AppColors.of(context).accent,
                    ),
                    title: Text(p['name'] as String? ?? '配置'),
                    subtitle: Text(
                      '${_providers[p['provider'] as String? ?? 'openai']?.$1 ?? 'OpenAI 兼容'}'
                      ' · ${p['model']} · ${_maskKey(p['apiKey'] as String? ?? '')}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    //切换 = 直接改 active；点已选中档保持不变
                    onTap: () =>
                        setDialogState(() => active = p['id'] as String),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.edit_outlined, size: 20),
                          tooltip: '编辑',
                          onPressed: () async {
                            final edited = await _profileFormDialog(
                              existing: p,
                              takenNames: [
                                for (final q in profiles)
                                  if (q['name'] != p['name'])
                                    q['name'] as String,
                              ],
                            );
                            if (edited == null) return;
                            setDialogState(() {
                              profiles = <Map<String, dynamic>>[
                                for (final q in profiles)
                                  q['id'] == p['id'] ? edited : q,
                              ];
                              //id 稳定：改名不再牵动 active
                            });
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline, size: 20),
                          tooltip: '删除',
                          //二次确认：误删配置档 = 连带丢失 Key，且 Key 无法找回
                          onPressed: () async {
                            final confirmed = await _confirmDeleteProfile(
                              p['name'] as String? ?? '',
                            );
                            if (confirmed != true) return; //取消即不动
                            setDialogState(() {
                              profiles = <Map<String, dynamic>>[
                                ...profiles.where((q) => q['id'] != p['id']),
                              ];
                              if (active == p['id']) {
                                active = profiles.isEmpty
                                    ? null
                                    : profiles.first['id'] as String;
                              }
                            });
                          },
                        ),
                      ],
                    ),
                  ),
                if (profiles.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      '尚未保存配置，点击「添加配置」',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.of(context).textSecondary,
                      ),
                    ),
                  ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () async {
                      final added = await _profileFormDialog(
                        takenNames: [
                          for (final q in profiles) q['name'] as String,
                        ],
                      );
                      if (added == null) return;
                      setDialogState(() {
                        profiles = <Map<String, dynamic>>[...profiles, added];
                        active = added['id'] as String; //新档即选中：检验/保存直接生效
                      });
                    },
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('添加配置'),
                  ),
                ),
                //连通性检验结果行（对话框内展示，SnackBar 会被对话框遮住）
                if (testMsg != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      testMsg!,
                      style: TextStyle(
                        fontSize: 12,
                        color: (testOk ?? false)
                            ? AppColors.of(context).accent
                            : AppColors.of(context).danger,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            //检验连通性：用对话框当前态（不落盘）发最小请求，结果行内展示
            TextButton(
              onPressed: testing
                  ? null
                  : () async {
                      //检验选中档（新填/编辑的档先确定回列表再选中它测）
                      final sel = active == null
                          ? <Map<String, dynamic>>[]
                          : profiles.where((p) => p['id'] == active).toList();
                      if (sel.isEmpty) {
                        setDialogState(() {
                          testing = false;
                          testOk = false;
                          testMsg = '请先添加并选中一个配置';
                        });
                        return;
                      }
                      final p = sel.first;
                      final cfg = LlmConfig(
                        apiUrl: p['apiUrl'] as String? ?? '',
                        apiKey: p['apiKey'] as String? ?? '',
                        model: p['model'] as String? ?? '',
                      );
                      setDialogState(() {
                        testing = true;
                        testMsg = null;
                      });
                      final (ok, msg) = await _llm.ping(cfg);
                      if (!context.mounted) return; //用户在检验期间关了对话框
                      setDialogState(() {
                        testing = false;
                        testOk = ok;
                        testMsg = msg;
                      });
                    },
              child: Text(testing ? '检验中…' : '检验连通性'),
            ),
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
    if (saved != true || !mounted) return; //用户取消，全部改动丢弃

    //落盘：顶层仅 active（激活档 id，null = 无激活配置），不再冗余镜像选中档三字段；
    //Key 混淆后写入（防公共目录下明文扫描）；空 profiles 也允许保存 = 无 API 配置状态；
    //保留其它顶层字段（themeMode 等外观配置，不能随 API 保存丢失）
    final next = {
      ..._config,
      'profiles': [
        for (final q in profiles)
          {...q, 'apiKey': obfuscateKey(q['apiKey'] as String? ?? '')},
      ],
      'active': active,
    };
    setState(() => _config = next);
    await StorageService().saveConfig(next);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(profiles.isEmpty ? '已保存（当前无 API 配置）' : 'API 配置已保存'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  //删除配置档二次确认：对话框内完成（主对话框之上叠一层），确认才执行内存删除
  //（保存才落盘，取消两层都无损）；提示选中的档被删后回落首档
  Future<bool?> _confirmDeleteProfile(String name) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除配置档'),
        content: Text('确定删除「$name」吗？\n其包含的 API Key 将一并移除，且无法找回。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.of(context).dangerSolid, //红色警示：不可逆操作
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  //配置档表单（添加/编辑共用）：名称+服务商+模型+(Base URL)+Key 三件套配套；
  //DeepSeek 接口内置、模型预填可改；OpenAI 兼容自填。确定返回档 Map，取消返回 null。
  //takenNames：已有档名（防重名，编辑时传排除自身的名单）；表单内可即时检验当前填写。
  Future<Map<String, String>?> _profileFormDialog({
    Map<String, dynamic>? existing, //null=添加
    List<String> takenNames = const [],
  }) async {
    var provider = existing?['provider'] as String? ?? 'deepseek';
    final nameC = TextEditingController(
      text:
          existing?['name'] as String? ??
          (provider == 'deepseek'
              ? _providers['deepseek']!.$1
              : _providers['openai']!.$1),
    );
    final baseUrlC = TextEditingController(
      text: existing?['apiUrl'] as String? ?? '',
    );
    //模型预填：编辑沿用档内值；添加时 DeepSeek 用内置默认、兼容留空
    final modelC = TextEditingController(
      text:
          existing?['model'] as String? ??
          (provider == 'deepseek' ? _providers['deepseek']!.$3 : ''),
    );
    final keyC = TextEditingController(
      text: existing?['apiKey'] as String? ?? '',
    );
    var testing = false;
    bool? testOk;
    String? testMsg;

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(existing == null ? '添加配置' : '编辑配置'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameC,
                  autofocus: existing == null,
                  decoration: const InputDecoration(labelText: '配置名称'),
                ),
                DropdownButtonFormField<String>(
                  initialValue: provider, //下拉内部态驱动显示，外部变量同步给 if 分支
                  decoration: const InputDecoration(labelText: '服务商'),
                  items: [
                    for (final e in _providers.entries)
                      DropdownMenuItem(value: e.key, child: Text(e.value.$1)),
                  ],
                  onChanged: (v) => setDialogState(() => provider = v!),
                ),
                //DeepSeek：接口内置；OpenAI 兼容：自填 Base URL
                if (provider == 'deepseek')
                  Padding(
                    padding: const EdgeInsets.only(top: 4, bottom: 4),
                    child: Text(
                      '接口 ${_providers['deepseek']!.$2}（内置）',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.of(context).textSecondary,
                      ),
                    ),
                  )
                else
                  TextField(
                    controller: baseUrlC,
                    onChanged: (v) =>
                        _onBaseUrlChanged(baseUrlC), //实时裁剪 v1 后的多余路径
                    decoration: const InputDecoration(
                      labelText: 'Base URL',
                      hintText: 'https://api.example.com/v1',
                    ),
                  ),
                TextField(
                  controller: modelC,
                  decoration: InputDecoration(
                    labelText: provider == 'deepseek'
                        ? 'Model（DeepSeek）'
                        : 'Model',
                    hintText: provider == 'deepseek'
                        ? _providers['deepseek']!.$3
                        : 'gpt-4o-mini',
                  ),
                ),
                TextField(
                  controller: keyC,
                  obscureText: true, //Key 遮显
                  decoration: const InputDecoration(labelText: 'API Key'),
                ),
                const SizedBox(height: 4),
                //表单内检验：当前填写即测，不必先保存
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: testing
                        ? null
                        : () async {
                            final cfg = LlmConfig(
                              apiUrl: provider == 'deepseek'
                                  ? _providers['deepseek']!.$2
                                  : baseUrlC.text.trim(),
                              apiKey: keyC.text.trim(),
                              model: modelC.text.trim(),
                            );
                            setDialogState(() {
                              testing = true;
                              testMsg = null;
                            });
                            final (ok2, msg) = await _llm.ping(cfg);
                            if (!context.mounted) return;
                            setDialogState(() {
                              testing = false;
                              testOk = ok2;
                              testMsg = msg;
                            });
                          },
                    child: Text(testing ? '检验中…' : '检验连通性'),
                  ),
                ),
                if (testMsg != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      testMsg!,
                      style: TextStyle(
                        fontSize: 12,
                        color: (testOk ?? false)
                            ? AppColors.of(context).accent
                            : AppColors.of(context).danger,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return null;
    //校验：名称/接口/模型/Key 均非空；名称不与已有档重复
    final name = nameC.text.trim();
    final apiUrl = provider == 'deepseek'
        ? _providers['deepseek']!.$2
        : _trimBaseUrlValue(baseUrlC.text.trim()); //确定时再裁一次（防检验/粘贴边缘态）
    final model = modelC.text.trim();
    final key = keyC.text.trim();
    if (name.isEmpty || apiUrl.isEmpty || model.isEmpty || key.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('名称、接口、模型与 Key 均不能为空'),
          duration: Duration(seconds: 2),
        ),
      );
      return null;
    }
    if (takenNames.contains(name)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('配置名称「$name」已存在'),
          duration: const Duration(seconds: 2),
        ),
      );
      return null;
    }
    return {
      'id': existing?['id'] as String? ?? _newProfileId(), //编辑沿用原 id
      'name': name,
      'provider': provider,
      'apiUrl': apiUrl,
      'model': model,
      'apiKey': key,
    };
  }

  //Base URL 裁剪：OpenAI 兼协议的 baseUrl 惯例以 /v1 结尾（后面由协议层拼 /chat/completions），
  //用户常把完整端点粘进来（…/v1/chat/completions）——输入时实时裁掉 v1 之后的部分。
  //仅当 /v1 是独立路径段（后跟 /）才认定，避免误伤 …/v1abc 或不含 v1 的网关路径（如 …/zen/go）。
  void _onBaseUrlChanged(TextEditingController c) {
    final trimmed = _trimBaseUrlValue(c.text);
    if (trimmed != c.text) {
      c.value = TextEditingValue(
        text: trimmed,
        selection: TextSelection.collapsed(offset: trimmed.length), //光标随裁剪归尾
      );
    }
  }

  //裁剪 /v1 之后的路径（保留到 v1 结束）；无 /v1 段则原样返回
  String _trimBaseUrlValue(String url) {
    final m = RegExp(r'^(.*?/v1)(/.*)$').firstMatch(url);
    return m == null ? url : m.group(1)!;
  }

  //Key 遮显：保留前 6 后 4，中间打点（sk-8a8…H9x 式）
  String _maskKey(String key) {
    if (key.length <= 12) return '•' * key.length;
    return '${key.substring(0, 6)}••••••${key.substring(key.length - 4)}';
  }
}
