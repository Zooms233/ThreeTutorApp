import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

//协议层：OpenAI 兼容 chat/completions 的 POST + SSE 流式解析 + 重试 + usage 解析。
//对业务无感知：输入 messages，输出全文 + usage；规则对齐 pi packages/ai（provider-retry 与 openai-completions）。

class LlmConfig {
  final String
  apiUrl; //如 https://api.deepseek.com/v1（尾斜杠归一化后拼接 /chat/completions）
  final String apiKey;
  final String model;

  const LlmConfig({
    required this.apiUrl,
    required this.apiKey,
    required this.model,
  });

  factory LlmConfig.fromMap(Map<String, dynamic> map) => LlmConfig(
    apiUrl: map['apiUrl'] as String? ?? '',
    apiKey: map['apiKey'] as String? ?? '',
    model: map['model'] as String? ?? '',
  );

  bool get isReady =>
      apiUrl.isNotEmpty && apiKey.isNotEmpty && model.isNotEmpty;

  String get completionsUrl {
    var url = apiUrl;
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1); //尾斜杠归一化
    }
    //用户误填完整端点时防重复拼接（设置页输入侧已实时裁剪，此处兜底手改 CONFIG 场景）
    if (url.endsWith('/chat/completions')) return url;
    return '$url/chat/completions';
  }
}

class LlmUsage {
  final int input; //prompt_tokens - cacheRead（缓存未命中部分）
  final int output; //completion_tokens（含思考 token）
  final int cacheRead;
  final int
  reasoning; //思考 token（混合推理模型 completion_tokens_details.reasoning_tokens）

  const LlmUsage({
    required this.input,
    required this.output,
    required this.cacheRead,
    this.reasoning = 0,
  });

  @override
  String toString() =>
      'input=$input output=$output reasoning=$reasoning cacheRead=$cacheRead';
}

class LlmResult {
  final String text;
  final LlmUsage? usage;

  const LlmResult({required this.text, this.usage});
}

class LlmException implements Exception {
  final String message;
  final int? statusCode; //null = 网络异常（无状态码）
  final Map<String, String>? headers;

  LlmException(this.message, [this.statusCode, this.headers]);

  bool get isNetworkError => statusCode == null;

  @override
  String toString() => message;
}

class LlmClient {
  //项目参数：连接与响应头 30s；流式期间无新数据 120s 判死（按断流处理）
  static const _headerTimeout = Duration(seconds: 30);
  static const _streamIdleTimeout = Duration(seconds: 120);
  //重试（pi provider-retry）：最多 3 次尝试；指数退避 0.5s*2^n 封顶 8s，乘 1-0~0.25 抖动；服务端延迟上限 60s
  static const _maxAttempts = 3;
  static const _maxRetryDelayMs = 60000;

  final http.Client _http;
  final Random _random = Random();

  //usage 累计（实例级）：进群聊页新建 service 即清零，对应一次会话的总账
  int _sumPrompt = 0;
  int _sumReasoning = 0; //思考 token 累计（混合推理模型的隐藏成本，单独可见）
  int _sumHit = 0;
  int _sumOutput = 0;

  LlmClient({http.Client? client}) : _http = client ?? http.Client();

  // —— 连通性检验（设置页）——

  ///最小请求（max_tokens=1）验证接口地址 / Key / 模型可用；不计入 usage 日志累计。
  ///返回 (是否成功, 描述)；描述供对话框内展示（成功含耗时，失败含状态码/可读原因）。
  Future<(bool, String)> ping(LlmConfig config) async {
    final request = http.Request('POST', Uri.parse(config.completionsUrl))
      ..headers['Authorization'] = 'Bearer ${config.apiKey}'
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode({
        'model': config.model,
        'messages': [
          {'role': 'user', 'content': 'ping'},
        ],
        'max_tokens': 1, //最小开销
        'stream': false,
      });

    final stopwatch = Stopwatch()..start();
    final http.StreamedResponse response;
    try {
      response = await _http.send(request).timeout(const Duration(seconds: 15));
    } catch (e) {
      return (false, '无法连接：$e');
    }
    stopwatch.stop();

    if (response.statusCode != 200) {
      final errorBody = await response.stream.bytesToString();
      final code = response.statusCode;
      //常见状态码给出可读原因，其余透传服务端错误摘要
      final hint = switch (code) {
        401 => 'Key 无效或未授权',
        404 => '接口地址或模型不存在',
        429 => '请求过于频繁或额度不足',
        _ => '',
      };
      final detail = hint.isNotEmpty
          ? hint
          : _extractErrorMessage(errorBody, code);
      return (false, 'HTTP $code：$detail');
    }
    return (
      true,
      '连接成功 · ${config.model} · ${stopwatch.elapsedMilliseconds}ms',
    );
  }

  ///发起一次对话。stream=false 时等待完整响应（课后更新用）；
  ///stream=true 时逐 chunk 拼接，onDelta 实时回调增量（UI「正在输入中」动画可用）。
  ///label：场景标签，stdout usage 调试行用（问答/上课/问候/总结/更新/群聊）。
  ///失败重试后仍耗尽 → 抛 LlmException，由场景层决定善后。
  Future<LlmResult> chat({
    required LlmConfig config,
    required List<Map<String, String>> messages,
    bool jsonMode = false, //true → response_format json_object（JSON 协议场景）
    bool stream = true,
    int? maxTokens, //生成上限（JSON 场景 4096：文档建议合理设置防截断，也防输出失控）
    String? thinkingEffort, //思考档位控制（官方：开关 thinking.type + 强度 reasoning_effort）；
    //null=模型默认（enabled + effort high）；'disabled'=关闭；'low'=低强度。
    //默认 high 下重任务（更新/群聊）思考数万 token，耗时与 output 计费双双爆炸；
    //但直接 disabled 会让重任务指令遵循崩掉（实测复读用户指令而非执行）——重任务用 'low'。
    void Function(String delta)? onDelta,
    String? label,
  }) async {
    final body = jsonEncode({
      'model': config.model,
      'stream': stream,
      if (stream) 'stream_options': {'include_usage': true}, //流式末尾附带 usage
      if (jsonMode) 'response_format': {'type': 'json_object'},
      ?maxTokens: maxTokens,
      if (thinkingEffort != null) ...{
        'thinking': {
          'type': thinkingEffort == 'disabled' ? 'disabled' : 'enabled',
        },
        if (thinkingEffort != 'disabled') 'reasoning_effort': thinkingEffort,
      },
      'messages': messages,
    });

    var attempt = 0;
    while (true) {
      final sw = Stopwatch()..start();
      try {
        final result = await _once(config, body, stream, onDelta);
        _logUsage(label, result.usage, sw.elapsedMilliseconds);
        return result;
      } on LlmException catch (e) {
        attempt++;
        if (attempt >= _maxAttempts || !_isRetryable(e)) rethrow;
        final delay = _retryDelayMs(e, attempt - 1);
        if (delay > 0) {
          await Future<void>.delayed(Duration(milliseconds: delay));
        }
      }
    }
  }

  //usage 调试输出（04：仅 stdout，不写入 CHAT）：单次一行 + 实例累计。
  //「缓存写入」= 未命中部分（本次实际计费输入，服务商将其写入缓存供后续请求命中）；
  //「命中」= prompt_tokens 里由缓存覆盖的部分（约 1/10 计价）。
  void _logUsage(String? label, LlmUsage? u, int ms) {
    final tag = label == null ? '' : ' $label';
    if (u == null) {
      debugPrint('[llm$tag] 服务商未返回 usage');
      return;
    }
    final prompt = u.input + u.cacheRead; //总输入 = 未命中 + 命中
    _sumPrompt += prompt;
    _sumHit += u.cacheRead;
    _sumOutput += u.output;
    _sumReasoning += u.reasoning;
    final rate = prompt == 0 ? 0.0 : u.cacheRead * 100 / prompt;
    final sumRate = _sumPrompt == 0 ? 0.0 : _sumHit * 100 / _sumPrompt;
    debugPrint(
      '[llm$tag] 入=$prompt（命中 ${u.cacheRead} + 写入 ${u.input}）出=${u.output}（思考 ${u.reasoning}）'
      '命中率=${rate.toStringAsFixed(1)}% ${ms}ms'
      ' ｜累计 入=$_sumPrompt 出=$_sumOutput 思考=$_sumReasoning 命中率=${sumRate.toStringAsFixed(1)}%',
    );
  }

  //单次请求：等待响应头（30s）→ 流式消费或整段读取
  Future<LlmResult> _once(
    LlmConfig config,
    String body,
    bool stream,
    void Function(String delta)? onDelta,
  ) async {
    final request = http.Request('POST', Uri.parse(config.completionsUrl))
      ..headers['Authorization'] = 'Bearer ${config.apiKey}'
      ..headers['Content-Type'] = 'application/json'
      ..body = body;

    final http.StreamedResponse response;
    try {
      response = await _http
          .send(request)
          .timeout(
            _headerTimeout,
            onTimeout: () => throw LlmException('连接超时（30s 无响应头）'),
          );
    } on LlmException {
      rethrow;
    } catch (e) {
      throw LlmException('网络异常：$e'); //无状态码 → 一律可重试
    }

    if (response.statusCode != 200) {
      final errorBody = await response.stream.bytesToString();
      throw LlmException(
        _extractErrorMessage(errorBody, response.statusCode),
        response.statusCode,
        response.headers,
      );
    }

    if (!stream) {
      final text = await response.stream.bytesToString();
      final Map<String, dynamic> json;
      try {
        json = jsonDecode(text) as Map<String, dynamic>;
      } catch (e) {
        //200 但 body 非法（空响应/网关错误页/截断）：裸 FormatException 会穿透上层
        //的 on LlmException 链导致静默失败（无 toast/无重载/按钮不变），统一转 LlmException
        final head = text.length > 200 ? text.substring(0, 200) : text;
        throw LlmException('响应解析失败（非 JSON）：$head');
      }
      if (json['error'] != null) {
        throw LlmException(
          _errorText(json['error']),
          response.statusCode,
          response.headers,
        );
      }
      var content = '';
      final choices = json['choices'] as List?;
      if (choices != null && choices.isNotEmpty) {
        final message = (choices.first as Map<String, dynamic>)['message'];
        if (message is Map<String, dynamic>) {
          content = message['content'] as String? ?? '';
        }
      }
      return LlmResult(text: content, usage: _parseUsage(json['usage']));
    }

    //流式：utf8 解码按行缓冲，data: 前缀剥离 → [DONE] 结束；断流（无 [DONE]/超时/解析失败）视为失败，交由重试
    final buffer = StringBuffer();
    final lineBuffer = StringBuffer(); //跨 chunk 的半行
    LlmUsage? usage;
    var sawDone = false;

    try {
      await for (final chunk in _idleGuard(response.stream)) {
        lineBuffer.write(utf8.decode(chunk, allowMalformed: true));
        final lines = lineBuffer.toString().split('\n');
        lineBuffer
          ..clear()
          ..write(lines.removeLast()); //末尾可能是半行，留待下一 chunk
        for (final line in lines) {
          final trimmed = line.trim();
          if (!trimmed.startsWith('data:')) continue;
          final data = trimmed.substring(5).trim();
          if (data == '[DONE]') {
            sawDone = true;
            break;
          }
          final chunkJson = jsonDecode(data) as Map<String, dynamic>;
          if (chunkJson['error'] != null) {
            throw LlmException(
              _errorText(chunkJson['error']),
              response.statusCode,
              response.headers,
            );
          }
          //usage 兼容：chunk.usage 优先，choice.usage 兜底（Moonshot 等服务商差异，对齐 pi）
          usage ??= _parseUsage(chunkJson['usage']);
          String? delta;
          final choices = chunkJson['choices'] as List?;
          if (usage == null && choices != null && choices.isNotEmpty) {
            usage = _parseUsage(
              (choices.first as Map<String, dynamic>)['usage'],
            );
          }
          if (choices != null && choices.isNotEmpty) {
            final deltaMap = (choices.first as Map<String, dynamic>)['delta'];
            if (deltaMap is Map<String, dynamic>) {
              delta = deltaMap['content'] as String?;
            }
          }
          if (delta != null && delta.isNotEmpty) {
            buffer.write(delta);
            onDelta?.call(delta);
          }
        }
        if (sawDone) break;
      }
    } catch (e) {
      throw LlmException('流式中断：$e', response.statusCode, response.headers);
    }

    if (!sawDone) {
      throw LlmException(
        '连接关闭但未收到 [DONE]（断流）',
        response.statusCode,
        response.headers,
      );
    }
    return LlmResult(text: buffer.toString(), usage: usage);
  }

  //流式空闲防护：每次收到数据重置计时；_streamIdleTimeout 内无新数据 → 注入错误并关流
  Stream<List<int>> _idleGuard(Stream<List<int>> source) {
    late final StreamController<List<int>> controller;
    Timer? timer;
    void arm() {
      timer?.cancel();
      timer = Timer(_streamIdleTimeout, () {
        controller.addError(LlmException('流式超时（120s 无新数据）'));
        controller.close();
      });
    }

    controller = StreamController<Uint8List>(
      onListen: () {
        arm();
        source.listen(
          (chunk) {
            arm();
            controller.add(chunk);
          },
          onError: controller.addError,
          onDone: () {
            timer?.cancel(); //流正常结束：取消空闲计时，避免向已关闭的流注入错误
            controller.close();
          },
          cancelOnError: true,
        );
      },
      onCancel: () => timer?.cancel(),
    );
    return controller.stream;
  }

  //重试判定（pi）：x-should-retry 头优先；408/409/429/5xx；无状态码（网络异常）一律可重试
  bool _isRetryable(LlmException e) {
    if (e.isNetworkError) return true;
    if (e.headers?['x-should-retry'] == 'true') return true;
    if (e.headers?['x-should-retry'] == 'false') return false;
    return e.statusCode == 408 ||
        e.statusCode == 409 ||
        e.statusCode == 429 ||
        e.statusCode! >= 500;
  }

  //退避：retry-after-ms / retry-after 头优先（超 60s 上限则放弃，重抛原错）；否则指数 0.5s*2^n 封顶 8s，乘 1-0~0.25 抖动
  int _retryDelayMs(LlmException e, int retryIndex) {
    final afterMs = e.headers?['retry-after-ms'];
    if (afterMs != null) {
      final value = double.tryParse(afterMs);
      if (value != null) {
        if (value > _maxRetryDelayMs) throw e;
        return value.round();
      }
    }
    final after = e.headers?['retry-after'];
    if (after != null) {
      final seconds = double.tryParse(after);
      if (seconds != null) {
        final delayMs = seconds * 1000;
        if (delayMs > _maxRetryDelayMs) throw e;
        return delayMs.round();
      }
    }
    final base = min(0.5 * pow(2, retryIndex), 8.0) * 1000;
    return (base * (1 - _random.nextDouble() * 0.25)).round();
  }

  //usage 兼容链（pi parseChunkUsage）：OpenAI prompt_tokens_details / DeepSeek 专用字段 / 顶层 cached_tokens（Kimi）
  LlmUsage? _parseUsage(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final promptTokens = raw['prompt_tokens'] as int? ?? 0;
    final details = raw['prompt_tokens_details'] as Map<String, dynamic>?;
    final cacheRead =
        details?['cached_tokens'] as int? ??
        raw['prompt_cache_hit_tokens'] as int? ??
        raw['cached_tokens'] as int? ??
        0;
    final output = raw['completion_tokens'] as int? ?? 0;
    final outDetails =
        raw['completion_tokens_details'] as Map<String, dynamic>?;
    return LlmUsage(
      input: max(0, promptTokens - cacheRead),
      output: output,
      cacheRead: cacheRead,
      reasoning: outDetails?['reasoning_tokens'] as int? ?? 0,
    );
  }

  //错误体解析：JSON 的 error.message 优先，退回原始文本片段
  String _extractErrorMessage(String body, int statusCode) {
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      if (json['error'] != null) return _errorText(json['error']);
      return 'HTTP $statusCode: ${body.length > 300 ? body.substring(0, 300) : body}';
    } catch (_) {
      return 'HTTP $statusCode: ${body.length > 300 ? body.substring(0, 300) : body}';
    }
  }

  String _errorText(Object? error) {
    if (error is Map<String, dynamic>) {
      return error['message'] as String? ?? '未知服务端错误';
    }
    return error?.toString() ?? '未知服务端错误';
  }
}
