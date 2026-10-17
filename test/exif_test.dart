import 'dart:typed_data';

import 'package:astrosophy/exif.dart';
import 'package:astrosophy/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// EXIF 时间解析。
///
/// 不用真照片：`assets/demo/` 里的演示图信息条被裁过（见 `lib/demo.dart`），
/// 而相机写出来的排布本来也没有定数。自己造字节能把每条分支单独摆出来，
/// 尤其是时区——真实照片里很少同时出现 `OffsetTimeOriginal` 和 GPS 时间。
///
/// 有两条路径在测试里**没法**钉住，都是同一个原因——「本机时区」进入了计算：
/// 由 GPS 时间反推当地偏移（`_offsetFromGps`）比较的是一个本地时间和一个
/// UTC 时间，差值里含着跑测试那台机器的时区。这一条只能靠实测照片确认。

/// 造一个 TIFF 块（EXIF 的核心结构）。
///
/// 只支持三种值：`int`（LONG，4 字节就地存）、`String`（ASCII，另存）、
/// `List<double>`（RATIONAL，另存，分母固定 1000）。造时间三件套和 GPS
/// 日期时间够了。
///
/// 偏移是算出来的，不是写死的：先定下三张目录各自的位置，再把要另存的值
/// 依次排在后面。写死偏移的话，加一个标签就得重算一遍。
Uint8List _tiff({
  bool littleEndian = true,
  Map<int, Object> ifd0 = const {},
  Map<int, Object> exif = const {},
  Map<int, Object> gps = const {},
}) {
  final out = <int>[];
  void u8(int value) => out.add(value & 0xFF);
  List<int> raw16(int value) => littleEndian
      ? [value & 0xFF, (value >> 8) & 0xFF]
      : [(value >> 8) & 0xFF, value & 0xFF];
  List<int> raw32(int value) => littleEndian
      ? [
          value & 0xFF,
          (value >> 8) & 0xFF,
          (value >> 16) & 0xFF,
          (value >> 24) & 0xFF,
        ]
      : [
          (value >> 24) & 0xFF,
          (value >> 16) & 0xFF,
          (value >> 8) & 0xFF,
          value & 0xFF,
        ];
  void u16(int value) => out.addAll(raw16(value));
  void u32(int value) => out.addAll(raw32(value));

  final ifd0Tags = ifd0.keys.toList()..sort();
  final exifTags = exif.keys.toList()..sort();
  final gpsTags = gps.keys.toList()..sort();
  final hasExif = exifTags.isNotEmpty;
  final hasGps = gpsTags.isNotEmpty;

  const ifd0At = 8;
  final count0 = ifd0Tags.length + (hasExif ? 1 : 0) + (hasGps ? 1 : 0);
  final exifAt = ifd0At + 2 + 12 * count0 + 4;
  final gpsAt = exifAt + (hasExif ? 2 + 12 * exifTags.length + 4 : 0);
  var cursor = gpsAt + (hasGps ? 2 + 12 * gpsTags.length + 4 : 0);

  final blobs = <int, List<int>>{};
  int store(List<int> bytes) {
    final at = cursor;
    blobs[at] = bytes;
    cursor += bytes.length;
    if (cursor.isOdd) cursor++; // TIFF 要求偶对齐。
    return at;
  }

  /// 一条 12 字节目录项：类型、个数、以及「就地值」或「另存偏移」。
  List<int> entry(int tag, Object value) {
    int type;
    int count;
    int slot;
    switch (value) {
      case int():
        type = 4;
        count = 1;
        slot = value;
      case String():
        final bytes = [...value.codeUnits, 0]; // EXIF 的 ASCII 含结尾 NUL。
        type = 2;
        count = bytes.length;
        // 规范要求不超过 4 字节的值直接塞进条目里。短厂商名（`ZWO`）正好
        // 走这条路——写成偏移的话，读回来的会是偏移量本身。
        if (bytes.length <= 4) {
          return raw16(tag) +
              raw16(type) +
              raw32(count) +
              [...bytes, ...List.filled(4 - bytes.length, 0)];
        }
        slot = store(bytes);
      case List<double>():
        final bytes = <int>[];
        for (final number in value) {
          bytes.addAll(raw32((number * 1000).round()));
          bytes.addAll(raw32(1000));
        }
        type = 5;
        count = value.length;
        slot = store(bytes);
      default:
        throw ArgumentError('造不出来的 EXIF 值：$value');
    }
    return raw16(tag) + raw16(type) + raw32(count) + raw32(slot);
  }

  final directory0 = <(int, List<int>)>[
    for (final tag in ifd0Tags) (tag, entry(tag, ifd0[tag]!)),
    if (hasExif) (0x8769, entry(0x8769, exifAt)),
    if (hasGps) (0x8825, entry(0x8825, gpsAt)),
  ]..sort((a, b) => a.$1.compareTo(b.$1));

  // 头：II/MM + 42 + IFD0 的偏移。
  u8(littleEndian ? 0x49 : 0x4D);
  u8(littleEndian ? 0x49 : 0x4D);
  u16(42);
  u32(ifd0At);

  void writeDirectory(List<(int, List<int>)> entries) {
    u16(entries.length);
    for (final (_, bytes) in entries) {
      out.addAll(bytes);
    }
    u32(0); // 没有下一张目录。
  }

  writeDirectory(directory0);
  if (hasExif) {
    final entries = [
      for (final tag in exifTags) (tag, entry(tag, exif[tag]!)),
    ];
    writeDirectory(entries);
  }
  if (hasGps) {
    final entries = [
      for (final tag in gpsTags) (tag, entry(tag, gps[tag]!)),
    ];
    writeDirectory(entries);
  }
  for (final at in blobs.keys.toList()..sort()) {
    while (out.length < at) {
      u8(0);
    }
    out.addAll(blobs[at]!);
  }
  return Uint8List.fromList(out);
}

/// 把 TIFF 块包进 JPEG 的 APP1 段（手机照片走的就是这条路）。
Uint8List _jpeg(Uint8List tiff) {
  // 长度字段把自己这 2 字节也算进去，再加 `Exif\0\0` 和 TIFF 块。
  final length = 8 + tiff.length;
  return Uint8List.fromList([
    0xFF, 0xD8, // SOI
    0xFF, 0xE1, (length >> 8) & 0xFF, length & 0xFF, // APP1
    ...'Exif'.codeUnits, 0, 0,
    ...tiff,
    0xFF, 0xD9, // EOI
  ]);
}

void main() {
  const original = '2026:10:15 21:34:07';

  group('parseExifTimestamp', () {
    test('规范写法', () {
      expect(parseExifTimestamp(original), DateTime(2026, 10, 15, 21, 34, 7));
    });

    test('真机上出现过的其它分隔符', () {
      // 规范写的是冒号，但横线和斜杠的写法都出现过——多收一种没有代价。
      expect(parseExifTimestamp('2026-10-15 21:34:07'), DateTime(2026, 10, 15, 21, 34, 7));
      expect(parseExifTimestamp('2026/10/15 21:34:07'), DateTime(2026, 10, 15, 21, 34, 7));
      expect(parseExifTimestamp('2026:10:15T21:34:07'), DateTime(2026, 10, 15, 21, 34, 7));
    });

    test('月份日期越界的当成没有', () {
      expect(parseExifTimestamp('2026:13:15 21:34:07'), isNull);
      expect(parseExifTimestamp('2026:10:32 21:34:07'), isNull);
      expect(parseExifTimestamp('2026:10:15 25:34:07'), isNull);
    });

    test('读不出时间就是 null，不猜', () {
      expect(parseExifTimestamp(null), isNull);
      expect(parseExifTimestamp(''), isNull);
      expect(parseExifTimestamp('0000:00:00 00:00:00'), isNull);
    });
  });

  group('readCaptureMoment', () {
    test('JPEG 里的 DateTimeOriginal', () {
      final moment = readCaptureMoment(
        _jpeg(_tiff(exif: {0x9003: original})),
      );
      expect(moment, isNotNull);
      expect(moment!.local, DateTime(2026, 10, 15, 21, 34, 7));
      expect(moment.source, CaptureTimeSource.dateTimeOriginal);
      // 没有时区标签，也读不出偏移——这时时区是未知的，不能假装知道。
      expect(moment.hasKnownOffset, isFalse);
      expect(moment.utc, isNull);
    });

    test('OffsetTimeOriginal 给出时区', () {
      final moment = readCaptureMoment(
        _jpeg(_tiff(exif: {0x9003: original, 0x9011: '+08:00'})),
      );
      expect(moment!.offset, const Duration(hours: 8));
      expect(moment.utc, DateTime.utc(2026, 10, 15, 13, 34, 7));
    });

    test('负偏移', () {
      final moment = readCaptureMoment(
        _jpeg(_tiff(exif: {0x9003: original, 0x9011: '-0530'})),
      );
      expect(moment!.offset, const Duration(hours: -5, minutes: -30));
    });

    test('只有文件时间时降一档标注来源', () {
      final moment = readCaptureMoment(
        _jpeg(_tiff(ifd0: {0x0132: original})),
      );
      expect(moment!.local, DateTime(2026, 10, 15, 21, 34, 7));
      // 「文件生成时间」和「拍摄时间」严格说不是一回事，报告里要能区分。
      expect(moment.source, CaptureTimeSource.fileModified);
    });

    test('拍摄时间优先于文件时间', () {
      final moment = readCaptureMoment(
        _jpeg(_tiff(
          ifd0: {0x0132: '2026:10:16 09:00:00'},
          exif: {0x9003: original},
        )),
      );
      expect(moment!.local, DateTime(2026, 10, 15, 21, 34, 7));
      expect(moment.source, CaptureTimeSource.dateTimeOriginal);
    });

    test('没有时间标签但 GPS 时间在：那就是 UTC', () {
      final moment = readCaptureMoment(
        _jpeg(_tiff(gps: {
          0x001D: '2026:10:15',
          0x0007: <double>[13, 34, 7],
        })),
      );
      expect(moment!.source, CaptureTimeSource.gps);
      expect(moment.offset, Duration.zero);
      expect(moment.utc, DateTime.utc(2026, 10, 15, 13, 34, 7));
    });

    test('相机型号、光圈、快门、ISO、焦距都读出来', () {
      final moment = readCaptureMoment(
        _jpeg(_tiff(
          ifd0: {0x010F: 'ZWO', 0x0110: 'Seestar S30 Pro'},
          exif: {
            0x9003: original,
            0x8827: 200,
            0x829A: <double>[380],
            0x829D: <double>[5],
            0x920A: <double>[160],
          },
        )),
      );
      expect(moment, isNotNull);
      expect(moment!.device, 'ZWO Seestar S30 Pro');
      expect(moment.iso, '200');
      expect(moment.exposure, '380s');
      expect(moment.fNumber, 'f/5');
      expect(moment.focalLength, '160.0mm');
    });

    test('型号已经带厂商时不再重复拼一次', () {
      final moment = readCaptureMoment(
        _jpeg(_tiff(ifd0: {
          0x010F: 'Canon',
          0x0110: 'Canon EOS R5',
        }, exif: {0x9003: original})),
      );
      expect(moment!.device, 'Canon EOS R5');
    });

    test('亚秒快门写成 1/N', () {
      final moment = readCaptureMoment(
        _jpeg(_tiff(exif: {0x9003: original, 0x829A: <double>[0.004]})),
      );
      expect(moment!.exposure, '1/250s');
    });

    test('没有拍摄时间时仍然不返回一个只有相机的对象', () {
      // 时间缺席时这条读取路径没有可用的「时刻」，相机信息也就没地方挂。
      // 这是现有契约：报告那张表靠拍摄时间这张卡进入，不单独造一个假时刻。
      expect(
        readCaptureMoment(_jpeg(_tiff(ifd0: {0x0110: 'Seestar S30 Pro'}))),
        isNull,
      );
    });

    test('TIFF 系容器（.tif / DNG / RAW）同样能读', () {
      // 这些格式本身就是 TIFF，没有 JPEG 那层壳。
      final moment = readCaptureMoment(_tiff(exif: {0x9003: original}));
      expect(moment!.local, DateTime(2026, 10, 15, 21, 34, 7));
      expect(moment.source, CaptureTimeSource.dateTimeOriginal);
    });

    test('大端（MM）字节序', () {
      final moment = readCaptureMoment(
        _jpeg(_tiff(littleEndian: false, exif: {0x9003: original})),
      );
      expect(moment!.local, DateTime(2026, 10, 15, 21, 34, 7));
    });

    test('PNG 没有 EXIF，返回 null', () {
      const png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0];
      expect(readCaptureMoment(Uint8List.fromList(png)), isNull);
    });

    test('截断的照片不会崩，只是读不出时间', () {
      final bytes = _jpeg(_tiff(exif: {0x9003: original}));
      expect(readCaptureMoment(Uint8List.sublistView(bytes, 0, 20)), isNull);
      expect(readCaptureMoment(Uint8List(0)), isNull);
      // APP1 的长度字段指向文件之外——损坏的照片里出现过。
      final broken = Uint8List.fromList(bytes);
      broken[5] = 0xFF;
      expect(readCaptureMoment(broken), isNull);
    });
  });

  group('CaptureMoment 与档案之间', () {
    test('存进去再读出来，时间、时区、来源都在', () {
      final moment = readCaptureMoment(
        _jpeg(_tiff(
          ifd0: {0x0110: 'Seestar S30 Pro'},
          exif: {
            0x9003: original,
            0x9011: '+08:00',
            0x8827: 200,
            0x829A: <double>[380],
            0x829D: <double>[5],
            0x920A: <double>[160],
          },
        )),
      )!;
      final restored = captureMomentFromMetadata(moment.toMetadata())!;
      expect(restored.local, moment.local);
      expect(restored.offset, moment.offset);
      expect(restored.source, moment.source);
      expect(restored.isManual, isFalse);
      expect(restored.device, 'Seestar S30 Pro');
      expect(restored.iso, '200');
      expect(restored.exposure, '380s');
      expect(restored.fNumber, 'f/5');
      expect(restored.focalLength, '160.0mm');
    });

    test('时区未知就存成未知，不补一个默认值', () {
      final moment = readCaptureMoment(
        _jpeg(_tiff(exif: {0x9003: original})),
      )!;
      final metadata = moment.toMetadata();
      expect(metadata.timestampOffsetMinutes, isNull);
      // 档案里有时间，就不能被当成「空元信息」丢掉（见 `HistoryStore.save`）。
      expect(metadata.isEmpty, isFalse);
      expect(captureMomentFromMetadata(metadata)!.hasKnownOffset, isFalse);
    });

    test('手填的时刻算得出 UTC，但要按本机时区折算', () {
      final manual = CaptureMoment(
        local: DateTime(2026, 10, 15, 21, 34, 7),
        offset: null,
        source: CaptureTimeSource.manual,
      );
      expect(manual.isManual, isTrue);
      expect(manual.utc, isNull);
      expect(
        manual.utcAt(const Duration(hours: 8)),
        DateTime.utc(2026, 10, 15, 13, 34, 7),
      );
    });

    test('空元信息读回来是 null', () {
      expect(captureMomentFromMetadata(null), isNull);
      expect(captureMomentFromMetadata(const CaptureMetadata()), isNull);
      expect(
        captureMomentFromMetadata(const CaptureMetadata(timestamp: '不是时间')),
        isNull,
      );
    });
  });
}
