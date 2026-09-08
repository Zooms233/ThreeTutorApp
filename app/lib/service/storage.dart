import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class StorageService {
  //数据根目录（按平台）：
  //Windows = E:\Documents\ThreeTutor —— 个人偏好位置，资源管理器直接可见、便于手动备份
  //Android = 公共 Documents/ThreeTutor —— 需「所有文件访问」权限（manifest 已声明，首次启动申请）
  //其他平台回退应用私有目录
  static const _windowsRoot = r'E:\Documents\ThreeTutor';
  static const _androidRoot = '/storage/emulated/0/Documents/ThreeTutor';

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
      if (entity is! Directory) continue; //只收子目录，混入的散文件不算世界
      //从完整路径中取出最后一段，即世界名：...\世界\杏坛 → 杏坛
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
      if (entity is File &&
          fileName.startsWith('tutor_') &&
          fileName.endsWith('.json')) {
        files.add(entity);
      }
    }
    files.sort((a, b) => a.path.compareTo(b.path)); //同目录下按路径排序 = 按文件名排序

    final result = <Map<String, dynamic>>[];
    for (final file in files) {
      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
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
      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
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
    List<String>? textbookPaths, //教学材料（可选，可多份，参考数据库，TEXTBOOK/）
    String? syllabusPath, //教学大纲（可选，教学范围，OUTLINE/）
  }) async {
    final courseDir = await getCourseDir(courseName);
    if (courseDir.existsSync()) return '同名课程已存在';

    try {
      await courseDir.create(recursive: true);
      await Directory('${courseDir.path}/CHAT').create(); //课次留档目录

      //拷贝导师档案（平铺）
      final worldDir = await getWorldDir(worldName);
      for (final entity in worldDir.listSync()) {
        final fileName = entity.path.split(Platform.pathSeparator).last;
        if (entity is File &&
            fileName.startsWith('tutor_') &&
            fileName.endsWith('.json')) {
          await entity.copy('${courseDir.path}/$fileName');
        }
      }

      //学习者档案：创建课程时直接生成（世界不再内置 LEARNER.json）
      await File('${courseDir.path}/LEARNER.json').writeAsString(
        jsonEncode({
          'name': learnerName,
          'motivation': motivation,
          'extra': extra,
        }),
      );

      //STATE 初值：从 tutor_a 开始轮换，课程名仅记目录名不写入
      final firstTutor =
          jsonDecode(
                await File('${courseDir.path}/tutor_a.json').readAsString(),
              )
              as Map<String, dynamic>;
      await File('${courseDir.path}/STATE.json').writeAsString(
        jsonEncode({
          'position': '', //无教材模式为空
          'next_tutor': firstTutor['name'],
          'lessons': 0,
          'last_date': '', //尚未上课
        }),
      );

      //教学材料（可选，可多份）：复制进课程 TEXTBOOK/ 目录（参考数据库，格式不限）
      for (final p in textbookPaths ?? const <String>[]) {
        await _copyIntoCourse(courseDir, 'TEXTBOOK', p);
      }
      //教学大纲（可选）：复制进课程 OUTLINE/ 目录（教学范围，短，全文注入）
      if (syllabusPath != null) {
        await _copyIntoCourse(courseDir, 'OUTLINE', syllabusPath);
      }
      return null;
    } catch (e) {
      //任一步失败：删掉半成品目录（拷贝/写档中断的残留），错误原因交调用方提示
      if (courseDir.existsSync()) {
        try {
          await courseDir.delete(recursive: true);
        } catch (_) {
          //清理失败不掩盖原始错误
        }
      }
      return '创建失败：$e';
    }
  }

  //建课时把外部文件复制进课程子目录（TEXTBOOK/OUTLINE，自动建目录）
  Future<void> _copyIntoCourse(
    Directory courseDir,
    String subDir,
    String sourcePath,
  ) async {
    final dir = Directory('${courseDir.path}/$subDir');
    await dir.create();
    final name = sourcePath.split(Platform.pathSeparator).last;
    await File(sourcePath).copy('${dir.path}/$name');
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
          'lastTime': '',
          'preview': '尚未开始上课',
        });
        continue;
      }

      //meta 取最新文件首行；最后一条 message 跨文件从后往前找——
      //群聊讨论写在上一课文件尾，最新消息可能在倒数第二个文件（四段文件组织）
      final meta =
          jsonDecode((await files.last.readAsLines()).first)
              as Map<String, dynamic>;
      Map<String, dynamic>? lastMessage;
      for (var i = files.length - 1; i >= 0 && lastMessage == null; i--) {
        final lines = (await files[i].readAsString())
            .split('\n')
            .where((l) => l.trim().isNotEmpty)
            .toList();
        for (var j = lines.length - 1; j >= 0; j--) {
          final row = jsonDecode(lines[j]) as Map<String, dynamic>;
          if (row['type'] == 'message') {
            lastMessage = row;
            break;
          }
        }
      }

      //微信式预览：他人消息带发言人名，自己消息不带
      final isUser = lastMessage?['role'] == 'user';
      final sender = isUser ? '' : '${lastMessage?['name'] ?? ''}: ';
      final preview = stripMarkdown(lastMessage?['content'] as String? ?? '');
      result.add({
        'name': course,
        'date': meta['date'] as String? ?? '',
        'lastTime': lastMessage?['time'] as String? ?? '',
        'preview': '$sender$preview',
      });
    }

    //排序：按最后活动倒序（最后一条消息 time；无消息用 meta.date 兑底；无日期垫底）
    String sortKey(Map<String, dynamic> c) {
      final t = c['lastTime'] as String? ?? '';
      if (t.isNotEmpty) return t;
      return c['date'] as String? ?? '';
    }

    result.sort((a, b) {
      final ka = sortKey(a);
      final kb = sortKey(b);
      if (ka.isEmpty && kb.isEmpty) return 0;
      if (ka.isEmpty) return 1;
      if (kb.isEmpty) return -1;
      return kb.compareTo(ka);
    });
    return result;
  }

  //剥离 Markdown/LaTeX 标记（会话预览用，不影响消息正文渲染）
  //公式 $...$ 替换为【公式】提示；斜体/加粗星号与标题#符号去除；换行压平
  static String stripMarkdown(String text) {
    return text
        .replaceAll(RegExp(r'\$\$?[^$]*\$\$?'), '【公式】')
        .replaceAll(RegExp(r'\*+'), '')
        .replaceAll('_', '') //斜体旁白下划线一并去除（与星号同待遇）
        .replaceAll(RegExp(r'^#+\s*', multiLine: true), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  //列出课程全部课次文件路径（旧 → 新）：按文件名内课次号数值排序（04：按 lesson 数值）
  Future<List<String>> listChatFiles(String courseName) async {
    final chatDir = Directory('${(await getCourseDir(courseName)).path}/CHAT');
    final files = <String>[];
    if (chatDir.existsSync()) {
      for (final entity in chatDir.listSync()) {
        if (entity is File && entity.path.endsWith('.jsonl')) {
          files.add(entity.path);
        }
      }
      int lessonNo(String path) {
        final m = RegExp(
          r'(\d+)课',
        ).firstMatch(path.split(Platform.pathSeparator).last);
        return m == null ? 0 : int.parse(m.group(1)!);
      }

      files.sort((a, b) => lessonNo(a).compareTo(lessonNo(b)));
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

  //课次文件路径：第N课.jsonl（文件名不带日期，跨度可跨多天；排序按 lesson 数值）
  Future<String> lessonPath(String courseName, int lesson) async =>
      '${(await getCourseDir(courseName)).path}/CHAT/第$lesson课.jsonl';

  //建课次文件（幂等）：meta 预填 lesson/tutor/date=今日/status=idle（04：交流期立即就位）
  Future<String> createLessonFile(
    String courseName,
    int lesson,
    String tutor,
  ) async {
    final path = await lessonPath(courseName, lesson);
    await Directory(
      '${(await getCourseDir(courseName)).path}/CHAT',
    ).create(recursive: true);
    if (!File(path).existsSync()) {
      final now = DateTime.now();
      final date =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      await File(path).writeAsString(
        '${jsonEncode({'type': 'meta', 'lesson': lesson, 'date': date, 'tutor': tutor, 'status': 'idle'})}\n',
      );
    }
    return path;
  }

  //meta 整行改写：合并 patch 后重写首行（status 推进 idle→ongoing→ended、date 改写实际完成日）
  Future<void> patchChatMeta(String path, Map<String, dynamic> patch) async {
    final file = File(path);
    final lines = (await file.readAsLines())
        .where((l) => l.trim().isNotEmpty)
        .toList();
    final meta = {...jsonDecode(lines.first) as Map<String, dynamic>, ...patch};
    lines[0] = jsonEncode(meta);
    await file.writeAsString("${lines.join('\n')}\n");
  }

  //当前会话目标：最新课次文件路径 + 本课授课导师；无课次时建第 1 课（idle 预填，04 语义）
  Future<Map<String, dynamic>> getCurrentLesson(String courseName) async {
    var files = await listChatFiles(courseName);
    if (files.isEmpty) {
      final state = await loadCourseState(courseName);
      await createLessonFile(
        courseName,
        1,
        state['next_tutor'] as String? ?? '导师',
      );
      files = await listChatFiles(courseName);
    }
    final path = files.last;
    final meta =
        jsonDecode((await File(path).readAsLines()).first)
            as Map<String, dynamic>;
    return {
      'path': path,
      'tutor': meta['tutor'] as String? ?? '导师',
      'lesson': meta['lesson'],
    };
  }

  //开启新课次：建档写 meta（status=idle 预填；文件已存在则幂等返回既有）
  //lesson = 累计课时 + 1，tutor = STATE.next_tutor（轮换推进在课后更新，此处只取）
  Future<Map<String, dynamic>> startNewLesson(String courseName) async {
    final state = await loadCourseState(courseName);
    final lesson = (state['lessons'] as int? ?? 0) + 1;
    final tutor = state['next_tutor'] as String? ?? '导师';
    final path = await createLessonFile(courseName, lesson, tutor);
    return {'path': path, 'tutor': tutor, 'lesson': lesson};
  }

  //读取最新课次 meta（上课控制按钮状态判定用；无课次返回 null，只读不建）
  Future<Map<String, dynamic>?> loadLatestChatMeta(String courseName) async {
    final files = await listChatFiles(courseName);
    if (files.isEmpty) return null;
    final lines = (await File(
      files.last,
    ).readAsLines()).where((l) => l.trim().isNotEmpty).toList();
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
    await file.writeAsString('$existing$separator${jsonEncode(message)}\n');
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
        final data =
            jsonDecode(await entity.readAsString()) as Map<String, dynamic>;
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

  //更新学习者档案的三个可编辑字段（关系页编辑入口）：
  //LEARNER.json 只含 name/motivation/extra 三个字段，全量覆盖即可；
  //prompt 每次请求现读本文件，保存后下一句话即生效
  Future<void> saveLearnerFields(
    String courseName, {
    required String name,
    required String motivation,
    required String extra,
  }) async {
    final courseDir = await getCourseDir(courseName);
    final file = File('${courseDir.path}/LEARNER.json');
    final learner = file.existsSync()
        ? jsonDecode(await file.readAsString()) as Map<String, dynamic>
        : <String, dynamic>{};
    learner['name'] = name;
    learner['motivation'] = motivation;
    learner['extra'] = extra;
    await file.writeAsString(jsonEncode(learner));
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
      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
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

  //STATE 单行重写（课后更新第 1 步：position/next_tutor/lessons/last_date）
  Future<void> saveCourseState(
    String courseName,
    Map<String, dynamic> state,
  ) async {
    final courseDir = await getCourseDir(courseName);
    await File('${courseDir.path}/STATE.json').writeAsString(jsonEncode(state));
  }

  //读取课程 PROGRESS.jsonl（每行一个知识点；展示时新知识点在前）
  Future<List<Map<String, dynamic>>> loadCourseProgress(
    String courseName,
  ) async {
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

  //列出课程教学材料：{outline: [文件名], textbook: [文件名]}（各按文件名排序）
  Future<Map<String, List<String>>> listCourseMaterials(
    String courseName,
  ) async {
    final courseDir = await getCourseDir(courseName);
    return {
      'outline': await _listSubFiles(courseDir, 'OUTLINE'),
      'textbook': await _listSubFiles(courseDir, 'TEXTBOOK'),
    };
  }

  Future<List<String>> _listSubFiles(Directory courseDir, String sub) async {
    final dir = Directory('${courseDir.path}/$sub');
    if (!dir.existsSync()) return [];
    final names = <String>[];
    for (final e in dir.listSync()) {
      if (e is File) {
        names.add(e.path.split(Platform.pathSeparator).last);
      }
    }
    names.sort();
    return names;
  }

  //添加教学材料/大纲：复制进课程子目录；大纲仅一份（先清旧文件再复制，即「更换」）
  //返回 null=成功；返回字符串=失败原因
  Future<String?> addCourseMaterial(
    String courseName,
    String sub, //'OUTLINE' | 'TEXTBOOK'
    String sourcePath,
  ) async {
    try {
      final courseDir = await getCourseDir(courseName);
      final dir = Directory('${courseDir.path}/$sub');
      await dir.create(recursive: true);
      final name = sourcePath.split(Platform.pathSeparator).last;
      if (sub == 'OUTLINE') {
        //仅一份：清掉旧大纲（更换语义）
        for (final e in dir.listSync()) {
          if (e is File) await e.delete();
        }
      }
      await File(sourcePath).copy('${dir.path}/$name');
      return null;
    } catch (e) {
      return '导入失败：$e';
    }
  }

  //删除课程内教学材料/大纲文件
  Future<void> deleteCourseMaterial(
    String courseName,
    String sub,
    String fileName,
  ) async {
    final courseDir = await getCourseDir(courseName);
    final file = File('${courseDir.path}/$sub/$fileName');
    if (file.existsSync()) await file.delete();
  }

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

  // —— token 用量账本（USAGE.jsonl，与 CONFIG 同级；对话档案不掺账目数据）——

  //追加一行用量记录：{time, course, lesson, scene, input, output, cacheRead}
  //input = 缓存未命中输入（计费且写入缓存），cacheRead = 缓存命中输入（约 1/10 计价）
  Future<void> appendUsage({
    required String course,
    String? lesson, //课次留档文件名；无课次上下文的调用为 null
    required String scene,
    required int input,
    required int output,
    required int cacheRead,
    int reasoning = 0, //思考 token（混合推理模型；thinking 关闭时为 0）
  }) async {
    final root = await getRootDir();
    final file = File('${root.path}/USAGE.jsonl');
    final line = jsonEncode({
      'time': DateTime.now().toIso8601String(),
      'course': course,
      'lesson': lesson,
      'scene': scene,
      'input': input,
      'output': output,
      'cacheRead': cacheRead,
      'reasoning': reasoning,
    });
    await file.writeAsString('$line\n', mode: FileMode.append);
  }

  //读取全部用量记录（坏行跳过——账本允许手工编辑，容错优先）；页面现读现算不缓存
  Future<List<Map<String, dynamic>>> readUsageLog() async {
    final root = await getRootDir();
    final file = File('${root.path}/USAGE.jsonl');
    if (!file.existsSync()) return [];
    final rows = <Map<String, dynamic>>[];
    for (final line in await file.readAsLines()) {
      if (line.trim().isEmpty) continue;
      try {
        rows.add(jsonDecode(line) as Map<String, dynamic>);
      } catch (_) {
        //坏行跳过
      }
    }
    return rows;
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
    const builtinWorlds = ['杏坛']; //内置世界清单，对应assets/worlds/
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
