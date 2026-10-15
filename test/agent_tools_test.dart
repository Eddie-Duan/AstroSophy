import 'dart:io';

import 'package:astrosophy/agent_tools.dart';
import 'package:astrosophy/history.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late AgentTools tools;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('astrosophy-agent-tools-');
    tools = AgentTools(
      report: {
        'catalog_stars': [
          {'name': '天狼星', 'ra_deg': 101.28},
        ],
        'deep_sky_objects': [
          {'name': 'M31', 'type': '星系'},
        ],
      },
      loadHistory: (await HistoryStore.open(root: root)).list,
    );
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  test('returns the current report and searches only current-field objects',
      () async {
    final report = await tools.execute('get_current_report', const {});
    expect(report, isA<Map<String, Object?>>());

    final result = await tools.execute(
      'find_catalog_object',
      {'query': '天狼'},
    ) as Map<String, Object?>;
    expect(result['count'], 1);
    expect((result['objects'] as List).single['name'], '天狼星');
  });

  test('lists local observation summaries without photo data', () async {
    final result = await tools.execute(
      'list_observations',
      {'limit': 3},
    ) as Map<String, Object?>;

    expect(result['count'], 0);
    expect(result['observations'], isEmpty);
  });

  test('rejects unknown tools and invalid arguments', () async {
    await expectLater(
      tools.execute('delete_file', const {}),
      throwsArgumentError,
    );
    await expectLater(
      tools.execute('list_observations', {'limit': 1000}),
      throwsFormatException,
    );
    await expectLater(
      tools.execute('get_current_report', {'path': 'anything'}),
      throwsFormatException,
    );
  });
}
