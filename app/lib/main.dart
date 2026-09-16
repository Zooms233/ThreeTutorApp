import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:three_tutor/page/chat/tab_chat.dart';
import 'package:three_tutor/page/contact/tab_contact.dart';
import 'package:three_tutor/page/setting/tab_setting.dart';
import 'package:three_tutor/service/storage.dart';
import 'package:three_tutor/service/three_tutor_service.dart';
import 'package:three_tutor/theme/app_colors.dart';
import 'package:three_tutor/theme/app_theme.dart';

Future<void> main() async {
  //在 await 之前初始化绑定（Android 权限申请用到了平台通道）
  WidgetsFlutterBinding.ensureInitialized();
  await _ensureStoragePermission();
  await _restoreThemeMode(); //恢复用户主题偏好（明亮/深色/自动），失败静默用默认
  runApp(const MyApp());
}

//从 CONFIG.json 恢复主题模式与思考强度档位；无字段/读取失败时保持默认
//（主题跟随系统；思考强度：教学组 disabled / 纯文本组 low）
Future<void> _restoreThemeMode() async {
  try {
    final config = await StorageService().loadConfig();
    final saved = config['themeMode'] as String?;
    if (saved != null) {
      themeModeNotifier.value = ThemeMode.values.firstWhere(
        (m) => m.name == saved,
        orElse: () => ThemeMode.system,
      );
    }
    final teaching = config['teachingThinkingEffort'] as String?;
    if (teaching != null && ThreeTutorService.isValidThinkingEffort(teaching)) {
      ThreeTutorService.teachingThinkingEffort = teaching;
    }
    final text = config['textThinkingEffort'] as String?;
    if (text != null && ThreeTutorService.isValidThinkingEffort(text)) {
      ThreeTutorService.textThinkingEffort = text;
    }
  } catch (_) {
    //读取失败不影响启动
  }
}

//Android 上申请「所有文件访问」权限：数据存放在公共 Documents/ThreeTutor
//Windows 等其他平台无需权限，直接跳过
Future<void> _ensureStoragePermission() async {
  if (!Platform.isAndroid) return;
  final status = await Permission.manageExternalStorage.status;
  if (status.isGranted) return;

  await Permission.manageExternalStorage.request();
  //request 会跳系统设置页，用户开启后返回 app；此处复查，仍拒绝则退出
  //（无此权限时档案读写全部会崩，与其带着坏状态运行不如直接退出）
  final granted = await Permission.manageExternalStorage.status;
  if (!granted.isGranted) {
    await SystemNavigator.pop(); //结束 activity，等同退出应用
    return; //退出成功则不再启动 UI；万一 pop 失败，黑屏比崩溃后坏数据更安全
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    //监听全局主题模式：设置页切换即重建整树（MaterialApp 换 themeMode）
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, mode, _) => MaterialApp(
        title: '三人师',
        debugShowCheckedModeBanner:
            false, //隐藏右上角 DEBUG 横幅（仅 debug 运行时显示，release 本来就没有）
        theme: buildLightTheme(),
        darkTheme: buildDarkTheme(),
        themeMode: mode, //light=明亮 / dark=深色 / system=跟随系统（Android 深色开关）
        home: const HomePage(),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  ///全局 tab 索引（静态可写）：任何页面都能切 tab——
  ///群聊页返回时统一切回聊天 tab（0），包括从通讯录/创建课程进入的对话页
  static final pageIndex = ValueNotifier<int>(0);

  @override
  createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final pages = [TabChat(), TabContact(), TabSetting()];

  @override
  Widget build(BuildContext context) {
    //body 与底栏都依赖 tab 索引，整树随 ValueNotifier 重建
    //IndexedStack 保活三个 tab：切走不销毁 State，回来时滚动位置/已加载数据原样保留
    return ValueListenableBuilder<int>(
      valueListenable: HomePage.pageIndex,
      builder: (_, pageIndex, _) => Scaffold(
        body: IndexedStack(index: pageIndex, children: pages),
        bottomNavigationBar: DecoratedBox(
          //顶部细分割线，贴合经典聊天应用底部栏样式（颜色随主题）
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: AppColors.of(context).divider, width: 0.5),
            ),
          ),
          child: NavigationBar(
            destinations: [
              NavigationDestination(icon: Icon(Icons.chat_bubble), label: '聊天'),
              NavigationDestination(icon: Icon(Icons.contacts), label: '通讯录'),
              NavigationDestination(
                icon: Icon(Icons.settings_applications),
                label: '设置',
              ),
            ],
            selectedIndex: pageIndex,
            onDestinationSelected: (tappedIndex) {
              HomePage.pageIndex.value = tappedIndex; //listener 触发 body 与底栏同步重建
            },
          ),
        ),
      ),
    );
  }
}
