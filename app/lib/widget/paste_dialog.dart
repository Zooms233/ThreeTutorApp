import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

//通用粘贴导入对话框：外部 AI 产物入库的统一入口（导师组、教学大纲共用）。
//主入口=粘贴剪贴板/手输全文；次入口=选 .txt/.md 回填到输入框（已有存档文件的用户）。
//选择器不可用不影响粘贴主路径（框内提示）。返回全文或 null（取消）。
Future<String?> showPasteImportDialog(
  BuildContext context, {
  required String title,
  required String hint,
}) {
  final textC = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          TextField(
            controller: textC,
            maxLines: 8,
            autofocus: true,
            decoration: InputDecoration(hintText: hint),
          ),
          TextButton.icon(
            onPressed: () async {
              try {
                final file = await openFile(
                  acceptedTypeGroups: const [
                    XTypeGroup(label: '文本', extensions: ['txt', 'md', 'text']),
                  ],
                );
                if (file == null) return; //用户取消选择
                textC.text = await file.readAsString();
              } catch (e) {
                //选择器不可用或读取失败：不影响粘贴主路径，框内提示
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('文件读取不可用：$e'),
                    duration: const Duration(seconds: 2),
                  ),
                );
              }
            },
            icon: const Icon(Icons.description_outlined, size: 16),
            label: const Text('从文件选择', style: TextStyle(fontSize: 13)),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, textC.text),
          child: const Text('导入'),
        ),
      ],
    ),
  );
}
