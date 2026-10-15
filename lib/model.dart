import 'dart:convert';
import 'dart:io' show HttpException;

import 'package:http/http.dart' as http;

typedef AgentToolExecutor = Future<Object?> Function(
  String name,
  Map<String, Object?> arguments,
);

typedef AgentToolListener = void Function(String name);

/// 挑主体时给模型看的一条候选。只有测量结果，没有照片。
class DeepSkyCandidate {
  const DeepSkyCandidate({
    required this.name,
    required this.category,
    this.angularSizeArcmin,
    this.fieldFraction,
    this.magnitude,
    this.nickname,
  });

  /// 目录编号（`M 45`、`IC 353`）。模型必须逐字照抄这一个。
  final String name;

  /// 中文类型（「疏散星团」）。
  final String category;

  final double? angularSizeArcmin;

  /// 长轴占像场对角线的比例。
  final double? fieldFraction;

  final double? magnitude;

  /// 本机手写的常用名；没有就是 null。给模型看是因为它是个有用的提示——但
  /// 也只是提示：真正做判断的是模型，本机那张表覆盖不到 IC 353 这种。
  final String? nickname;

  Map<String, Object?> toJson() => {
        'name': name,
        'type': category,
        if (angularSizeArcmin != null) 'angular_size_arcmin': angularSizeArcmin,
        if (fieldFraction != null)
          'fraction_of_field_of_view':
              double.parse(fieldFraction!.toStringAsFixed(3)),
        if (magnitude != null) 'magnitude': magnitude,
        if (nickname != null) 'common_chinese_name': nickname,
      };
}

/// 与兼容 OpenAI 接口的模型服务对话。
///
/// 双模型路由是刻意的：日常解读用便宜快的轻量模型，只有在结果「较弱」
/// 或者已经解算出天区、问题需要真正推理时才交给强模型；强模型不可用时
/// 再退回轻量模型，避免用户配置不全就直接失败。
class ModelService {
  static const _tools = <Map<String, Object?>>[
    {
      'type': 'function',
      'function': {
        'name': 'get_current_report',
        'description': '读取当前照片的本机分析与天区解算摘要。',
        'parameters': {
          'type': 'object',
          'properties': <String, Object?>{},
          'additionalProperties': false,
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'find_catalog_object',
        'description': '按名称搜索当前照片视场内已识别的恒星或深空天体。',
        'parameters': {
          'type': 'object',
          'properties': {
            'query': {
              'type': 'string',
              'description': '要查找的天体名称，例如天狼星或 M31。',
            },
          },
          'required': ['query'],
          'additionalProperties': false,
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'list_observations',
        'description': '列出本机已保存观测的摘要，不读取或返回照片。',
        'parameters': {
          'type': 'object',
          'properties': {
            'limit': {
              'type': 'integer',
              'minimum': 1,
              'maximum': 20,
              'description': '最多返回多少条观测，范围为 1 到 20。',
            },
          },
          'required': ['limit'],
          'additionalProperties': false,
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'get_observation',
        'description':
            '读取本机某一条观测记录的详细内容：保存时的解读、解算坐标与比例尺、'
                '拍摄时刻。回答「我那张土星解出来是什么」这类问题时用它，'
                '而不是让用户自己去翻记录。不返回照片。',
        'parameters': {
          'type': 'object',
          'properties': {
            'observation_id': {
              'type': 'string',
              'description': '观测记录的 id，先用 list_observations 拿到。',
            },
          },
          'required': ['observation_id'],
          'additionalProperties': false,
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'open_screen',
        'description':
            '在应用里打开一个页面。纯界面动作，没有副作用，不需要用户确认。',
        'parameters': {
          'type': 'object',
          'properties': {
            'screen': {
              'type': 'string',
              'enum': ['history', 'settings'],
              'description': 'history＝观星记录，settings＝API 设置。',
            },
          },
          'required': ['screen'],
          'additionalProperties': false,
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'save_current_observation',
        'description': '请求保存当前观测；应用会先向用户确认。',
        'parameters': {
          'type': 'object',
          'properties': {
            'name': {'type': 'string', 'description': '观测记录名称。'},
          },
          'required': ['name'],
          'additionalProperties': false,
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'rename_observation',
        'description': '请求重命名本机观测记录；应用会先向用户确认。',
        'parameters': {
          'type': 'object',
          'properties': {
            'observation_id': {'type': 'string'},
            'new_name': {'type': 'string'},
          },
          'required': ['observation_id', 'new_name'],
          'additionalProperties': false,
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'delete_observation',
        'description': '请求删除本机观测记录及其预览图；应用会先向用户确认。',
        'parameters': {
          'type': 'object',
          'properties': {
            'observation_id': {'type': 'string'},
          },
          'required': ['observation_id'],
          'additionalProperties': false,
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'request_online_solve',
        'description': '请求将当前照片预览上传到 Astrometry.net 解算；应用会先向用户确认。',
        'parameters': {
          'type': 'object',
          'properties': <String, Object?>{},
          'additionalProperties': false,
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'propose_non_sky_regions',
        'description':
            '请求模型检查当前照片中的水印、文字或界面区域并建议遮罩。'
                '这一步会把预览图发到用户配置的模型服务，'
                '所以那个模型必须支持图像输入；应用会先向用户确认。',
        'parameters': {
          'type': 'object',
          'properties': <String, Object?>{},
          'additionalProperties': false,
        },
      },
    },
  ];

  /// 带固定工具集的有限轮对话。所有工具执行都由应用处理，模型不能发起
  /// 任意网络请求、读文件或执行代码。
  ///
  /// [assistantName] 非空时助手会自称这个名字（应用里叫 Nox），
  /// [appBrief] 是它对自己这个应用的了解——「熟悉常用操作」靠的就是这一段，
  /// 而不是靠它去猜。为空时保持原来那句通用人设，一字不差。
  ///
  /// [history] 是之前几轮问答，顺序为旧到新，用来让助手记住对话。只放
  /// `role` 和 `content`：把工具调用也回放进去会让上下文迅速膨胀，而这些
  /// 细节本来就已经体现在它上一轮说过的话里了。
  static Future<String> chatWithTools({
    required String baseUrl,
    required String lightKey,
    required String lightModel,
    required String strongKey,
    required String strongModel,
    required Map<String, Object?> report,
    required String question,
    required AgentToolExecutor executeTool,
    AgentToolListener? onToolCall,
    String? assistantName,
    String? appBrief,
    String contextLabel = '当前图像分析摘要',
    List<Map<String, String>> history = const [],
    http.Client? httpClient,
  }) async {
    const maxToolCalls = 5;
    final routeStrong = report['quality'] == '较弱' || report['solved'] == true;
    final models = <(String, String)>[
      if (routeStrong) (strongKey, strongModel) else (lightKey, lightModel),
      if (routeStrong && lightKey.isNotEmpty)
        (lightKey, lightModel)
      else if (!routeStrong && strongKey.isNotEmpty)
        (strongKey, strongModel),
    ];
    final persona = assistantName == null
        ? '你是面向爱好者的天文图像助手。'
        : '你是「$assistantName」，这个应用里的助手。${appBrief ?? ''}';
    final client = httpClient ?? http.Client();
    final errors = <String>[];
    var anyToolExecuted = false;
    try {
      for (final (key, model) in models) {
        if (key.trim().isEmpty || model.trim().isEmpty) continue;
        try {
          final messages = <Map<String, Object?>>[
            {
              'role': 'system',
              'content': '$persona'
                  '只依据本机测量和工具结果回答，'
                      '明确区分目录确认、估算和未知；不得把视觉背景说成 SQM/Bortle，'
                      '也不得把仪器星等说成校准视星等。除只读查询外，保存、改名、删除、'
                      '联网解算和发送图片都属于有副作用的操作；只有用户明确要求时才可申请，'
                      '应用仍会在执行前单独确认。简洁使用中文，不要为了调用工具而调用工具。',
            },
            for (final turn in history)
              if (turn['role'] == 'user' || turn['role'] == 'assistant')
                {'role': turn['role'], 'content': turn['content'] ?? ''},
            {
              'role': 'user',
              'content':
                  '问题：${question.trim().isEmpty ? '请概括照片能确认的天文信息和可靠性。' : question.trim()}\n'
                      '$contextLabel：${jsonEncode(report)}',
            },
          ];
          var toolCallCount = 0;
          while (true) {
            final uri = Uri.parse(
              '${baseUrl.trim().replaceFirst(RegExp(r'/+$'), '')}/chat/completions',
            );
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
                    'messages': messages,
                    'tools': _tools,
                    'tool_choice': 'auto',
                  }),
                )
                .timeout(const Duration(seconds: 45));
            if (response.statusCode < 200 || response.statusCode >= 300) {
              throw HttpException('模型 API 返回 HTTP ${response.statusCode}。');
            }
            final decoded = jsonDecode(response.body) as Map<String, dynamic>;
            final message = decoded['choices']?[0]?['message'];
            if (message is! Map) {
              throw const FormatException('模型响应中缺少 assistant 消息。');
            }
            final toolCalls = message['tool_calls'];
            if (toolCalls is! List || toolCalls.isEmpty) {
              final content = message['content'];
              if (content is! String || content.trim().isEmpty) {
                throw const FormatException('模型返回内容为空。');
              }
              return content.trim();
            }
            if (toolCalls.length + toolCallCount > maxToolCalls) {
              throw StateError('Agent 达到本轮工具调用上限（$maxToolCalls 次）。');
            }
            messages.add(Map<String, Object?>.from(message));
            for (final rawCall in toolCalls) {
              if (rawCall is! Map) {
                throw const FormatException('模型返回了无效的工具调用。');
              }
              final call = Map<String, Object?>.from(rawCall);
              final function = call['function'];
              if (function is! Map || call['id'] is! String) {
                throw const FormatException('模型返回了不完整的工具调用。');
              }
              final functionMap = Map<String, Object?>.from(function);
              final name = functionMap['name'];
              final rawArguments = functionMap['arguments'];
              if (name is! String || rawArguments is! String) {
                throw const FormatException('模型返回了无效的工具参数。');
              }
              final arguments = jsonDecode(rawArguments);
              if (arguments is! Map) {
                throw const FormatException('工具参数必须是 JSON 对象。');
              }
              onToolCall?.call(name);
              anyToolExecuted = true;
              final result = await executeTool(
                name,
                Map<String, Object?>.from(arguments),
              );
              toolCallCount++;
              messages.add({
                'role': 'tool',
                'tool_call_id': call['id'],
                'name': name,
                'content': jsonEncode(result),
              });
            }
          }
        } catch (error) {
          if (anyToolExecuted) rethrow;
          errors.add('$model：$error');
        }
      }
      throw StateError(errors.isEmpty ? '未配置可用模型。' : errors.join('\n'));
    } finally {
      if (httpClient == null) client.close();
    }
  }

  /// 从画面里的深空天体里挑出「这张照片拍的是哪一个」。
  ///
  /// ## 为什么这件事交给模型，而测量不交
  ///
  /// 候选编号、坐标、角尺寸、占像场多大——全是本机算出来的**测量**，模型一个
  /// 字都不许改。而「这些里面哪个才是主角」是个**判断**，它需要的正是模型知道
  /// 而本机不知道的东西：哪个名字是爱好者真会说的。
  ///
  /// 实况就是这么暴露出来的：拍昴星团的那张图里，IC 353 在目录里记着 180′，
  /// 比 M45 的 110′ 大，于是按尺寸排出来的「主体」成了 IC 353——一个没有星等、
  /// 没有常用名、大部分人没听说过的暗反射星云，而 180′ 这个数本身就可疑
  /// （目录里 IC 360、IC 2118 也是恰好 180.0′）。本机只能靠手写的常用名表去
  /// 近似，而那张表回答不了「M45 和 IC 353 之间选哪个」。
  ///
  /// ## 只允许排序，不允许增删
  ///
  /// 回答必须**逐字**等于候选里的某一个编号，否则返回 null、整个判断作废。模型
  /// 编一个天体出来是最坏的结果：报告顶部会郑重其事地写一个画面里根本没有的
  /// 东西，而用户没法察觉。
  ///
  /// 失败一律返回 null，调用方保留本机的次序——没配模型、断网、模型答得不像话，
  /// 结果都只是「和以前一样」，不会变成「报告坏了」。
  static Future<String?> pickPrimaryDeepSky({
    required String baseUrl,
    required String apiKey,
    required String model,
    required List<DeepSkyCandidate> candidates,
    http.Client? httpClient,
  }) async {
    if (candidates.length < 2) return null;
    if (apiKey.trim().isEmpty || model.trim().isEmpty) return null;
    final client = httpClient ?? http.Client();
    try {
      final uri = Uri.parse(
        '${baseUrl.trim().replaceFirst(RegExp(r'/+$'), '')}/chat/completions',
      );
      final response = await client.post(
        uri,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${apiKey.trim()}',
        },
        body: jsonEncode({
          'model': model.trim(),
          'temperature': 0,
          'messages': [
            {
              'role': 'system',
              'content':
                  '你是天文观测助手。用户会给你一张照片里解出来的深空天体清单，'
                      '你要指出这张照片**拍的是哪一个**。'
                      '只能从清单里的编号中选一个，逐字照抄，不要发明编号，'
                      '也不要解释。判断依据是「爱好者会说自己拍了什么」：'
                      '优先选那个大家都叫得出名字的目标，而不是尺寸数字最大的。'
                      '只输出 JSON：{"primary": "编号"}。',
            },
            {
              'role': 'user',
              'content': jsonEncode({'objects': [for (final c in candidates) c.toJson()]}),
            },
          ],
        }),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) return null;
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final content = decoded['choices']?[0]?['message']?['content'];
      if (content is! String) return null;
      final pick = _primaryFrom(content);
      if (pick == null) return null;
      // 必须是候选里真有的那一个，而且要**逐字**相等——差一个空格都算没匹配上，
      // 返回去也没法在列表里定位。
      for (final candidate in candidates) {
        if (candidate.name == pick) return candidate.name;
      }
      return null;
    } catch (_) {
      // 挑主体这件事失败不该影响任何别的东西：报告照出，只是顺序按本机那套。
      return null;
    } finally {
      if (httpClient == null) client.close();
    }
  }

  /// 从模型那段话里抠出 `{"primary": "…"}`。
  ///
  /// 不要求整段就是 JSON：模型常常会包一层 ```json 围栏，或者先说一句「这张
  /// 照片拍的是」再给 JSON。所以只找 `primary` 对应的那个字符串。
  static String? _primaryFrom(String content) {
    final match = RegExp(r'"primary"\s*:\s*"([^"]*)"').firstMatch(content);
    final value = match?.group(1)?.trim();
    if (value == null || value.isEmpty) return null;
    return value;
  }

  static Future<List<Map<String, double>>> proposeNonSkyRegions({
    required String baseUrl,
    required String apiKey,
    required String model,
    required String imageBase64,
    required int imageWidth,
    required int imageHeight,
    http.Client? httpClient,
  }) async {
    if (apiKey.trim().isEmpty || model.trim().isEmpty) {
      throw StateError('未配置可用的视觉模型 API Key 或模型名。');
    }
    if (imageWidth <= 0 || imageHeight <= 0) {
      throw ArgumentError('视觉分析的图像尺寸无效。');
    }
    final client = httpClient ?? http.Client();
    try {
      final uri = Uri.parse(
        '${baseUrl.trim().replaceFirst(RegExp(r'/+$'), '')}/chat/completions',
      );
      final response = await client
          .post(
            uri,
            headers: {
              'Authorization': 'Bearer ${apiKey.trim()}',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'model': model.trim(),
              'temperature': 0,
              'messages': [
                {
                  'role': 'system',
                  'content':
                      '你是天文照片的水印区域定位器。只找明确叠加在照片上的文字、'
                          '水印、相机状态栏或 UI；不要把星云、星团、星轨、暗角、'
                          '地景或任何可能的天体结构标为遮罩。若不确定，返回空 regions。'
                          '只输出 JSON：{"regions":[{"x":0,"y":0,"width":0,"height":0}]}。'
                          '坐标是相对于整张图片左上角的 0 到 1 归一化矩形；'
                          '最多 8 个框，每框不超过图像面积 25%，合计不超过 30%。',
                },
                {
                  'role': 'user',
                  'content': [
                    {
                      'type': 'text',
                      'text': '请定位明确的文字/水印叠加区域。',
                    },
                    {
                      'type': 'image_url',
                      'image_url': {
                        'url': 'data:image/jpeg;base64,$imageBase64',
                        'detail': 'high',
                      },
                    },
                  ],
                },
              ],
            }),
          )
          .timeout(const Duration(seconds: 60));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('视觉模型 API 返回 HTTP ${response.statusCode}。');
      }
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final rawContent = decoded['choices']?[0]?['message']?['content'];
      final content = switch (rawContent) {
        String value => value,
        List values => values
            .whereType<Map>()
            .map((part) => part['text'])
            .whereType<String>()
            .join('\n'),
        _ => '',
      };
      if (content.trim().isEmpty) {
        throw const FormatException('视觉模型没有返回区域建议。');
      }
      final jsonText = content
          .trim()
          .replaceFirst(RegExp(r'^```(?:json)?\s*'), '')
          .replaceFirst(RegExp(r'\s*```$'), '');
      final result = jsonDecode(jsonText);
      if (result is! Map || result['regions'] is! List) {
        throw const FormatException('视觉模型区域建议格式无效。');
      }
      final rawRegions = result['regions']! as List;
      if (rawRegions.length > 8) {
        throw const FormatException('视觉模型建议的区域数量超出上限。');
      }
      final regions = <Map<String, double>>[];
      var totalArea = 0.0;
      for (final rawRegion in rawRegions) {
        if (rawRegion is! Map) {
          throw const FormatException('视觉模型返回了无效的区域。');
        }
        final region = <String, double>{};
        for (final key in const ['x', 'y', 'width', 'height']) {
          final value = rawRegion[key];
          if (value is! num || !value.toDouble().isFinite) {
            throw const FormatException('视觉模型区域坐标必须是有限数字。');
          }
          region[key] = value.toDouble();
        }
        final x = region['x']!;
        final y = region['y']!;
        final width = region['width']!;
        final height = region['height']!;
        final area = width * height;
        if (x < 0 ||
            y < 0 ||
            width <= 0 ||
            height <= 0 ||
            x + width > 1 ||
            y + height > 1 ||
            area > 0.25 ||
            width * imageWidth < 2 ||
            height * imageHeight < 2) {
          throw const FormatException('视觉模型区域坐标超出允许范围。');
        }
        if (regions.any(
          (other) =>
              x < other['x']! + other['width']! &&
              x + width > other['x']! &&
              y < other['y']! + other['height']! &&
              y + height > other['y']!,
        )) {
          throw const FormatException('视觉模型区域建议互相重叠。');
        }
        totalArea += area;
        if (totalArea > 0.3) {
          throw const FormatException('视觉模型建议的遮罩总面积过大。');
        }
        regions.add(region);
      }
      return regions;
    } finally {
      if (httpClient == null) client.close();
    }
  }

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
          final uri = Uri.parse(
            '${baseUrl.trim().replaceFirst(RegExp(r'/+$'), '')}/chat/completions',
          );
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
