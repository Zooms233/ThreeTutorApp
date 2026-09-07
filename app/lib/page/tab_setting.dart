import 'package:flutter/material.dart';
import 'package:tutor_chat/service/llm_client.dart';
import 'package:tutor_chat/service/storage.dart';

//设置页：API 配置（上课动态热力图暂缓，原因见类内注释块）
class TabSetting extends StatefulWidget {
  const TabSetting({super.key});

  @override
  State<TabSetting> createState() => _TabSettingState();
}

class _TabSettingState extends State<TabSetting> {
  //热力图暂缓：文件模型改为「第N课.jsonl」后，meta.date 语义弱化、用户消息自带
  //时间戳，按日聚合的数据源需要重新设计；恢复时取消本类与 storage 内注释块
  // static const _cellSize = 12.0; //热力图格子边长
  // static const _cellGap = 3.0; //格子间距
  // static const _weekCount = 26; //展示的周数上限（半年，窄屏按宽度自适应减少）

  // Map<String, int> _lessonDates = {}; //日期 → 课次数
  Map<String, dynamic> _config = {}; //CONFIG.json 内容
  bool _loading = true;
  final _llm = LlmClient(); //连通性检验用（无状态，直接调协议层 ping）

  @override
  void initState() {
    super.initState(); //先执行 Flutter 自身的初始化
    _load();
  }

  @override
  void dispose() {
    super.dispose();
  }

  //读取配置并刷新（热力图数据 listLessonDates 暂缓，见类顶注释）
  Future<void> _load() async {
    final config = await StorageService().loadConfig();
    if (!mounted) return; //await 等待期间页面可能已被销毁，先确认还活着再刷新
    setState(() {
      _config = config;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
        //API 配置唯一入口 = 下方摘要卡（未配置时显示引导文案，同样可点进配置）
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                // _buildHeatmap(), //热力图暂缓
                _buildApiSummary(), //当前 API 配置摘要（点击进入配置对话框）
                const SizedBox(height: 32),
                const Center(
                  //与 pubspec version 同步（引入 package_info 前先硬编码）
                  child: Text(
                    'v1.0.0',
                    style: TextStyle(fontSize: 12, color: Color(0xFFB0B0B0)),
                  ),
                ),
              ],
            ),
    );
  }

  /* ── 上课动态热力图（暂缓）─────────────────────────────
     文件模型改为「第N课.jsonl」后，meta.date 语义弱化、用户消息自带
     时间戳，按日聚合的数据源需要重新设计；恢复时取消注释。
     ───────────────────────────────────────────────────*/
  /*
  //热力图：统计行 + 月份标注 + 26 周网格（列=周，行=周一至周日）
  //不滚动：列数按可用宽度自适应（最多 26 周，窄屏自动减少）
  Widget _buildHeatmap() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day); //归零到当天
    final thisMonday = today.subtract(Duration(days: today.weekday - 1));

    //统计行固定按半年（26 周）范围计数
    final halfYearMonday = thisMonday.subtract(const Duration(days: 25 * 7));
    final total = _lessonDates.entries.where((e) {
      final d = DateTime.tryParse(e.key);
      return d != null && !d.isBefore(halfYearMonday) && !d.isAfter(today);
    }).fold(0, (sum, e) => sum + e.value);

    return Container(
      color: Colors.white,
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '最近半年上课 $total 次',
            style: const TextStyle(fontSize: 14, color: Color(0xFF999999)),
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) {
              const labelWidth = 30.0; //左侧星期标注列宽
              final available = constraints.maxWidth - labelWidth;
              final weeks = ((available / (_cellSize + _cellGap)).floor())
                  .clamp(1, _weekCount);
              final startMonday = thisMonday.subtract(
                Duration(days: (weeks - 1) * 7),
              );

              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  //左侧：月份行占位 + 星期标注
                  SizedBox(
                    width: labelWidth,
                    child: Column(
                      children: [
                        const SizedBox(height: 16), //与月份标注行同高
                        _buildWeekdayLabels(),
                      ],
                    ),
                  ),
                  //右侧：月份标注 + 周列网格
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildMonthLabels(startMonday, weeks),
                      Row(
                        children: [
                          for (var week = 0; week < weeks; week++)
                            _buildWeekColumn(startMonday, week),
                        ],
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  //月份标注行：包含某月 1 日的列标注该月（GitHub 风格，文字可延伸到右侧空格）
  Widget _buildMonthLabels(DateTime startMonday, int weeks) {
    final labels = <Widget>[];
    for (var week = 0; week < weeks; week++) {
      final name = _monthLabelFor(startMonday, week);
      if (name.isEmpty) continue;
      labels.add(
        Positioned(
          left: week * (_cellSize + _cellGap),
          child: Text(
            name,
            style: const TextStyle(fontSize: 10, color: Color(0xFFB0B0B0)),
          ),
        ),
      );
    }
    return SizedBox(
      height: 16,
      width: weeks * (_cellSize + _cellGap),
      child: Stack(clipBehavior: Clip.none, children: labels),
    );
  }

  //该周若包含某月 1 日 → 返回该月英文名，否则空
  String _monthLabelFor(DateTime startMonday, int week) {
    const names = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    for (var day = 0; day < 7; day++) {
      final d = startMonday.add(Duration(days: week * 7 + day));
      if (d.day == 1) return names[d.month - 1];
    }
    return '';
  }

  //周列：7 个格子（周一 → 周日）
  Widget _buildWeekColumn(DateTime startMonday, int week) {
    return Padding(
      padding: const EdgeInsets.only(right: _cellGap),
      child: Column(
        children: [
          for (var day = 0; day < 7; day++)
            _buildCell(startMonday.add(Duration(days: week * 7 + day))),
        ],
      ),
    );
  }

  //格子：按当天课次数着色；点按显示当日课次；未来日期留空占位
  Widget _buildCell(DateTime date) {
    if (date.isAfter(DateTime.now())) {
      return SizedBox(width: _cellSize, height: _cellSize + _cellGap);
    }

    final count = _lessonDates[_dateKey(date)] ?? 0;
    return GestureDetector(
      onTap: () {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${date.month}月${date.day}日 · 上课 $count 次'),
            duration: const Duration(milliseconds: 600),
          ),
        );
      },
      child: Container(
        width: _cellSize,
        height: _cellSize,
        margin: const EdgeInsets.only(bottom: _cellGap),
        decoration: BoxDecoration(
          color: _cellColor(count),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }

  //颜色梯度：0 课灰 / 1 课浅绿 / 2 课中绿 / 3 课及以上深绿
  Color _cellColor(int count) {
    if (count == 0) return const Color(0xFFEBEDF0);
    if (count == 1) return const Color(0xFF9BE9A8);
    if (count == 2) return const Color(0xFF40C463);
    return const Color(0xFF216E39);
  }

  //左侧星期标注：只标 Mon / Wed / Fri（GitHub 风格）
  Widget _buildWeekdayLabels() {
    return Column(
      children: [
        for (var row = 0; row < 7; row++)
          SizedBox(
            width: 30,
            height: _cellSize + _cellGap,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                switch (row) {
                  0 => 'Mon',
                  2 => 'Wed',
                  4 => 'Fri',
                  _ => '',
                },
                style: const TextStyle(fontSize: 10, color: Color(0xFFB0B0B0)),
              ),
            ),
          ),
      ],
    );
  }

  static String _dateKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  */

  //内置服务商表：DeepSeek 官方（接口+模型内置，实测可用组合，只填 Key）；OpenAI 兼容自填
  static const _providers = <String, (String, String, String)>{
    'deepseek': ('DeepSeek 官方', 'https://api.deepseek.com', 'deepseek-v4-flash'),
    'openai': ('OpenAI 兼容', '', ''),
  };

  //配置档：服务商+模型+Key 三者配套（不同 Key 对应不同接口/模型，不可拆分管理）。
  //惰性迁移：旧配置无 profiles 时，把顶层 apiUrl/model/apiKey 组装为首档（不落盘，保存时才写入）。
  List<Map<String, dynamic>> get _profiles {
    final list = [
      for (final p in (_config['profiles'] as List? ?? []))
        Map<String, dynamic>.from(p as Map),
    ];
    if (list.isEmpty && (_config['apiKey'] as String? ?? '').isNotEmpty) {
      final url = _config['apiUrl'] as String? ?? '';
      final isDeepseek = url == _providers['deepseek']!.$2;
      list.add({
        'name': isDeepseek ? 'DeepSeek 官方' : 'OpenAI 兼容',
        'provider': isDeepseek ? 'deepseek' : 'openai',
        'apiUrl': url,
        'model': _config['model'] as String? ?? '',
        'apiKey': _config['apiKey'],
      });
    }
    return list;
  }

  //使用中配置档名；失效（被删/未迁移）时回落首档，空列表返回空串
  String get _activeName {
    final name = _config['active'] as String? ?? '';
    final profiles = _profiles;
    if (profiles.any((p) => p['name'] == name)) return name;
    return profiles.isEmpty ? '' : profiles.first['name'] as String;
  }

  //当前 API 配置摘要卡：使用中档的 名称/模型/Key 遮显；点击进入配置对话框
  Widget _buildApiSummary() {
    if (_loading) return const SizedBox.shrink();
    final matched = _profiles.where((p) => p['name'] == _activeName).toList();
    if (matched.isEmpty) {
      return Container(
        color: Colors.white,
        margin: const EdgeInsets.all(16),
        child: const ListTile(
          leading: Icon(Icons.vpn_key_outlined),
          title: Text('API 未配置'),
          subtitle: Text('点击设置服务商、模型与 Key'),
          trailing: Icon(Icons.chevron_right),
        ),
      );
    }
    final p = matched.first;
    return Container(
      color: Colors.white,
      margin: const EdgeInsets.all(16),
      child: ListTile(
        leading: const Icon(Icons.vpn_key_outlined),
        title: Text(p['name'] as String),
        subtitle: Text(
          '${p['model']} · ${_maskKey(p['apiKey'] as String? ?? '')}',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: _showApiConfigDialog,
      ),
    );
  }

  //API 配置对话框：配置档列表（服务商+模型+Key 三者配套，不可拆分管理）。
  //点击档即选用；添加/编辑走表单子对话框；检验连通性针对选中档。
  //所有改动在对话框内存态，点「保存」一次性落盘 CONFIG.json（取消即丢弃）。
  Future<void> _showApiConfigDialog() async {
    var profiles = _profiles;
    var active = _activeName;
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
                      active == p['name']
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      size: 20,
                      color: const Color(0xFF07C160),
                    ),
                    title: Text(p['name'] as String? ?? '配置'),
                    subtitle: Text(
                      '${_providers[p['provider'] as String? ?? 'openai']?.$1 ?? 'OpenAI 兼容'}'
                      ' · ${p['model']} · ${_maskKey(p['apiKey'] as String? ?? '')}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    onTap: () =>
                        setDialogState(() => active = p['name'] as String),
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
                                  q['name'] == p['name'] ? edited : q,
                              ];
                              //编辑中的档若被改名且是选中档 → 同步 active
                              if (active == p['name']) {
                                active = edited['name']!;
                              }
                            });
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline, size: 20),
                          tooltip: '删除',
                          onPressed: () => setDialogState(() {
                            profiles = <Map<String, dynamic>>[
                              ...profiles.where((q) => q['name'] != p['name']),
                            ];
                            if (active == p['name']) {
                              active = profiles.isEmpty
                                  ? ''
                                  : profiles.first['name'] as String;
                            }
                          }),
                        ),
                      ],
                    ),
                  ),
                if (profiles.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text(
                      '尚未保存配置，点击「添加配置」',
                      style: TextStyle(
                        fontSize: 12,
                        color: Color(0xFF999999),
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
                      setDialogState(
                        () => profiles = <Map<String, dynamic>>[
                          ...profiles,
                          added,
                        ],
                      );
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
                            ? const Color(0xFF07C160)
                            : const Color(0xFFE64340),
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
                      final sel = profiles
                          .where((p) => p['name'] == active)
                          .toList();
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

    //落盘：选中档同步到顶层三字段（LLM 调用层唯一事实，调用层不感知配置档概念）
    final sel = profiles.where((p) => p['name'] == active).toList();
    if (sel.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('请先添加并选中一个配置'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    final p = sel.first;
    final next = {
      'profiles': profiles,
      'active': active,
      'apiUrl': p['apiUrl'],
      'model': p['model'],
      'apiKey': p['apiKey'],
    };
    setState(() => _config = next);
    await StorageService().saveConfig(next);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('API 配置已保存'),
        duration: Duration(seconds: 1),
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
      text: existing?['name'] as String? ??
          (provider == 'deepseek'
              ? _providers['deepseek']!.$1
              : _providers['openai']!.$1),
    );
    final baseUrlC = TextEditingController(
      text: existing?['apiUrl'] as String? ?? '',
    );
    //模型预填：编辑沿用档内值；添加时 DeepSeek 用内置默认、兼容留空
    final modelC = TextEditingController(
      text: existing?['model'] as String? ??
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
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF999999),
                      ),
                    ),
                  )
                else
                  TextField(
                    controller: baseUrlC,
                    onChanged: (v) => _onBaseUrlChanged(baseUrlC), //实时裁剪 v1 后的多余路径
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
                            ? const Color(0xFF07C160)
                            : const Color(0xFFE64340),
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
