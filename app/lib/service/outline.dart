import 'dart:io';

//大纲解析与校验：大纲即进度文件（doc/06）。
//结构约定：`#` 章 / `##` 节 / `- [ ]`|`- [x]` 原子知识点——二态、无编号、文本全文唯一。
//解析与校验一体：parse 成功即校验通过；任何不合规格行都是错误并带行号，
//导入时拒绝——绝不静默降级（doc/06 遗传学事故教训：失效被吞是事故根源之一）。

///原子知识点行：大纲状态的最小单位（一个可独立检验的知识点）
class OutlineItem {
  final String text; //要点文本（不含 checkbox 记号）
  final bool done; //true=[x] 已学，false=[ ] 待学
  final int lineNo; //文件行号（1 起始，报错与行级写入共用）

  const OutlineItem({
    required this.text,
    required this.done,
    required this.lineNo,
  });
}

///节：`## 节名`（一节约一次课容量）
class OutlineSection {
  final String title;
  final int lineNo;
  final List<OutlineItem> items;

  const OutlineSection({
    required this.title,
    required this.lineNo,
    required this.items,
  });
}

///章：`# 章名`
class OutlineChapter {
  final String title;
  final int lineNo;
  final List<OutlineSection> sections;

  const OutlineChapter({
    required this.title,
    required this.lineNo,
    required this.sections,
  });
}

///一份通过校验的大纲（parse errors 为空时的返回值）
class OutlineDoc {
  final List<OutlineChapter> chapters;

  const OutlineDoc({required this.chapters});

  ///第一个待学原子行（按文件行序：章→节→行；全 [x] 返回 null = 结课）
  OutlineItem? get firstPending {
    for (final ch in chapters) {
      for (final sec in ch.sections) {
        for (final it in sec.items) {
          if (!it.done) return it;
        }
      }
    }
    return null;
  }

  ///当前节：第一个含待学原子行的节（结课返回 null）
  OutlineSection? get currentSection {
    for (final ch in chapters) {
      for (final sec in ch.sections) {
        if (sec.items.any((it) => !it.done)) return sec;
      }
    }
    return null;
  }

  int get totalItems => chapters.fold(
    0,
    (n, ch) => n + ch.sections.fold(0, (m, s) => m + s.items.length),
  );

  int get doneItems => chapters.fold(
    0,
    (n, ch) =>
        n +
        ch.sections.fold(
          0,
          (m, s) => m + s.items.where((it) => it.done).length,
        ),
  );
}

///校验错误：行号 + 原因（lineNo 0 = 整体性错误）
class OutlineError {
  final int lineNo;
  final String message;

  const OutlineError(this.lineNo, this.message);
}

class Outline {
  static final _sectionRe = RegExp(r'^## (.+)$'); //## 节名（先于章判）
  static final _chapterRe = RegExp(r'^# (.+)$'); //# 章名
  static final _itemRe = RegExp(r'^- \[([ x])\] (.+)$'); //- [ ]|`- [x]` 要点
  //列表语法的行（-、*、+ 或数字编号开头）——出现即必须是合法知识点行，
  //防格式漂移静默丢行（如 `-[ ] x`、`* [ ] x` 被当普通文本吞掉）
  static final _listLikeRe = RegExp(r'^(?:[-*+] |\d+[.)] )');
  static final _deepHeadingRe = RegExp(r'^#{3,}'); //### 及更深：不支持

  //剥离成对代码围栏：粘贴导入的产物常带 ``` 围栏（整段复制网页对话输出），
  //若不剥，围栏行虽能作为普通文本放行（解析不报错），但会作为噪音写入大纲文件随注入进上下文。
  //剥后行号相对原文可能整体前移 1~2 行——仅在带围栏的非常规格式上发生，可接受
  static String _stripFence(String content) {
    final lines = content.split('\n');
    final first = lines.indexWhere((l) => l.trim().isNotEmpty);
    if (first < 0 || !lines[first].trimLeft().startsWith('```')) return content;
    final last = lines.lastIndexWhere((l) => l.trim().isNotEmpty);
    if (last <= first || lines[last].trim() != '```') return content; //闭栏须裸 ```
    return lines.sublist(first + 1, last).join('\n');
  }

  //解析 + 校验：返回 (doc, errors)。errors 为空 = 通过；非空则 doc 为 null。
  //先剥成对代码围栏（粘贴产物），校验错误行号相对剥后文本
  static (OutlineDoc?, List<OutlineError>) parse(String content) {
    content = _stripFence(content);
    final errors = <OutlineError>[];
    final chapters = <OutlineChapter>[];
    final sectionTitles = <String, int>{}; //节标题 → 首现行（全文唯一性）
    final itemTexts = <String, int>{}; //原子行文本 → 首现行（全文唯一性）

    //当前累积状态（lineNo 0 = 尚无对应块）
    var chapterTitle = '';
    var chapterLine = 0;
    var sections = <OutlineSection>[]; //当前章累积的节
    var sectionTitle = '';
    var sectionLine = 0;
    var items = <OutlineItem>[]; //当前节累积的知识点

    void closeSection() {
      if (sectionLine == 0) return;
      if (items.isEmpty) {
        errors.add(OutlineError(sectionLine, '节「$sectionTitle」内没有知识点行'));
      } else {
        sections.add(
          OutlineSection(
            title: sectionTitle,
            lineNo: sectionLine,
            items: List.of(items),
          ),
        );
      }
      sectionTitle = '';
      sectionLine = 0;
      items = [];
    }

    void closeChapter() {
      closeSection();
      if (chapterLine == 0) return;
      if (sections.isEmpty) {
        errors.add(
          OutlineError(chapterLine, '章「$chapterTitle」内没有小节（## 节名）'),
        );
      } else {
        chapters.add(
          OutlineChapter(
            title: chapterTitle,
            lineNo: chapterLine,
            sections: List.of(sections),
          ),
        );
      }
      chapterTitle = '';
      chapterLine = 0;
      sections = [];
    }

    final lines = content.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final lineNo = i + 1;
      final trimmed = lines[i].trim();
      if (trimmed.isEmpty) continue;

      //节标题
      final section = _sectionRe.firstMatch(trimmed);
      if (section != null) {
        if (chapterLine == 0) {
          errors.add(OutlineError(lineNo, '节标题必须出现在章标题（# …）之后'));
          continue;
        }
        closeSection();
        final title = section.group(1)!.trim();
        if (title.isEmpty) {
          errors.add(OutlineError(lineNo, '节标题不能为空'));
          continue;
        }
        if (sectionTitles.containsKey(title)) {
          errors.add(
            OutlineError(
              lineNo,
              '节标题「$title」与第 ${sectionTitles[title]} 行重复（全文唯一）',
            ),
          );
          continue;
        }
        sectionTitles[title] = lineNo;
        sectionTitle = title;
        sectionLine = lineNo;
        continue;
      }

      //章标题
      final chapter = _chapterRe.firstMatch(trimmed);
      if (chapter != null) {
        closeChapter();
        final title = chapter.group(1)!.trim();
        if (title.isEmpty) {
          errors.add(OutlineError(lineNo, '章标题不能为空'));
          continue;
        }
        chapterTitle = title;
        chapterLine = lineNo;
        continue;
      }

      //知识点行
      final item = _itemRe.firstMatch(trimmed);
      if (item != null) {
        if (sectionLine == 0) {
          errors.add(OutlineError(lineNo, '知识点行必须出现在节标题（## …）之后'));
          continue;
        }
        final text = item.group(2)!.trim();
        if (text.isEmpty) {
          errors.add(OutlineError(lineNo, '知识点文本不能为空'));
          continue;
        }
        if (itemTexts.containsKey(text)) {
          errors.add(
            OutlineError(
              lineNo,
              '知识点「$text」与第 ${itemTexts[text]} 行重复（全文唯一）',
            ),
          );
          continue;
        }
        itemTexts[text] = lineNo;
        items.add(
          OutlineItem(text: text, done: item.group(1) == 'x', lineNo: lineNo),
        );
        continue;
      }

      //其余报错类行：更深标题、格式漂移的列表行
      if (_deepHeadingRe.hasMatch(trimmed)) {
        errors.add(
          OutlineError(lineNo, '不支持的标题层级（仅 # 章与 ## 节两级）'),
        );
        continue;
      }
      if (_listLikeRe.hasMatch(trimmed)) {
        errors.add(
          OutlineError(lineNo, '列表行必须为知识点格式：- [ ] 要点（或 - [x] 要点）'),
        );
        continue;
      }
      //普通文本行放行（空行、`>` 来源注记等）
    }
    closeChapter();

    if (errors.isNotEmpty) return (null, errors);
    if (chapters.isEmpty) {
      return (null, [const OutlineError(0, '大纲至少需要一个章标题（# 章名）')]);
    }
    return (OutlineDoc(chapters: chapters), const []);
  }

  //读文件并校验：导入拦截与结算复用的便捷入口
  static Future<(OutlineDoc?, List<OutlineError>)> validateFile(
    String path,
  ) async {
    final file = File(path);
    if (!file.existsSync()) {
      return (null, [const OutlineError(0, '文件不存在')]);
    }
    return parse(await file.readAsString());
  }

  //错误摘要（SnackBar 等单行场景）：前 max 条「第N行 原因」+ 余数提示
  static String summarize(List<OutlineError> errors, {int max = 3}) {
    final head = errors
        .take(max)
        .map((e) => e.lineNo > 0 ? '第${e.lineNo}行 ${e.message}' : e.message)
        .join('；');
    return errors.length > max ? '$head（共 ${errors.length} 处）' : head;
  }
}
