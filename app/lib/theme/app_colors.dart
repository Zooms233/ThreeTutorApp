import 'package:flutter/material.dart';

/// 语义色板：深浅两套，通过 ThemeExtension 挂到 ThemeData 上。
///
/// 浅色套 = 微信风现状（灰底 + 白卡 + 绿强调）；
/// 深色套 = GitHub Dark（经典 #24292E 系）：
///   背景 #24292E / 浮起 #1F2428 / 主文字 #E1E4E8 / 次要 #959DA5 /
///   链接 #79B8FF / 按钮绿 #176F2C / 警示 #F97583 / 贡献图 #0E4429~#39D353，
///   用户气泡沿用微信深色（底 #25352C + 字 #95EC69）。
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.background, //页面/顶栏背景（浅 #EDEDED / 深 #24292E）
    required this.surface, //卡片/导师气泡/底栏/输入条（白 / #1F2428）
    required this.textPrimary, //主文字（#191919 / #E1E4E8）
    required this.textSecondary, //次要文字（#999999 / #959DA5）
    required this.textTertiary, //更淡文字：时间戳/版本号（#B0B0B0 / #6A737D）
    required this.textFaint, //弱文字：分组标题/表单标签（#808080 / #6A737D）
    required this.divider, //分割线（#E5E5E5 / #30363D）
    required this.accent, //强调绿：图标/文字/选中态（#07C160 / #3FB950）
    required this.accentSolid, //实心按钮底（#07C160 / #176F2C）
    required this.link, //链接蓝（#576B95 / #79B8FF）
    required this.danger, //警示文字/图标（#FA5151 / #F97583）
    required this.dangerSolid, //警示按钮底（#E64340 / #CB2431）
    required this.userBubble, //用户气泡底（#95EC69 / #25352C）
    required this.userBubbleText, //用户气泡文字（#191919 / #95EC69）
    required this.iconFaint, //弱图标：chevron/空状态（#C8C8C8 / #444D56）
    required this.disabledSurface, //禁用底：发送按钮（#D8D8D8 / #30363D）
    required this.editBarBg, //修改提示条底（#F2F2F2 / #2F363D）
    //热力图（GitHub contribution 风格）：浅色越深越热、深色越亮越热
    required this.heatEmpty,
    required this.heatL1,
    required this.heatL2,
    required this.heatL3,
    required this.heatL4,
  });

  final Color background;
  final Color surface;
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;
  final Color textFaint;
  final Color divider;
  final Color accent;
  final Color accentSolid;
  final Color link;
  final Color danger;
  final Color dangerSolid;
  final Color userBubble;
  final Color userBubbleText;
  final Color iconFaint;
  final Color disabledSurface;
  final Color editBarBg;
  final Color heatEmpty;
  final Color heatL1;
  final Color heatL2;
  final Color heatL3;
  final Color heatL4;

  /// 从 BuildContext 取当前主题的语义色板
  static AppColors of(BuildContext context) =>
      Theme.of(context).extension<AppColors>()!;

  /// 浅色套：微信风现状
  static const light = AppColors(
    background: Color(0xFFEDEDED),
    surface: Colors.white,
    textPrimary: Color(0xFF191919),
    textSecondary: Color(0xFF999999),
    textTertiary: Color(0xFFB0B0B0),
    textFaint: Color(0xFF808080),
    divider: Color(0xFFE5E5E5),
    accent: Color(0xFF07C160),
    accentSolid: Color(0xFF07C160),
    link: Color(0xFF576B95),
    danger: Color(0xFFFA5151),
    dangerSolid: Color(0xFFE64340),
    userBubble: Color(0xFF95EC69),
    userBubbleText: Color(0xFF191919),
    iconFaint: Color(0xFFC8C8C8),
    disabledSurface: Color(0xFFD8D8D8),
    editBarBg: Color(0xFFF2F2F2),
    heatEmpty: Color(0xFFEBEDF0),
    heatL1: Color(0xFF9BE9A8),
    heatL2: Color(0xFF40C463),
    heatL3: Color(0xFF30A14E),
    heatL4: Color(0xFF216E39),
  );

  /// 深色套：GitHub Dark 系
  static const dark = AppColors(
    background: Color(0xFF24292E),
    surface: Color(0xFF1F2428),
    textPrimary: Color(0xFFE1E4E8),
    textSecondary: Color(0xFF959DA5),
    textTertiary: Color(0xFF6A737D),
    textFaint: Color(0xFF6A737D),
    divider: Color(0xFF30363D),
    accent: Color(0xFF3FB950),
    accentSolid: Color(0xFF176F2C),
    link: Color(0xFF79B8FF),
    danger: Color(0xFFF97583),
    dangerSolid: Color(0xFFCB2431),
    userBubble: Color(0xFF25352C),
    userBubbleText: Color(0xFF95EC69),
    iconFaint: Color(0xFF444D56),
    disabledSurface: Color(0xFF30363D),
    editBarBg: Color(0xFF2F363D),
    heatEmpty: Color(0xFF21262D),
    heatL1: Color(0xFF0E4429),
    heatL2: Color(0xFF006D32),
    heatL3: Color(0xFF26A641),
    heatL4: Color(0xFF39D353),
  );

  @override
  AppColors copyWith({
    Color? background,
    Color? surface,
    Color? textPrimary,
    Color? textSecondary,
    Color? textTertiary,
    Color? textFaint,
    Color? divider,
    Color? accent,
    Color? accentSolid,
    Color? link,
    Color? danger,
    Color? dangerSolid,
    Color? userBubble,
    Color? userBubbleText,
    Color? iconFaint,
    Color? disabledSurface,
    Color? editBarBg,
    Color? heatEmpty,
    Color? heatL1,
    Color? heatL2,
    Color? heatL3,
    Color? heatL4,
  }) {
    return AppColors(
      background: background ?? this.background,
      surface: surface ?? this.surface,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textTertiary: textTertiary ?? this.textTertiary,
      textFaint: textFaint ?? this.textFaint,
      divider: divider ?? this.divider,
      accent: accent ?? this.accent,
      accentSolid: accentSolid ?? this.accentSolid,
      link: link ?? this.link,
      danger: danger ?? this.danger,
      dangerSolid: dangerSolid ?? this.dangerSolid,
      userBubble: userBubble ?? this.userBubble,
      userBubbleText: userBubbleText ?? this.userBubbleText,
      iconFaint: iconFaint ?? this.iconFaint,
      disabledSurface: disabledSurface ?? this.disabledSurface,
      editBarBg: editBarBg ?? this.editBarBg,
      heatEmpty: heatEmpty ?? this.heatEmpty,
      heatL1: heatL1 ?? this.heatL1,
      heatL2: heatL2 ?? this.heatL2,
      heatL3: heatL3 ?? this.heatL3,
      heatL4: heatL4 ?? this.heatL4,
    );
  }

  @override
  AppColors lerp(ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) return this;
    Color lc(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppColors(
      background: lc(background, other.background),
      surface: lc(surface, other.surface),
      textPrimary: lc(textPrimary, other.textPrimary),
      textSecondary: lc(textSecondary, other.textSecondary),
      textTertiary: lc(textTertiary, other.textTertiary),
      textFaint: lc(textFaint, other.textFaint),
      divider: lc(divider, other.divider),
      accent: lc(accent, other.accent),
      accentSolid: lc(accentSolid, other.accentSolid),
      link: lc(link, other.link),
      danger: lc(danger, other.danger),
      dangerSolid: lc(dangerSolid, other.dangerSolid),
      userBubble: lc(userBubble, other.userBubble),
      userBubbleText: lc(userBubbleText, other.userBubbleText),
      iconFaint: lc(iconFaint, other.iconFaint),
      disabledSurface: lc(disabledSurface, other.disabledSurface),
      editBarBg: lc(editBarBg, other.editBarBg),
      heatEmpty: lc(heatEmpty, other.heatEmpty),
      heatL1: lc(heatL1, other.heatL1),
      heatL2: lc(heatL2, other.heatL2),
      heatL3: lc(heatL3, other.heatL3),
      heatL4: lc(heatL4, other.heatL4),
    );
  }
}
