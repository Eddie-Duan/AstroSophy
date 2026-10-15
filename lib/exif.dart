import 'dart:typed_data';

import 'models.dart';

/// 从照片字节里读出来的拍摄时刻。
///
/// 只读时间，不读别的一概不碰：这个项目要 EXIF 的地方只有一处——算行星位置
/// 得知道照片是什么时候拍的。设备型号、光圈、坐标都不读，也不读进内存，更不
/// 写进档案（坐标是私人信息，演示图就是因为它被裁过）。
class CaptureMoment {
  const CaptureMoment({
    required this.local,
    required this.offset,
    required this.source,
  });

  /// 相机写下的拍摄时间。**没有时区**：EXIF 的 `DateTimeOriginal` 按规范是
  /// 当地时间，但确实有相机往里写 UTC，从文件里分辨不出来。
  final DateTime local;

  /// 这个时间相对 UTC 的偏移。EXIF 的 `OffsetTimeOriginal`、或者同类标签
  /// 里的 GPS 时间能给出它；两个都没有就是 null，此时**时区是未知的**。
  final Duration? offset;

  /// 时间读自哪个标签，报告里要如实写清楚。
  final CaptureTimeSource source;

  /// 换算成 UTC。时区未知时返回 null——不猜。差几个小时对行星位置的影响是
  /// 角分量级，但对「是不是这个天体」的判断没有影响；不过报告里得说明白。
  DateTime? get utc => offset == null ? null : _shiftedBy(offset!);

  /// 换算成 UTC，时区未知时按 [fallbackOffset] 算。
  ///
  /// 手机照片基本都是在设备当时所在的时区拍的，而「设备现在的时区」是可以
  /// 问到的、最接近的答案。用它算出来的时刻**要写进报告**：这是一条假设，
  /// 不是从文件里读出来的事实。
  DateTime utcAt(Duration fallbackOffset) =>
      _shiftedBy(offset ?? fallbackOffset);

  /// 把当地挂钟时间减去偏移，结果按 UTC 表达。
  ///
  /// 不能写成 `local.subtract(delta)`：[local] 是不带时区的挂钟时间，减出来的
  /// 还是「本机时区里的那个挂钟时间」——字段对、瞬间错。同一张照片在两台时区
  /// 不同的手机上会算出不同的毫秒数，而这里要的正是一个唯一的瞬间。先按字段
  /// 造一个 UTC 时刻再减，跨日跨月由 DateTime 自己处理。
  DateTime _shiftedBy(Duration delta) => DateTime.utc(
        local.year,
        local.month,
        local.day,
        local.hour,
        local.minute,
        local.second,
      ).subtract(delta);

  /// 时区是读出来的还是假定的。
  bool get hasKnownOffset => offset != null;

  /// 是不是用户手填的。
  bool get isManual => source == CaptureTimeSource.manual;

  /// 存进档案的形式（见 `models.dart` 的 `CaptureMetadata`）。
  CaptureMetadata toMetadata() => CaptureMetadata(
        timestamp: _iso(local),
        timestampOffsetMinutes: offset?.inMinutes,
        timestampSource: source.name,
      );

  static String _iso(DateTime value) {
    String two(int number) => number.toString().padLeft(2, '0');
    return '${value.year.toString().padLeft(4, '0')}-${two(value.month)}-'
        '${two(value.day)}T${two(value.hour)}:${two(value.minute)}:'
        '${two(value.second)}';
  }
}

/// 从档案里读回拍摄时刻。读不出时间就返回 null。
CaptureMoment? captureMomentFromMetadata(CaptureMetadata? metadata) {
  final text = metadata?.timestamp;
  if (text == null) return null;
  final local = DateTime.tryParse(text);
  if (local == null) return null;
  final minutes = metadata!.timestampOffsetMinutes;
  final source = CaptureTimeSource.values.firstWhere(
    (value) => value.name == metadata.timestampSource,
    orElse: () => CaptureTimeSource.manual,
  );
  return CaptureMoment(
    local: DateTime(local.year, local.month, local.day, local.hour,
        local.minute, local.second),
    offset: minutes == null ? null : Duration(minutes: minutes),
    source: source,
  );
}

/// 拍摄时间是从哪里来的。
enum CaptureTimeSource {
  /// EXIF `DateTimeOriginal`（0x9003）。
  dateTimeOriginal,

  /// EXIF `DateTime`（0x0132）。相机写的是「文件生成时间」，手机上基本等于
  /// 拍摄时间，但严格说不是一回事，所以单列一档。
  fileModified,

  /// EXIF 的 GPS 日期 + 时间。按规范是 UTC，直接可用。
  gps,

  /// 图片里没有可用时间，用户手填的。
  manual,

  /// 演示图自带的拍摄时间。
  ///
  /// 这几张是从原图上裁下来的，EXIF 早被裁没了，时间只能跟着图一起写进
  /// 代码里。它和「手填」不同：这是拍摄者提供的原始信息，不是用户在现场
  /// 现补的，报告里该分清楚。
  demo;

  String get label => switch (this) {
        CaptureTimeSource.dateTimeOriginal => '照片 EXIF 的拍摄时间',
        CaptureTimeSource.fileModified => '照片 EXIF 的文件时间',
        CaptureTimeSource.gps => '照片 EXIF 的 GPS 时间',
        CaptureTimeSource.manual => '你手动填写的时间',
        CaptureTimeSource.demo => '演示图自带的拍摄时间',
      };
}

/// 从图片字节里读拍摄时间。读不到返回 null。
///
/// 支持 JPEG（手机照片）和 TIFF 系容器（`.tif`，以及 DNG / CR2 / NEF / ARW
/// 这些同样以 TIFF 开头的 RAW）。PNG 和 WebP 不带 EXIF 时间，返回 null。
///
/// 不用第三方 EXIF 包，理由和自写 Markdown 渲染器一样：要用的只有三个标签，
/// 一百来行解析比一个长期没人维护的依赖（还会顺带读走整包私有信息）更好交代。
CaptureMoment? readCaptureMoment(Uint8List bytes) {
  final tiff = _tiffBlock(bytes);
  if (tiff == null || tiff.length < 8) return null;
  final reader = _Directory(tiff);
  if (!reader.isValid) return null;

  final ifd0 = reader.read(reader.u32(4));
  final exifIfd = switch (ifd0[0x8769]) {
    final entry? => reader.read(reader.u32(entry.valueOffset)),
    _ => const <int, _Entry>{},
  };

  final original = parseExifTimestamp(exifIfd[0x9003]?.ascii(reader));
  final modified = parseExifTimestamp(ifd0[0x0132]?.ascii(reader));
  final gpsUtc = _gpsTime(reader, ifd0);

  final local = original ?? modified;
  if (local != null) {
    // 时区：先看 EXIF 自己写的偏移，再拿 GPS 的 UTC 时间和它对照着反推。
    final offset = _parseOffset(exifIfd[0x9011]?.ascii(reader)) ??
        _parseOffset(ifd0[0x9010]?.ascii(reader)) ??
        (gpsUtc == null ? null : _offsetFromGps(local, gpsUtc));
    return CaptureMoment(
      local: local,
      offset: offset,
      source: original != null
          ? CaptureTimeSource.dateTimeOriginal
          : CaptureTimeSource.fileModified,
    );
  }
  // 没有拍摄时间标签，但 GPS 时间是现成的——它按规范就是 UTC。
  if (gpsUtc != null) {
    return CaptureMoment(
      local: gpsUtc,
      offset: Duration.zero,
      source: CaptureTimeSource.gps,
    );
  }
  return null;
}

/// 解析 EXIF 的时间文本（`2026:10:15 21:34:07`）成不带时区的 [DateTime]。
///
/// 分隔符允许 `:`、`-`、`/` 和空格混用：规范写的是冒号，但真机上这些写法都
/// 出现过，而多收一种写法不会有任何代价。
DateTime? parseExifTimestamp(String? text) {
  if (text == null) return null;
  final match = RegExp(r'(\d{4})\D(\d{1,2})\D(\d{1,2})\D+(\d{1,2})\D(\d{1,2})\D(\d{1,2})')
      .firstMatch(text.trim());
  if (match == null) return null;
  int part(int index) => int.parse(match.group(index)!);
  final year = part(1);
  final month = part(2);
  final day = part(3);
  final hour = part(4);
  final minute = part(5);
  final second = part(6);
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  if (hour > 23 || minute > 59 || second > 60) return null;
  if (year < 1800 || year > 2200) return null;
  return DateTime(year, month, day, hour, minute, second);
}

/// 解析 `+08:00` / `-0530` 这样的 UTC 偏移。
Duration? _parseOffset(String? text) {
  if (text == null) return null;
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  final match = RegExp(r'^([+-])(\d{2}):?(\d{2})$').firstMatch(trimmed);
  if (match == null) return null;
  final sign = match.group(1) == '-' ? -1 : 1;
  final hours = int.parse(match.group(2)!);
  final minutes = int.parse(match.group(3)!);
  if (hours > 14 || minutes > 59) return null;
  return Duration(minutes: sign * (hours * 60 + minutes));
}

/// 用 GPS 的 UTC 时间反推当地偏移。
///
/// 相机写 GPS 时间是常见做法，写 `OffsetTimeOriginal` 的反而不多。两者相减
/// 就是当地偏移；差值必须落在整刻钟上、且在现实范围内，否则说明两边有一头
/// 是错的（有相机把 GPS 时间也写成当地时间），宁可认「时区未知」。
Duration? _offsetFromGps(DateTime local, DateTime gpsUtc) {
  final delta = local.difference(gpsUtc);
  if (delta.inHours.abs() > 14) return null;
  final minutes = (delta.inMinutes / 15).round() * 15;
  if ((delta.inMinutes - minutes).abs() > 2) return null;
  return Duration(minutes: minutes);
}

/// 读 GPS 日期（0x001D）+ 时间（0x0007）并合成 UTC 时刻。
DateTime? _gpsTime(_Directory reader, Map<int, _Entry> ifd0) {
  final pointer = ifd0[0x8825];
  if (pointer == null) return null;
  final gps = reader.read(reader.u32(pointer.valueOffset));
  final stamp = gps[0x001D]?.ascii(reader);
  final clock = gps[0x0007];
  if (stamp == null || clock == null || clock.count < 3) return null;
  final date = parseExifTimestamp('${stamp.trim()} 00:00:00');
  if (date == null) return null;
  final hour = _rational(reader, clock.valueOffset);
  final minute = _rational(reader, clock.valueOffset + 8);
  final second = _rational(reader, clock.valueOffset + 16);
  if (hour == null || minute == null || second == null) return null;
  final wholeSeconds = second.floor();
  return DateTime.utc(
    date.year,
    date.month,
    date.day,
    hour.round(),
    minute.round(),
    wholeSeconds,
  );
}

double? _rational(_Directory reader, int offset) {
  final numerator = reader.u32(offset);
  final denominator = reader.u32(offset + 4);
  if (denominator == 0) return null;
  return numerator / denominator;
}

/// 找出图片里的 EXIF 数据块（TIFF 结构那一整段）。
///
/// 返回的视图从 TIFF 头开始——EXIF 里所有偏移量都是相对它算的。
Uint8List? _tiffBlock(Uint8List bytes) {
  if (bytes.length < 8) return null;
  // JPEG：顺着段走，找 APP1 里的 "Exif\0\0"。
  if (bytes[0] == 0xFF && bytes[1] == 0xD8) {
    var offset = 2;
    while (offset + 4 <= bytes.length) {
      if (bytes[offset] != 0xFF) {
        offset++;
        continue;
      }
      final marker = bytes[offset + 1];
      // 无载荷的标记：填充、重启、以及 TEM。
      if (marker == 0xFF || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD8)) {
        offset += 2;
        continue;
      }
      // 到了压缩数据或者文件尾，后面不会再有 APP1 了。
      if (marker == 0xDA || marker == 0xD9) return null;
      if (offset + 4 > bytes.length) return null;
      final length = (bytes[offset + 2] << 8) | bytes[offset + 3];
      if (length < 2 || offset + 2 + length > bytes.length) return null;
      if (marker == 0xE1 &&
          length >= 8 &&
          bytes[offset + 4] == 0x45 && // 'E'
          bytes[offset + 5] == 0x78 && // 'x'
          bytes[offset + 6] == 0x69 && // 'i'
          bytes[offset + 7] == 0x66 && // 'f'
          bytes[offset + 8] == 0x00 &&
          bytes[offset + 9] == 0x00) {
        return Uint8List.sublistView(bytes, offset + 10, offset + 2 + length);
      }
      offset += 2 + length;
    }
    return null;
  }
  // TIFF 系容器（含 DNG / CR2 / NEF / ARW）：文件本身就是 TIFF，直接读。
  if ((bytes[0] == 0x49 && bytes[1] == 0x49) ||
      (bytes[0] == 0x4D && bytes[1] == 0x4D)) {
    return bytes;
  }
  return null;
}

/// TIFF 目录（IFD）的读取器：只管按字节序取值，不做业务判断。
class _Directory {
  _Directory(this.data);

  final Uint8List data;

  bool get littleEndian => data[0] == 0x49;

  /// 头两个字节是 II/MM、接下来两个字节是 42，才算一个像样的 TIFF 头。
  /// 照片本身可能损坏，先看一眼再往下读。
  bool get isValid {
    if (data.length < 8) return false;
    final endianOk = (data[0] == 0x49 && data[1] == 0x49) ||
        (data[0] == 0x4D && data[1] == 0x4D);
    return endianOk && u16(2) == 42;
  }

  int u16(int offset) {
    if (offset + 2 > data.length) return 0;
    return littleEndian
        ? data[offset] | (data[offset + 1] << 8)
        : (data[offset] << 8) | data[offset + 1];
  }

  int u32(int offset) {
    if (offset + 4 > data.length) return 0;
    return littleEndian
        ? data[offset] |
            (data[offset + 1] << 8) |
            (data[offset + 2] << 16) |
            (data[offset + 3] << 24)
        : (data[offset] << 24) |
            (data[offset + 1] << 16) |
            (data[offset + 2] << 8) |
            data[offset + 3];
  }

  /// 读一个 IFD，返回「标签 → 条目」。越界的条目直接丢掉：一张被截断的
  /// 照片不该让整条链路崩掉，读不到时间就当没有时间。
  Map<int, _Entry> read(int offset) {
    final entries = <int, _Entry>{};
    if (offset < 8 || offset + 2 > data.length) return entries;
    final count = u16(offset);
    for (var index = 0; index < count; index++) {
      final base = offset + 2 + index * 12;
      if (base + 12 > data.length) break;
      final entry = _Entry(u16(base + 2), u32(base + 4));
      final size = entry.byteLength;
      if (size <= 0) continue;
      // 值不超过 4 字节时就地存在条目里，否则另有一个偏移量指向它。
      final valueOffset = size <= 4 ? base + 8 : u32(base + 8);
      if (valueOffset <= 0 || valueOffset + size > data.length) continue;
      entries[u16(base)] = _Entry(entry.type, entry.count, valueOffset);
    }
    return entries;
  }
}

/// 一条 IFD 条目。这里只记「值有多大、在哪里」，不解释含义。
class _Entry {
  const _Entry(this.type, this.count, [this.valueOffset = 0]);

  final int type;
  final int count;

  /// 值在 TIFF 块里的绝对偏移。
  final int valueOffset;

  static const _sizes = <int, int>{1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 7: 1, 10: 8};

  int get byteLength => (_sizes[type] ?? 0) * count;

  /// 按 ASCII 读（EXIF 的时间、日期、时区偏移都是这种）。末尾的 NUL 和
  /// 空格是填充，去掉。
  String? ascii(_Directory reader) {
    if (type != 2 || count <= 0) return null;
    final end = valueOffset + count;
    if (end > reader.data.length) return null;
    final raw = reader.data.sublist(valueOffset, end);
    return String.fromCharCodes(raw).replaceAll('\u0000', '').trimRight();
  }
}
