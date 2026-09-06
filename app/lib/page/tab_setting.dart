import 'package:flutter/material.dart';
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

  //API 配置对话框：三项输入保存至 CONFIG.json
  Future<void> _showApiConfigDialog() async {
    final urlController = TextEditingController(
      text: _config['apiUrl'] as String? ?? '',
    );
    final keyController = TextEditingController(
      text: _config['apiKey'] as String? ?? '',
    );
    final modelController = TextEditingController(
      text: _config['model'] as String? ?? '',
    );

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('API 配置'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: urlController,
              decoration: const InputDecoration(
                labelText: 'API URL',
                hintText: 'https://api.deepseek.com',
              ),
            ),
            TextField(
              controller: keyController,
              obscureText: true, //Key 遮显
              decoration: const InputDecoration(labelText: 'API Key'),
            ),
            TextField(
              controller: modelController,
              decoration: const InputDecoration(
                labelText: 'Model',
                hintText: 'deepseek-v4-flash',
              ),
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
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved != true || !mounted) return; //用户取消

    //保存（只更新三项，其余字段原样保留）
    setState(() {
      _config['apiUrl'] = urlController.text.trim();
      _config['apiKey'] = keyController.text.trim();
      _config['model'] = modelController.text.trim();
    });
    await StorageService().saveConfig(_config);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('API 配置已保存'),
        duration: Duration(seconds: 1),
      ),
    );
  }
}
