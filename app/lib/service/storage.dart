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
