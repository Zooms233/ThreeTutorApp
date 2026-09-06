import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class StorageService {
  //数据根目录（按平台）：
  //Windows = E:\Documents\TutorChat —— 个人偏好位置，资源管理器直接可见、便于手动备份
  //Android = 公共 Documents/TutorChat —— 需「所有文件访问」权限（manifest 已声明，首次启动申请）
  //其他平台回退应用私有目录
  static const _windowsRoot = r'E:\Documents\TutorChat';
  static const _androidRoot = '/storage/emulated/0/Documents/TutorChat';

  //返回本应用的数据根目录（不存在则创建）
  Future<Directory> getRootDir() async {
    final Directory dir;
    if (Platform.isWindows) {
      dir = Directory(_windowsRoot);
    } else if (Platform.isAndroid) {
      dir = Directory(_androidRoot);
    } else {
      dir = await getApplicationSupportDirectory();
    }
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  //返回某世界的目录（世界路径=根目录/世界/世界名）
  Future<Directory> getWorldDir(String name) async {
    final root = await getRootDir();
    return Directory('${root.path}/世界/$name');
  }

  //扫描「世界/」目录，返回世界名单（目录不存在则先创建）
  Future<List<String>> listWorlds() async {
    final root = await getRootDir();
    final worldDir = Directory('${root.path}/世界');
    if (!worldDir.existsSync()) {
      await worldDir.create(recursive: true);
    }

    final names = <String>[];
    for (final entity in await worldDir.list().toList()) {
      //从完整路径中取出最后一段，即世界名：...\世界\教令院 → 教令院
      names.add(entity.path.split(Platform.pathSeparator).last);
    }
    return names;
  }

  //读取世界内全部导师名单：世界目录下 tutor_ 开头的 JSON 文件，按文件名排序（tutor_a → b → c）
  Future<List<Map<String, dynamic>>> loadWorldTutors(String worldName) async {
    final worldDir = await getWorldDir(worldName);
    if (!worldDir.existsSync()) return []; //目录不存在视为无导师

    final files = <File>[];
    for (final entity in worldDir.listSync()) {
      final fileName = entity.path.split(Platform.pathSeparator).last;
      if (entity is File && fileName.startsWith('tutor_') && fileName.endsWith('.json')) {
        files.add(entity);
      }
    }
    files.sort((a, b) => a.path.compareTo(b.path)); //同目录下按路径排序 = 按文件名排序

    final result = <Map<String, dynamic>>[];
    for (final file in files) {
      final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      result.add({
        'file': file.path.split(Platform.pathSeparator).last, //文件名，点击导师时据此读取档案
        'name': data['name'],
        'dir': worldDir.path, //世界目录路径（头像图片查找用）
      });
    }
    return result;
  }

  //读取世界内某位导师的完整档案（导师档案页用）
  Future<Map<String, dynamic>> loadTutorProfile(
    String worldName,
    String fileName,
  ) async {
    final worldDir = await getWorldDir(worldName);
    final text = await File('${worldDir.path}/$fileName').readAsString();
    return jsonDecode(text) as Map<String, dynamic>;
  }

  //读取世界内学习者的完整档案（学习者档案页用）
  Future<Map<String, dynamic>> loadLearnerProfile(String worldName) async {
    final worldDir = await getWorldDir(worldName);
    final text = await File('${worldDir.path}/LEARNER.json').readAsString();
    return jsonDecode(text) as Map<String, dynamic>;
  }

  //返回某课程的目录（课程路径=根目录/课程/课程名）
  Future<Directory> getCourseDir(String name) async {
    final root = await getRootDir();
    return Directory('${root.path}/课程/$name');
  }

  //扫描「课程/」目录，返回全部课程名单（目录不存在则返回空）
  Future<List<String>> listCourses() async {
    final root = await getRootDir();
    final courseDir = Directory('${root.path}/课程');
    if (!courseDir.existsSync()) return [];

    final names = <String>[];
    for (final entity in await courseDir.list().toList()) {
      if (entity is Directory) {
        //从完整路径取出最后一段，即课程名
        names.add(entity.path.split(Platform.pathSeparator).last);
      }
    }
    return names;
  }

  //查找某导师参与的课程：课程档案是世界档案的复制副本（文件名一致），
  //比对课程内同名文件的 name 字段与当前导师 name，双保险避免同名不同人
  Future<List<String>> findCoursesByTutor(
    String worldName,
    String fileName,
  ) async {
    final tutorProfile = await loadTutorProfile(worldName, fileName);
    final tutorName = tutorProfile['name'] as String?;

    final matched = <String>[];
    for (final course in await listCourses()) {
      final courseDir = await getCourseDir(course);
      final file = File('${courseDir.path}/$fileName');
      if (!file.existsSync()) continue;
      final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      if (data['name'] == tutorName) matched.add(course);
    }
    return matched;
  }

  //创建课程：建目录 + 从世界拷贝档案（模板快照）+ 写 STATE 初值
  //返回 null=成功；返回字符串=失败原因
  Future<String?> createCourse({
    required String worldName,
    required String courseName,
    required String learnerName,
    required String motivation,
    String extra = '',
    String? textbookPath,
  }) async {
    final courseDir = await getCourseDir(courseName);
    if (courseDir.existsSync()) return '同名课程已存在';
    await courseDir.create(recursive: true);
    await Directory('${courseDir.path}/CHAT').create(); //课次留档目录

    //拷贝导师档案（平铺）
    final worldDir = await getWorldDir(worldName);
    for (final entity in worldDir.listSync()) {
      final fileName = entity.path.split(Platform.pathSeparator).last;
      if (entity is File && fileName.startsWith('tutor_') && fileName.endsWith('.json')) {
        await entity.copy('${courseDir.path}/$fileName');
      }
    }

    //拷贝学习者档案并填入称呼/动力/其他（identity 与 story 随文件继承）
    final learner = jsonDecode(
      await File('${worldDir.path}/LEARNER.json').readAsString(),
    ) as Map<String, dynamic>;
    learner['name'] = learnerName;
    learner['motivation'] = motivation;
    learner['extra'] = extra;
    await File('${courseDir.path}/LEARNER.json').writeAsString(
      jsonEncode(learner),
    );

    //STATE 初值：从 tutor_a 开始轮换，课程名仅记目录名不写入
    final firstTutor = jsonDecode(
      await File('${courseDir.path}/tutor_a.json').readAsString(),
    ) as Map<String, dynamic>;
    await File('${courseDir.path}/STATE.json').writeAsString(
      jsonEncode({
        'position': '', //无教材模式为空
        'next_tutor': firstTutor['name'],
        'lessons': 0,
        'last_date': '', //尚未上课
      }),
    );

    //教材（可选）：复制进课程 TEXTBOOK/ 目录
    if (textbookPath != null) {
      final textbookDir = Directory('${courseDir.path}/TEXTBOOK');
      await textbookDir.create();
      final name = textbookPath.split(Platform.pathSeparator).last;
      await File(textbookPath).copy('${textbookDir.path}/$name');
    }
    return null;
  }

  //会话列表数据：每课程一行（群名/日期/预览）
  //预览 = 最新 CHAT 文件最后一条消息；无 CHAT 则预览"尚未开始上课"且垫底排序
  Future<List<Map<String, dynamic>>> listConversations() async {
    final result = <Map<String, dynamic>>[];

    for (final course in await listCourses()) {
      final chatDir = Directory('${(await getCourseDir(course)).path}/CHAT');

      //找最新课次文件：文件名含日期与课次，字典序即时间序，取最后一个
      final files = <File>[];
      if (chatDir.existsSync()) {
        for (final entity in chatDir.listSync()) {
          if (entity is File && entity.path.endsWith('.jsonl')) {
            files.add(entity);
          }
        }
        files.sort((a, b) => a.path.compareTo(b.path));
      }

      if (files.isEmpty) {
        result.add({
          'name': course,
          'date': '',
          'preview': '尚未开始上课',
        });
        continue;
      }

      //读取首行 meta 与最后一条 message（从后往前找，跳过其他行型）
      final lines = (await files.last
              .readAsString())
          .split('\n')
          .where((l) => l.trim().isNotEmpty)
          .toList();
      final meta = jsonDecode(lines.first) as Map<String, dynamic>;
      Map<String, dynamic>? lastMessage;
      for (var i = lines.length - 1; i >= 0; i--) {
        final row = jsonDecode(lines[i]) as Map<String, dynamic>;
        if (row['type'] == 'message') {
          lastMessage = row;
          break;
        }
      }

      //微信式预览：他人消息带发言人名，自己消息不带
      final isUser = lastMessage?['role'] == 'user';
      final sender = isUser ? '' : '${lastMessage?['name'] ?? ''}: ';
      final preview = stripMarkdown(lastMessage?['content'] as String? ?? '');
      result.add({
        'name': course,
        'date': meta['date'] as String? ?? '',
        'preview': '$sender$preview',
      });
    }

    //排序：有消息的按日期倒序，无消息垫底（按名称）
    result.sort((a, b) {
      final da = a['date'] as String;
      final db = b['date'] as String;
      if (da.isEmpty && db.isEmpty) return 0;
      if (da.isEmpty) return 1;
      if (db.isEmpty) return -1;
      return db.compareTo(da);
    });
    return result;
  }

  //剥离 Markdown/LaTeX 标记（会话预览用，不影响消息正文渲染）
  //公式 $...$ 替换为【公式】提示；斜体/加粗星号与标题#符号去除；换行压平
  static String stripMarkdown(String text) {
    return text
        .replaceAll(RegExp(r'\$\$?[^$]*\$\$?'), '【公式】')
        .replaceAll(RegExp(r'\*+'), '')
        .replaceAll(RegExp(r'^#+\s*', multiLine: true), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  //列出课程全部课次文件路径（旧 → 新排序）：只查文件名单，不读内容（按需加载用）
  Future<List<String>> listChatFiles(String courseName) async {
    final chatDir = Directory('${(await getCourseDir(courseName)).path}/CHAT');
    final files = <String>[];
    if (chatDir.existsSync()) {
      for (final entity in chatDir.listSync()) {
        if (entity is File && entity.path.endsWith('.jsonl')) {
          files.add(entity.path);
        }
      }
      files.sort(); //文件名含日期与课次，字典序即时间序
    }
    return files;
  }

  //读取单个课次文件的条目（兼容旧数据：message 缺 phase 默认按上课消息处理）
  Future<List<Map<String, dynamic>>> loadChatFile(String path) async {
    final entries = <Map<String, dynamic>>[];
    for (final line in await File(path).readAsLines()) {
      if (line.trim().isEmpty) continue;
      final row = jsonDecode(line) as Map<String, dynamic>;
      if (row['type'] == 'message' && row['phase'] == null) {
        row['phase'] = 'teaching';
      }
      entries.add(row);
    }
    return entries;
  }

  //当前会话目标：最新课次文件路径 + 本课授课导师；无课次时自动开第 1 课
  Future<Map<String, dynamic>> getCurrentLesson(String courseName) async {
    final files = await listChatFiles(courseName);
    if (files.isEmpty) return startNewLesson(courseName);

    //最新课次：读 meta 拿导师与课次号
    final lines = (await File(files.last).readAsLines())
        .where((l) => l.trim().isNotEmpty)
        .toList();
    final meta = jsonDecode(lines.first) as Map<String, dynamic>;
    return {
      'path': files.last,
      'tutor': meta['tutor'] as String? ?? '导师',
      'lesson': meta['lesson'],
    };
  }

  //开启新课次：建档写 meta（按钮「开始上课」与首课共用；文件已存在则幂等返回既有）
  //lesson = 累计课时 + 1，tutor = STATE.next_tutor（轮换推进在课后更新，此处只取）
  Future<Map<String, dynamic>> startNewLesson(String courseName) async {
    final courseDir = await getCourseDir(courseName);
    final state = await loadCourseState(courseName);
    final now = DateTime.now();
    final date =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final lesson = (state['lessons'] as int? ?? 0) + 1;
    final tutor = state['next_tutor'] as String? ?? '导师';
    final path = '${courseDir.path}/CHAT/$date-第$lesson课.jsonl';

    await Directory('${courseDir.path}/CHAT').create(recursive: true);
    if (!File(path).existsSync()) {
      await File(path).writeAsString(
        '${jsonEncode({
          'type': 'meta',
          'lesson': lesson,
          'date': date,
          'tutor': tutor,
          'status': 'ongoing',
        })}\n',
      );
    }
    return {'path': path, 'tutor': tutor, 'lesson': lesson};
  }

  //读取最新课次 meta（上课控制按钮状态判定用；无课次返回 null，只读不建）
  Future<Map<String, dynamic>?> loadLatestChatMeta(String courseName) async {
    final files = await listChatFiles(courseName);
    if (files.isEmpty) return null;
    final lines = (await File(files.last).readAsLines())
        .where((l) => l.trim().isNotEmpty)
        .toList();
    if (lines.isEmpty) return null;
    return jsonDecode(lines.first) as Map<String, dynamic>;
  }

  //追加一条消息到课次文件（先写后说；补齐末尾换行避免黏行）
  Future<void> appendChatMessage(
    String path,
    Map<String, dynamic> message,
  ) async {
    final file = File(path);
    final existing = await file.readAsString();
    final separator = existing.isEmpty || existing.endsWith('\n') ? '' : '\n';
    await file.writeAsString(
      '$existing$separator${jsonEncode(message)}\n',
    );
  }

  //课程内导师名 → 档案文件名映射（消息头像按名查找对应图片）
  Future<Map<String, String>> loadCourseTutorFiles(String courseName) async {
    final courseDir = await getCourseDir(courseName);
    final map = <String, String>{};
    for (final entity in courseDir.listSync()) {
      final fileName = entity.path.split(Platform.pathSeparator).last;
      if (entity is File &&
          fileName.startsWith('tutor_') &&
          fileName.endsWith('.json')) {
        final data = jsonDecode(await entity.readAsString()) as Map<String, dynamic>;
        map[data['name'] as String? ?? ''] = fileName;
      }
    }
    return map;
  }

  //读取课程学习者档案（LEARNER.json；文件不存在返回空 Map）
  Future<Map<String, dynamic>> loadCourseLearner(String courseName) async {
    final courseDir = await getCourseDir(courseName);
    final file = File('${courseDir.path}/LEARNER.json');
    if (!file.existsSync()) return {};
    return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  }

  //读取课程内导师与学习者的关系（tutor_*.json 的 name + relation，按文件名 tutor_a→b→c）
  Future<List<Map<String, dynamic>>> loadCourseTutorRelations(
    String courseName,
  ) async {
    final courseDir = await getCourseDir(courseName);
    final tutors = <Map<String, dynamic>>[];

    final files = <File>[];
    for (final entity in courseDir.listSync()) {
      final fileName = entity.path.split(Platform.pathSeparator).last;
      if (entity is File &&
          fileName.startsWith('tutor_') &&
          fileName.endsWith('.json')) {
        files.add(entity);
      }
    }
    files.sort((a, b) => a.path.compareTo(b.path));

    for (final file in files) {
      final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      tutors.add({'name': data['name'], 'relation': data['relation']});
    }
    return tutors;
  }

  //读取课程 STATE.json（单行 JSON；文件不存在返回空 Map）
  Future<Map<String, dynamic>> loadCourseState(String courseName) async {
    final courseDir = await getCourseDir(courseName);
    final file = File('${courseDir.path}/STATE.json');
    if (!file.existsSync()) return {};
    return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  }

  //读取课程 PROGRESS.jsonl（每行一个知识点；展示时新知识点在前）
  Future<List<Map<String, dynamic>>> loadCourseProgress(String courseName) async {
    final courseDir = await getCourseDir(courseName);
    final file = File('${courseDir.path}/PROGRESS.jsonl');
    if (!file.existsSync()) return [];

    final result = <Map<String, dynamic>>[];
    for (final line in await file.readAsLines()) {
      if (line.trim().isEmpty) continue;
      result.add(jsonDecode(line) as Map<String, dynamic>);
    }
    return result.reversed.toList();
  }

  //重命名课程（群名 = 课程名 = 课程目录名）
  //返回 null=成功；返回字符串=失败原因
  Future<String?> renameCourse(String oldName, String newName) async {
    if (newName == oldName) return null;
    if (RegExp(r'[\\/:*?"<>|]').hasMatch(newName)) {
      return '包含不能用于文件夹名的字符';
    }
    final newDir = await getCourseDir(newName);
    if (newDir.existsSync()) return '同名课程已存在';
    final oldDir = await getCourseDir(oldName);
    if (!oldDir.existsSync()) return '课程不存在';
    await oldDir.rename(newDir.path);
    return null;
  }

  //删除课程：删除整个课程目录（含 CHAT/STATE/PROGRESS/档案副本）
  Future<void> deleteCourse(String courseName) async {
    final courseDir = await getCourseDir(courseName);
    if (courseDir.existsSync()) {
      await courseDir.delete(recursive: true);
    }
  }

  /* 上课动态（热力图数据，暂缓）：扫描全部课程 CHAT 文件的 meta.date 按日聚合计数。
     文件模型改为「第N课.jsonl」后数据源需重新设计，恢复时取消注释。
  //上课动态：扫描全部课程 CHAT 文件的 meta.date，按日期聚合计数（热力图数据，现扫现算）
  Future<Map<String, int>> listLessonDates() async {
    final counts = <String, int>{};

    for (final course in await listCourses()) {
      final chatDir = Directory('${(await getCourseDir(course)).path}/CHAT');
      if (!chatDir.existsSync()) continue;
      for (final entity in chatDir.listSync()) {
        if (entity is! File || !entity.path.endsWith('.jsonl')) continue;
        final lines = (await entity.readAsLines())
            .where((l) => l.trim().isNotEmpty)
            .toList();
        if (lines.isEmpty) continue;
        final meta = jsonDecode(lines.first) as Map<String, dynamic>;
        final date = meta['date'] as String?;
        if (date != null && date.isNotEmpty) {
          counts[date] = (counts[date] ?? 0) + 1;
        }
      }
    }
    return counts;
  }
  */

  //读取 CONFIG.json（不存在返回空 Map）
  Future<Map<String, dynamic>> loadConfig() async {
    final root = await getRootDir();
    final file = File('${root.path}/CONFIG.json');
    if (!file.existsSync()) return {};
    return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  }

  //保存 CONFIG.json（整写，保留调用方传入的全部字段）
  Future<void> saveConfig(Map<String, dynamic> config) async {
    final root = await getRootDir();
    final file = File('${root.path}/CONFIG.json');
    await file.writeAsString(jsonEncode(config));
  }

  //导入单个内置世界：从 assets/worlds/<name>/ 复制档案到应用目录
  //返回 false 表示世界已存在，跳过导入
  Future<bool> importSingleWorld(String name) async {
    final worldDir = await getWorldDir(name);
    if (worldDir.existsSync()) {
      return false; //世界已存在，不导入
    }

    await worldDir.create(recursive: true); //File 写入不会自动建目录，必须预先创建
    const fileList = [
      //固定文件配置
      'LEARNER.json',
      'tutor_a.json',
      'tutor_b.json',
      'tutor_c.json',
    ];
    for (final file in fileList) {
      final contents = await rootBundle.loadString('assets/worlds/$name/$file');
      await File('${worldDir.path}/$file').writeAsString(contents);
    }
    return true;
  }

  //删除世界：删除整个世界目录（含其中全部角色文件）
  Future<void> deleteWorld(String name) async {
    final worldDir = await getWorldDir(name);
    if (await worldDir.exists()) {
      await worldDir.delete(recursive: true);
    }
  }

  //导入全部内置世界，返回汇总消息
  Future<String> importBuiltinWorlds() async {
    const builtinWorlds = ['教令院', '星光咖啡馆', '秀知院研究所']; //内置世界清单，对应assets/worlds/
    final imported = <String>[];
    final skipped = <String>[];

    for (final world in builtinWorlds) {
      final ok = await importSingleWorld(world);
      if (ok) {
        imported.add(world);
      } else {
        skipped.add(world);
      }
    }

    if (skipped.isEmpty) {
      return '已导入 ${imported.length} 个世界：${imported.join('、')}';
    }
    return '导入 ${imported.length} 个世界：${imported.join('、')}；跳过：${skipped.join('、')}';
  }
}
