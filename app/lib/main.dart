import 'package:flutter/material.dart';
import 'package:tutor_chat/page/tab_chat.dart';
import 'package:tutor_chat/page/tab_contact.dart';
import 'package:tutor_chat/page/tab_setting.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TutorChat',
      theme: ThemeData(colorScheme: .fromSeed(seedColor: Colors.purple)),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int pageIndex = 0;
  final pages = [TabChat(), TabContact(), TabSetting()];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: pages[pageIndex],
      bottomNavigationBar: NavigationBar(
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
          //用户点击时要做的事
          setState(() {
            pageIndex = tappedIndex;
          });
        },
      ),
    );
  }
}
