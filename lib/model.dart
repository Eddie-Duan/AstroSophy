import 'dart:convert';
import 'dart:io' show HttpException;

import 'package:http/http.dart' as http;

/// 与兼容 OpenAI 接口的模型服务对话。
///
/// 双模型路由是刻意的：日常解读用便宜快的轻量模型，只有在结果「较弱」
/// 或者已经解算出天区、问题需要真正推理时才交给强模型；强模型不可用时
/// 再退回轻量模型，避免用户配置不全就直接失败。
class ModelService {
  static Future<String> explain({
    required String baseUrl,
    required String lightKey,
    required String lightModel,
    required String strongKey,
    required String strongModel,
    required Map<String, Object?> report,
    required String question,
  }) async {
    final routeStrong = report['quality'] == '较弱' || report['solved'] == true;
    final models = <(String, String)>[
      if (routeStrong) (strongKey, strongModel) else (lightKey, lightModel),
      if (routeStrong && lightKey.isNotEmpty)
        (lightKey, lightModel)
      else if (!routeStrong && strongKey.isNotEmpty)
        (strongKey, strongModel),
    ];
    final client = http.Client();
    final errors = <String>[];
    try {
      for (final (key, model) in models) {
        if (key.trim().isEmpty || model.trim().isEmpty) continue;
        try {
          final uri = Uri.parse('${baseUrl.trim().replaceFirst(RegExp(r'/+$'), '')}/chat/completions');
          final response = await client
              .post(
                uri,
                headers: {
                  'Authorization': 'Bearer ${key.trim()}',
                  'Content-Type': 'application/json',
                },
                body: jsonEncode({
                  'model': model.trim(),
                  'temperature': 0.3,
                  'messages': [
                    {
                      'role': 'system',
                      'content':
                          '你是面向爱好者的天文图像助手。只依据数据回答，明确区分目录确认、估算和未知；'
                              '不得把视觉背景说成 SQM/Bortle，也不得把仪器星等说成校准视星等。'
                              '简洁使用中文。',
                    },
                    {
                      'role': 'user',
                      'content':
                          '问题：${question.trim().isEmpty ? '请概括照片能确认的天文信息和可靠性。' : question.trim()}\n'
                              '图像分析 JSON：${jsonEncode(report)}',
                    },
                  ],
                }),
              )
              .timeout(const Duration(seconds: 45));
          if (response.statusCode < 200 || response.statusCode >= 300) {
            throw HttpException('模型 API 返回 HTTP ${response.statusCode}。');
          }
          final decoded = jsonDecode(response.body) as Map<String, dynamic>;
          final content = decoded['choices']?[0]?['message']?['content'];
          if (content is! String || content.trim().isEmpty) {
            throw const FormatException('模型返回内容为空。');
          }
          return content.trim();
        } catch (error) {
          errors.add('$model：$error');
        }
      }
      throw StateError(errors.isEmpty ? '未配置可用模型。' : errors.join('\n'));
    } finally {
      client.close();
    }
  }
}
