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
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'API 配置',
            onPressed: _showApiConfigDialog,
          ),
        ],
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

  //当前服务商：显式字段优先；缺省按 apiUrl 匹配内置 DeepSeek 推断（旧配置迁移）
  String get _currentProvider {
    final p = _config['provider'] as String?;
    if (p != null && _providers.containsKey(p)) return p;
    return (_config['apiUrl'] as String? ?? '') == _providers['deepseek']!.$2
        ? 'deepseek'
        : 'openai';
  }

  //Key 库（CONFIG.keys 数组 → List<Map>，副本）
  List<Map<String, dynamic>> get _savedKeys => [
        for (final k in (_config['keys'] as List? ?? []))
          Map<String, dynamic>.from(k as Map),
      ];

  //当前 API 配置摘要卡：服务商 / 模型 / 使用中的 Key（遮显+备注名）；点击进入配置对话框
  Widget _buildApiSummary() {
    if (_loading) return const SizedBox.shrink();
    final info = _providers[_currentProvider]!;
    final isDeepseek = _currentProvider == 'deepseek';
    final key = _config['apiKey'] as String? ?? '';
    final model = isDeepseek ? info.$3 : (_config['model'] as String? ?? '');
    final matched = _savedKeys.where((k) => k['value'] == key).toList();
    final keyLabel = key.isEmpty
        ? '未配置'
        : (matched.isNotEmpty ? matched.first['label'] as String : '未入库');
    return Container(
      color: Colors.white,
      margin: const EdgeInsets.all(16),
      child: ListTile(
        leading: const Icon(Icons.vpn_key_outlined),
        title: Text(info.$1),
        subtitle: Text(
          '$model · ${key.isEmpty ? '—' : _maskKey(key)}（$keyLabel）',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: _showApiConfigDialog,
      ),
    );
  }

  //API 配置对话框：服务商选择 → DeepSeek 只填 Key（接口/模型内置）；
  //OpenAI 兼容自填 Base URL + Model。Key 库支持添加/删除/选用；
  //所有改动在对话框内存态，点「保存」一次性落盘 CONFIG.json（取消即丢弃）。
  Future<void> _showApiConfigDialog() async {
    var provider = _currentProvider;
    final baseUrlC = TextEditingController(
      text: _config['apiUrl'] as String? ?? '',
    );
    //模型可修改：显式 provider=deepseek 时沿用已保存值（可能被用户改过）；
    //推断迁移或从其他服务商切回时预填内置默认；OpenAI 兼容沿用已存值
    final modelC = TextEditingController(
      text: provider == 'deepseek'
          ? (_config['provider'] == 'deepseek'
              ? (_config['model'] as String? ?? _providers['deepseek']!.$3)
              : _providers['deepseek']!.$3)
          : (_config['model'] as String? ?? ''),
    );
    final keyC = TextEditingController(
      text: _config['apiKey'] as String? ?? '',
    );
    var keys = _savedKeys;
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
                DropdownButtonFormField<String>(
                  initialValue: provider, //下拉自身内部态驱动显示，外部变量仅同步给 if 分支
                  decoration: const InputDecoration(labelText: '服务商'),
                  items: [
                    for (final e in _providers.entries)
                      DropdownMenuItem(value: e.key, child: Text(e.value.$1)),
                  ],
                  onChanged: (v) => setDialogState(() => provider = v!),
                ),
                //DeepSeek：接口内置，模型预填可修改；OpenAI 兼容：自填 Base URL 与 Model
                if (provider == 'deepseek') ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 4, bottom: 4),
                    child: Text(
                      '接口 ${_providers['deepseek']!.$2}（内置）· 模型可修改',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF999999),
                      ),
                    ),
                  ),
                  TextField(
                    controller: modelC,
                    decoration: const InputDecoration(
                      labelText: 'Model（DeepSeek）',
                      hintText: 'deepseek-v4-flash',
                    ),
                  ),
                ] else ...[
                  TextField(
                    controller: baseUrlC,
                    decoration: const InputDecoration(
                      labelText: 'Base URL',
                      hintText: 'https://api.example.com/v1',
                    ),
                  ),
                  TextField(
                    controller: modelC,
                    decoration: const InputDecoration(
                      labelText: 'Model',
                      hintText: 'gpt-4o-mini',
                    ),
                  ),
                ],
                TextField(
                  controller: keyC,
                  obscureText: true, //Key 遮显
                  decoration: const InputDecoration(
                    labelText: 'API Key（当前使用）',
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Text(
                      '已保存的 Key',
                      style: TextStyle(fontSize: 13, color: Color(0xFF666666)),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: () async {
                        final added = await _addKeyDialog(keys.length + 1);
                        if (added == null) return;
                        setDialogState(() {
                          keys = [...keys, added];
                          keyC.text = added['value']!; //新添加即选用
                        });
                      },
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('添加'),
                    ),
                  ],
                ),
                //Key 库列表：点击选用；尾随删除（删使用中的 Key 同步清空当前值）
                for (final k in keys)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      keyC.text.trim() == k['value']
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      size: 20,
                      color: const Color(0xFF07C160),
                    ),
                    title: Text(k['label'] as String? ?? 'Key'),
                    subtitle: Text(
                      _maskKey(k['value'] as String? ?? ''),
                      style: const TextStyle(fontSize: 12),
                    ),
                    onTap: () =>
                        setDialogState(() => keyC.text = k['value'] as String),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline, size: 20),
                      onPressed: () => setDialogState(() {
                        keys = keys
                            .where((x) => x['value'] != k['value'])
                            .toList();
                        if (keyC.text.trim() == k['value']) keyC.clear();
                      }),
                    ),
                  ),
                if (keys.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text(
                      '尚未保存 Key，点击「添加」入库',
                      style: TextStyle(
                        fontSize: 12,
                        color: Color(0xFF999999),
                      ),
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

    //组装落盘：DeepSeek 覆盖内置接口/模型；手填未入库的 Key 自动入库
    final key = keyC.text.trim();
    final deepseek = provider == 'deepseek';
    final apiUrl = deepseek ? _providers['deepseek']!.$2 : baseUrlC.text.trim();
    final model = modelC.text.trim(); //两模式同源（DeepSeek 模式预填可修改）
    if (apiUrl.isEmpty || model.isEmpty || key.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('接口地址、模型与 API Key 均不能为空'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    if (!keys.any((k) => k['value'] == key)) {
      keys = [...keys, {'label': '默认', 'value': key}];
    }
    final next = {
      ..._config,
      'provider': provider,
      'apiUrl': apiUrl,
      'model': model,
      'apiKey': key,
      'keys': keys,
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

  //添加 Key 子对话框：备注 + Key 值；确定返回 Map，取消返回 null
  Future<Map<String, String>?> _addKeyDialog(int index) async {
    final labelC = TextEditingController(text: 'Key $index');
    final valueC = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加 Key'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: labelC,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '备注（如：官方 / 备用）',
              ),
            ),
            TextField(
              controller: valueC,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Key 值'),
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
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (ok != true || valueC.text.trim().isEmpty) return null;
    return {'label': labelC.text.trim(), 'value': valueC.text.trim()};
  }

  //Key 遮显：保留前 6 后 4，中间打点（sk-8a8…H9x 式）
  String _maskKey(String key) {
    if (key.length <= 12) return '•' * key.length;
    return '${key.substring(0, 6)}••••••${key.substring(key.length - 4)}';
  }
}
