import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:tutor_chat/page/tab_chat.dart';
import 'package:tutor_chat/page/tab_contact.dart';
import 'package:tutor_chat/page/tab_setting.dart';

Future<void> main() async {
  //在 await 之前初始化绑定（Android 权限申请用到了平台通道）
  WidgetsFlutterBinding.ensureInitialized();
  await _ensureStoragePermission();
  runApp(const MyApp());
}

//Android 上申请「所有文件访问」权限：数据存放在公共 Documents/TutorChat
//Windows 等其他平台无需权限，直接跳过
Future<void> _ensureStoragePermission() async {
  if (!Platform.isAndroid) return;
  final status = await Permission.manageExternalStorage.status;
  if (!status.isGranted) {
    await Permission.manageExternalStorage.request();
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TutorChat',
      debugShowCheckedModeBanner:
          false, //隐藏右上角 DEBUG 横幅（仅 debug 运行时显示，release 本来就没有）
      theme: ThemeData(
        //fontFamily：思源黑体（内置 assets/fonts，Regular + Bold）；LaTeX 公式同步该字号与字距
        fontFamily: 'SourceHanSansCN',
        //微信绿作为种子色：全局强调色（按钮、水波纹、选中态）
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF07C160)),
        //微信浅色模式基础底色：页面与顶栏同为浅灰，列表内容用白色行浮起
        scaffoldBackgroundColor: const Color(0xFFEDEDED),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFEDEDED),
          scrolledUnderElevation: 0, //列表滚动时顶栏不因 surfaceTint 变色
        ),
        //全局分割线：微信细线风格
        dividerTheme: const DividerThemeData(
          color: Color(0xFFE5E5E5),
          thickness: 0.5,
        ),
        //底部导航栏：微信白底 + 选中绿 / 未选中灰
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: Colors.white,
          indicatorColor: const Color(0x1A07C160), //微信绿 10% 透明度的选中胶囊
          iconTheme: WidgetStateProperty.resolveWith((states) {
            return states.contains(WidgetState.selected)
                ? const IconThemeData(color: Color(0xFF07C160))
                : const IconThemeData(color: Color(0xFF999999));
          }),
          labelTextStyle: WidgetStateProperty.resolveWith((states) {
            return states.contains(WidgetState.selected)
                ? const TextStyle(fontSize: 12, color: Color(0xFF07C160))
                : const TextStyle(fontSize: 12, color: Color(0xFF999999));
          }),
        ),
      ),
      home: const HomePage(),
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
    return ValueListenableBuilder<int>(
      valueListenable: HomePage.pageIndex,
      builder: (_, pageIndex, _) => Scaffold(
        body: pages[pageIndex],
        bottomNavigationBar: DecoratedBox(
          //顶部细分割线，贴合微信底部栏样式
          decoration: const BoxDecoration(
            border: Border(
              top: BorderSide(color: Color(0xFFE5E5E5), width: 0.5),
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
