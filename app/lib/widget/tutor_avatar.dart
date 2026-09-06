import 'dart:io';

import 'package:flutter/material.dart';

//首字占位头像：当前阶段全用首字（课程名/导师名第一个字）
//预留图片支持：传入 imageDir + fileName 时，目录中存在同名图片
//（tutor_a.json → tutor_a.png/jpg/jpeg/webp）则自动显示图片，否则回退首字
//头像画好后放进世界/课程目录即可无缝替换，无需改代码
class TutorAvatar extends StatelessWidget {
  const TutorAvatar({
    super.key,
    required this.name,
    this.size = 48,
    this.imageDir,
    this.fileName,
  });

  final String name; //首字来源（导师名或课程群名）
  final double size; //边长
  final String? imageDir; //图片查找目录（世界/课程目录），null = 纯首字
  final String? fileName; //导师档案文件名（如 tutor_a.json）

  //目录中查找同名图片文件
  File? _findImageFile() {
    if (imageDir == null || fileName == null) return null;
    final base = fileName!.replaceAll(RegExp(r'\.json$'), '');
    for (final ext in ['png', 'jpg', 'jpeg', 'webp']) {
      final file = File('$imageDir/$base.$ext');
      if (file.existsSync()) return file;
    }
    return null;
  }

  //首字底色：按名字 hash 从色板取色，多会话时有区分度
  Color _backgroundColor() {
    const palette = [
      Color(0xFF07C160), //微信绿
      Color(0xFF306CFF), //蓝（与应用图标同色）
      Color(0xFFFA9D3B), //橙
      Color(0xFF6467F0), //紫
      Color(0xFF10AEFF), //青
      Color(0xFFFA5151), //红
    ];
    var sum = 0;
    for (final rune in name.runes) {
      sum += rune;
    }
    return palette[sum % palette.length];
  }

  //名字首字（runes 取首字符，兼容中文与多字节字符）
  String get _firstChar =>
      name.isEmpty ? '?' : String.fromCharCode(name.runes.first);

  @override
  Widget build(BuildContext context) {
    final imageFile = _findImageFile();

    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.18), //微信式圆角方形
      child: SizedBox(
        width: size,
        height: size,
        child: imageFile != null
            ? Image.file(
                imageFile,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _buildPlaceholder(),
              )
            : _buildPlaceholder(),
      ),
    );
  }

  //首字占位：色块底 + 白色首字居中
  Widget _buildPlaceholder() {
    return Container(
      color: _backgroundColor(),
      alignment: Alignment.center,
      child: Text(
        _firstChar,
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.42,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
