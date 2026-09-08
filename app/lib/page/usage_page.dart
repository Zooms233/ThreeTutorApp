import 'package:flutter/material.dart';

import 'package:three_tutor/service/storage.dart';

///用量统计页：现读数据根 USAGE.jsonl 聚合展示（账本文件即唯一事实，每次进入现算不缓存）。
///结构 = 顶部总账卡 + 课程分组（ExpansionTile）→ 课次小节 → 单次调用行（时间 场景 入/出/命中）。
///「输入」在行内拆出命中数：命中部分约 1/10 计价，混在总输入里看不出缓存省了多少钱。
class UsagePage extends StatefulWidget {
  const UsagePage({super.key});

  @override
  State<UsagePage> createState() => _UsagePageState();
}

class _UsagePageState extends State<UsagePage> {
  bool _loading = true;
  List<Map<String, dynamic>> _rows = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rows = await StorageService().readUsageLog();
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _loading = false;
    });
  }

  //清理已删除课程的用量残留：先扫描预览（无残留则提示），列出课程红字确认后删除并刷新
  Future<void> _purgeOrphans() async {
    final scan = await StorageService().orphanUsageScan();
    if (!mounted) return;
    if (scan.courses.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('没有已删除课程的残留记录'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    final names = scan.courses.toList()..sort();
    final preview = names.length <= 5
        ? names.join('、')
        : '${names.take(5).join('、')} 等 ${names.length} 门';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清理用量残留'),
        content: Text(
          '检测到 ${names.length} 门已删除课程的用量记录（共 ${scan.rows} 条）：\n'
          '$preview\n\n删除后不可恢复，确定清理吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFE64340), //红色警示：不可逆操作
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清理'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final removed = await StorageService().purgeOrphanUsage();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已清理 ${names.length} 门课程的 $removed 条记录'),
        duration: const Duration(seconds: 2),
      ),
    );
    _load();
  }

  //账本数值字段便捷读取（缺失/脏数据按 0 计）
  int _num(Map<String, dynamic> r, String k) => (r[k] as num?)?.toInt() ?? 0;

  //时间显示：ISO → 「M月d日 HH:mm」；解析失败返回原串（容错）
  String _fmtTime(String s) {
    final d = DateTime.tryParse(s);
    if (d == null) return s;
    return '${d.month}月${d.day}日 '
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_rows.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('用量统计')),
        body: const Center(
          child: Text(
            '暂无用量记录\n上过课或问答后，这里会出现统计',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFF999999)),
          ),
        ),
      );
    }

    //总账：prompt 总输入 = 未命中写入 + 缓存命中
    var totalWrite = 0, totalOut = 0, totalHit = 0;
    for (final r in _rows) {
      totalWrite += _num(r, 'input');
      totalOut += _num(r, 'output');
      totalHit += _num(r, 'cacheRead');
    }
    final totalPrompt = totalWrite + totalHit;
    final totalRate = totalPrompt == 0 ? 0.0 : totalHit * 100 / totalPrompt;

    //课程分组；组间按最近一次调用时间降序（最近在用的课程排前面）
    final byCourse = <String, List<Map<String, dynamic>>>{};
    for (final r in _rows) {
      byCourse.putIfAbsent(r['course'] as String? ?? '未知课程', () => []).add(r);
    }
    final courses = byCourse.keys.toList()
      ..sort(
        (a, b) => (byCourse[b]!.last['time'] as String? ?? '').compareTo(
          byCourse[a]!.last['time'] as String? ?? '',
        ),
      );

    return Scaffold(
      appBar: AppBar(
        title: const Text('用量统计'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '清理已删除课程的残留记录',
            onPressed: _purgeOrphans,
          ),
        ],
      ),
      body: ListView(
        children: [
          _buildHeatmap(_rows),
          _totalCard(totalPrompt, totalWrite, totalOut, totalHit, totalRate),
          for (final c in courses) _courseTile(c, byCourse[c]!),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  // —— 热力图（GitHub contribution 风格，按 token 消耗着色）——
  //颜色深度按「计费加权热度」而非 token 裸量：DeepSeek 官方定价比例
  //（命中 1 / 写入 4 / 输出 16，元每百万 token 归一）作权重——费用才是用户感知的
  //「消耗强度」；悬停仍显示真实 token 数（不做价格换算展示）。
  //档位按非零日四分位自适应（GitHub 同款思路），抗用量增长。
  Widget _buildHeatmap(List<Map<String, dynamic>> rows) {
    //按日聚合：dayTokens（悬停显示的真实 token 量）与 dayHeat（着色权重）
    final dayTokens = <String, int>{};
    final dayHeat = <String, double>{};
    for (final r in rows) {
      final t = DateTime.tryParse(r['time'] as String? ?? '');
      if (t == null) continue;
      final key = '${t.year}-${t.month}-${t.day}';
      final write = _num(r, 'input');
      final hit = _num(r, 'cacheRead');
      final out = _num(r, 'output');
      dayTokens[key] = (dayTokens[key] ?? 0) + write + hit + out;
      dayHeat[key] = (dayHeat[key] ?? 0) + write * 4.0 + hit + out * 16.0;
    }
    //非零日四分位 → 4 档非零色阶（GitHub 标准色）
    final heats = dayHeat.values.where((h) => h > 0).toList()..sort();
    double q(double p) => heats.isEmpty
        ? 0
        : heats[(heats.length * p).clamp(0, heats.length - 1).floor()];
    final q1 = q(0.25), q2 = q(0.5), q3 = q(0.75);
    Color colorOf(double heat) {
      if (heat <= 0) return const Color(0xFFEBEDF0);
      if (heat <= q1) return const Color(0xFF9BE9A8);
      if (heat <= q2) return const Color(0xFF40C463);
      if (heat <= q3) return const Color(0xFF30A14E);
      return const Color(0xFF216E39);
    }

    //窗口：最多 26 周（半年），列数按可用宽度自适应；起点对齐周一
    return Container(
      color: Colors.white,
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      padding: const EdgeInsets.all(12),
      child: LayoutBuilder(
        builder: (context, c) {
          const cell = 11.0, gap = 3.0, labelW = 18.0, monthH = 14.0;
          final cols = ((c.maxWidth - labelW - 16) / (cell + gap))
              .floor()
              .clamp(4, 26);
          final now = DateTime.now();
          final today = DateTime(now.year, now.month, now.day);
          final start = today.subtract(
            Duration(days: now.weekday - 1 + 7 * (cols - 1)),
          );
          //统计行：窗口内真实 token 总量
          var windowTokens = 0;
          for (final e in dayTokens.entries) {
            final p = e.key.split('-').map(int.parse).toList();
            final d = DateTime(p[0], p[1], p[2]);
            if (!d.isBefore(start) && !d.isAfter(today)) {
              windowTokens += e.value;
            }
          }

          //单格：有数据包 Tooltip（点按触发）；无数据/未来日期纯色块
          Widget cellBox(DateTime d) {
            final key = '${d.year}-${d.month}-${d.day}';
            final tokens = d.isAfter(today) ? 0 : (dayTokens[key] ?? 0);
            final box = Container(
              width: cell,
              height: cell,
              margin: const EdgeInsets.symmetric(vertical: gap / 2),
              decoration: BoxDecoration(
                color: colorOf(d.isAfter(today) ? 0 : (dayHeat[key] ?? 0)),
                borderRadius: BorderRadius.circular(2),
              ),
            );
            if (tokens <= 0) return box;
            return Tooltip(
              message: '${d.month}月${d.day}日 · 消耗 ${_fmtTokens(tokens)} token',
              triggerMode: TooltipTriggerMode.tap,
              child: box,
            );
          }

          //一列（一周）：顶部月份标注区 + 周一至周日 7 格；
          //包含某月 1 日的列标注该月（OverflowBox 允许文字延伸到右侧空格）
          Widget weekColumn(DateTime monday) {
            String? monthLabel;
            for (var i = 0; i < 7; i++) {
              final d = monday.add(Duration(days: i));
              if (d.day == 1) monthLabel = '${d.month}月';
            }
            return Column(
              children: [
                SizedBox(
                  width: cell + gap,
                  height: monthH,
                  child: monthLabel == null
                      ? null
                      : OverflowBox(
                          maxWidth: double.infinity,
                          alignment: Alignment.centerLeft,
                          child: Text(
                            monthLabel,
                            style: const TextStyle(
                              fontSize: 9,
                              color: Color(0xFF999999),
                            ),
                          ),
                        ),
                ),
                for (var i = 0; i < 7; i++)
                  cellBox(monday.add(Duration(days: i))),
              ],
            );
          }

          //网格内容居中（列数封顶 26 后宽屏右侧留白，居中避免左偏；
          //统计行随网格居中，避免左对齐与网格错位）
          return Column(
            children: [
              Text(
                '近半年消耗 ${_fmtTokens(windowTokens)} token',
                style: const TextStyle(fontSize: 13, color: Color(0xFF666666)),
              ),
              const SizedBox(height: 8),
              Center(
                child: SizedBox(
                  height: monthH + 7 * (cell + gap),
                  //必须 min：默认 max 会占满卡片宽度，Center 失去居中对象
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      //左侧星期标注：第 1/3/5 行显示「一/三/五」
                      SizedBox(
                        width: labelW,
                        child: Column(
                          children: [
                            SizedBox(height: monthH),
                            for (var i = 0; i < 7; i++)
                              SizedBox(
                                width: labelW,
                                height: cell + gap,
                                child: [0, 2, 4].contains(i)
                                    ? Text(
                                        ['一', '三', '五'][(i / 2).floor()],
                                        style: const TextStyle(
                                          fontSize: 9,
                                          color: Color(0xFF999999),
                                        ),
                                      )
                                    : null,
                              ),
                          ],
                        ),
                      ),
                      for (var w = 0; w < cols; w++)
                        weekColumn(start.add(Duration(days: 7 * w))),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  //token 量简写（45.1k / 1.2M）
  String _fmtTokens(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '$n';
  }

  //总账卡：三列数字 + 口径说明小字
  Widget _totalCard(int prompt, int write, int out, int hit, double rate) {
    return Container(
      color: Colors.white,
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _stat('$prompt', '总输入', '（命中 $hit）'),
              _stat('$out', '总输出', ''),
              _stat('${rate.toStringAsFixed(1)}%', '缓存命中率', ''),
            ],
          ),
          const SizedBox(height: 8),
          //命中为 0 时拆分式说明没有信息量，不显示
          if (hit > 0)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                '输入 = 写入 $write + 命中 $hit；命中部分约 1/10 计价',
                style: TextStyle(fontSize: 11, color: Color(0xFFB0B0B0)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _stat(String value, String label, String sub) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(fontSize: 12, color: Color(0xFF999999)),
        ),
        if (sub.isNotEmpty)
          Text(
            sub,
            style: const TextStyle(fontSize: 11, color: Color(0xFFB0B0B0)),
          ),
      ],
    );
  }

  //课程分组：ExpansionTile 内按课次分小节，每行一次调用（append 顺序即时间序）
  Widget _courseTile(String course, List<Map<String, dynamic>> rows) {
    var write = 0, out = 0, hit = 0;
    for (final r in rows) {
      write += _num(r, 'input');
      out += _num(r, 'output');
      hit += _num(r, 'cacheRead');
    }
    final prompt = write + hit;
    final rate = prompt == 0 ? 0.0 : hit * 100 / prompt;
    //课次分组（保序）
    final byLesson = <String, List<Map<String, dynamic>>>{};
    for (final r in rows) {
      byLesson.putIfAbsent(r['lesson'] as String? ?? '无课次上下文', () => []).add(r);
    }
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Material(
        color: Colors.white, //背景由 Material 承担（ExpansionTile 内部是 ListTile，水波纹可见）
        child: ExpansionTile(
          title: Text(course),
          subtitle: Text(
            '${rows.length} 次 · 入 $prompt · 出 $out · 命中率 ${rate.toStringAsFixed(1)}%',
            style: const TextStyle(fontSize: 12),
          ),
          children: [
            for (final e in byLesson.entries) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    //lesson 存的是留档文件名（lesson-003.jsonl），展示去后缀
                    e.key.replaceAll(RegExp(r'\.jsonl$'), ''),
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF07C160),
                    ),
                  ),
                ),
              ),
              for (final r in e.value)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${_fmtTime(r['time'] as String? ?? '')} · ${r['scene'] ?? ''}',
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      Text(
                        '入 ${_num(r, 'input') + _num(r, 'cacheRead')}'
                        '（命中 ${_num(r, 'cacheRead')}）出 ${_num(r, 'output')}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF666666),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 4),
            ],
          ],
        ),
      ),
    );
  }
}
