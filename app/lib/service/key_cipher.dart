import 'dart:convert';

//API Key 本地混淆：CONFIG.json 位于公共 Documents/ThreeTutor（任何 app 可读），
//防止 key 以明文形式被其他软件正则扫描窃取（sk- 开头等特征）。
//定性为混淆而非加密：不抵抗拿到文件后的定向逆向（xorshift 模式可被识别）。
//固定盐播种的确定性字节流，不依赖配置档 id；真需要加密强度时再上 Android Keystore。

const _prefix = 'enc1:'; //版本前缀：无前缀视为明文（兼容手工编辑 CONFIG 的用法）

//混淆：enc1: + Base64( XOR( utf8(plain), keystream ) )；空串原样返回
String obfuscateKey(String plain) {
  if (plain.isEmpty) return plain;
  final bytes = utf8.encode(plain);
  final ks = _keyStream(bytes.length);
  return _prefix + base64Encode([
    for (var i = 0; i < bytes.length; i++) bytes[i] ^ ks[i],
  ]);
}

//解混淆：剥离前缀 → Base64 解码 → 逆 XOR；无前缀按明文直接返回；
//密文损坏（手工改坏/截断）按未配置处理返回空串，交由上层「Key 未填」提示兜底
String deobfuscateKey(String stored) {
  if (!stored.startsWith(_prefix)) return stored;
  try {
    final data = base64Decode(stored.substring(_prefix.length));
    final ks = _keyStream(data.length);
    return utf8.decode([
      for (var i = 0; i < data.length; i++) data[i] ^ ks[i],
    ]);
  } catch (_) {
    return '';
  }
}

//确定性字节流：固定盐 FNV-1a 播种 + xorshift64 混合，每轮取高 32 位低字节。
//Dart VM int 为 64 位，移位/乘法自然环绕，无需掩码
List<int> _keyStream(int len) {
  var s = 0xcbf29ce484222325; //FNV-1a offset basis
  for (final b in utf8.encode('ThreeTutor.key.v1')) {
    s = (s ^ b) * 0x100000001b3;
  }
  return List<int>.generate(len, (_) {
    s ^= s >> 12;
    s ^= s << 25;
    s ^= s >> 27;
    return (s >> 32) & 0xFF;
  });
}
