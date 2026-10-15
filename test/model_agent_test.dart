import 'dart:convert';
import 'dart:io';

import 'package:astrosophy/model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('runs a bounded tool round-trip with the configured API key', () async {
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      expect(request.headers['Authorization'], 'Bearer test-key');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['tools'], isA<List<dynamic>>());
      if (requests == 1) {
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'role': 'assistant',
                  'content': null,
                  'tool_calls': [
                    {
                      'id': 'call-1',
                      'type': 'function',
                      'function': {
                        'name': 'find_catalog_object',
                        'arguments': '{"query":"M31"}',
                      },
                    },
                  ],
                },
              },
            ],
          }),
          200,
        );
      }
      expect(
        (body['messages'] as List<dynamic>).last['role'],
        'tool',
      );
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'role': 'assistant', 'content': '找到了 M31。'},
            },
          ],
        }),
        200,
      );
    });
    final calledTools = <String>[];

    final result = await ModelService.chatWithTools(
      baseUrl: 'https://models.example/v1',
      lightKey: 'test-key',
      lightModel: 'test-model',
      strongKey: '',
      strongModel: '',
      report: const {'quality': '良好', 'solved': false},
      question: '查一下 M31',
      httpClient: client,
      executeTool: (name, arguments) async {
        expect(name, 'find_catalog_object');
        expect(arguments, {'query': 'M31'});
        return {'objects': <Object?>[]};
      },
      onToolCall: calledTools.add,
    );

    expect(result, '找到了 M31。');
    expect(requests, 2);
    expect(calledTools, ['find_catalog_object']);
    client.close();
  });

  test('validates normalized regions suggested by a vision-capable model',
      () async {
    final client = MockClient((request) async {
      expect(request.headers['Authorization'], 'Bearer vision-key');
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final messages = body['messages'] as List<dynamic>;
      final userContent = messages.last['content'] as List<dynamic>;
      expect(userContent.last['image_url']['url'], 'data:image/jpeg;base64,AA==');
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {
                'content':
                    '{"regions":[{"x":0.0,"y":0.85,"width":1.0,"height":0.15}]}',
              },
            },
          ],
        }),
        200,
      );
    });

    final regions = await ModelService.proposeNonSkyRegions(
      baseUrl: 'https://models.example/v1',
      apiKey: 'vision-key',
      model: 'vision-model',
      imageBase64: 'AA==',
      imageWidth: 1200,
      imageHeight: 1200,
      httpClient: client,
    );

    expect(regions, [
      {'x': 0.0, 'y': 0.85, 'width': 1.0, 'height': 0.15},
    ]);
    client.close();
  });

  test('rejects overly large vision masks', () async {
    final client = MockClient((request) async {
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {
                'content':
                    '{"regions":[{"x":0,"y":0,"width":0.8,"height":0.8}]}',
              },
            },
          ],
        }),
        200,
      );
    });

    await expectLater(
      ModelService.proposeNonSkyRegions(
        baseUrl: 'https://models.example/v1',
        apiKey: 'vision-key',
        model: 'vision-model',
        imageBase64: 'AA==',
        imageWidth: 1200,
        imageHeight: 1200,
        httpClient: client,
      ),
      throwsFormatException,
    );
    client.close();
  });

  test('does not repeat an executed write action after a later API failure',
      () async {
    var requests = 0;
    var actions = 0;
    final client = MockClient((request) async {
      requests++;
      if (requests == 1) {
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'role': 'assistant',
                  'tool_calls': [
                    {
                      'id': 'call-delete',
                      'type': 'function',
                      'function': {
                        'name': 'delete_observation',
                        'arguments': '{"observation_id":"record-1"}',
                      },
                    },
                  ],
                },
              },
            ],
          }),
          200,
        );
      }
      return http.Response('failed', 503);
    });

    await expectLater(
      ModelService.chatWithTools(
        baseUrl: 'https://models.example/v1',
        lightKey: 'test-key',
        lightModel: 'light-model',
        strongKey: 'fallback-key',
        strongModel: 'strong-model',
        report: const {'quality': '良好', 'solved': false},
        question: '删除记录',
        httpClient: client,
        executeTool: (name, arguments) async {
          actions++;
          return {'deleted': true};
        },
      ),
      throwsA(isA<HttpException>()),
    );
    expect(requests, 2);
    expect(actions, 1);
    client.close();
  });
}
