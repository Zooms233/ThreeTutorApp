import 'package:flutter/material.dart';
import 'package:three_tutor/theme/app_colors.dart';

/// 全局主题模式（三态：明亮/深色/自动跟随系统）。
/// 设置页切换时写入；启动时从 CONFIG.json 恢复（见 main.dart）。
final ValueNotifier<ThemeMode> themeModeNotifier = ValueNotifier(ThemeMode.system);

/// 浅色主题：微信风现状（灰底 + 白卡 + 绿强调）
ThemeData buildLightTheme() => _buildTheme(Brightness.light, AppColors.light);

/// 深色主题：GitHub Dark 系（#24292E 底 + #1F2428 浮起层 + 绿强调）
ThemeData buildDarkTheme() => _buildTheme(Brightness.dark, AppColors.dark);

ThemeData _buildTheme(Brightness brightness, AppColors colors) {
  final isDark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF07C160), //绿作为种子色：深浅两套统一强调色系
    brightness: brightness,
  );

  return ThemeData(
    //fontFamily：思源黑体（内置 assets/fonts，Regular + Bold）；LaTeX 公式同步该字号与字距
    fontFamily: 'SourceHanSansCN',
    colorScheme: scheme,
    //页面与顶栏同为底色，列表内容用 surface 色行浮起（浅=浅灰/白，深=深底/浮起层）
    scaffoldBackgroundColor: colors.background,
    appBarTheme: AppBarTheme(
      backgroundColor: colors.background,
      foregroundColor: colors.textPrimary,
      scrolledUnderElevation: 0, //列表滚动时顶栏不因 surfaceTint 变色
    ),
    //全局分割线：极细线风格
    dividerTheme: DividerThemeData(
      color: colors.divider,
      thickness: 0.5,
    ),
    //底部导航栏：surface 底 + 选中绿 / 未选中灰
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: colors.surface,
      indicatorColor: isDark
          ? const Color(0x1A3FB950) //深色：绿 10% 透明度的选中胶囊
          : const Color(0x1A07C160),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        return states.contains(WidgetState.selected)
            ? IconThemeData(color: colors.accent)
            : IconThemeData(color: colors.textSecondary);
      }),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        return states.contains(WidgetState.selected)
            ? TextStyle(fontSize: 12, color: colors.accent)
            : TextStyle(fontSize: 12, color: colors.textSecondary);
      }),
    ),
    //实心按钮：浅色默认派生绿；深色用 GitHub 按钮绿（#176F2C 底 + #DCFFE4 字，不刺眼）
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: isDark ? colors.accentSolid : null,
        foregroundColor: isDark ? const Color(0xFFDCFFE4) : null,
      ),
    ),
    //对话框：深色下用浮起层色，与卡片同层级
    dialogTheme: DialogThemeData(
      backgroundColor: isDark ? colors.surface : null,
    ),
    //语义色板随主题挂载（页面经 AppColors.of(context) 读取）
    extensions: [colors],
  );
}
