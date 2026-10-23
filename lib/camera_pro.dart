import 'package:flutter/services.dart';

class CameraProCapabilities {
  const CameraProCapabilities({
    required this.supported,
    required this.exposureMinNs,
    required this.exposureMaxNs,
    required this.isoMin,
    required this.isoMax,
    required this.width,
    required this.height,
  });

  final bool supported;
  final int exposureMinNs;
  final int exposureMaxNs;
  final int isoMin;
  final int isoMax;
  final int width;
  final int height;

  static const unsupported = CameraProCapabilities(
    supported: false,
    exposureMinNs: 0,
    exposureMaxNs: 0,
    isoMin: 0,
    isoMax: 0,
    width: 0,
    height: 0,
  );

  factory CameraProCapabilities.fromMap(Map<Object?, Object?> map) =>
      CameraProCapabilities(
        supported: map['supported'] == true,
        exposureMinNs: (map['exposureMinNs'] as num?)?.toInt() ?? 0,
        exposureMaxNs: (map['exposureMaxNs'] as num?)?.toInt() ?? 0,
        isoMin: (map['isoMin'] as num?)?.toInt() ?? 0,
        isoMax: (map['isoMax'] as num?)?.toInt() ?? 0,
        width: (map['width'] as num?)?.toInt() ?? 0,
        height: (map['height'] as num?)?.toInt() ?? 0,
      );
}

/// Android Camera2 的专业模式通道。
///
/// 真正的曝光/ISO 控制不在 Flutter camera 插件里；这个通道只负责“拍一张
/// 全分辨率静态图”，预览和实时跟踪仍由 camera 插件负责。
class CameraProService {
  static const _channel = MethodChannel('astrosophy/camera_pro');

  static Future<CameraProCapabilities> capabilities() async {
    final map = await _channel.invokeMethod<Map<Object?, Object?>>('capabilities');
    if (map == null) return CameraProCapabilities.unsupported;
    return CameraProCapabilities.fromMap(map);
  }

  static Future<Uint8List> capture({
    required double exposureSeconds,
    required int iso,
  }) async {
    final bytes = await _channel.invokeMethod<Uint8List>('capture', {
      'exposureNs': (exposureSeconds * 1e9).round(),
      'iso': iso,
    });
    if (bytes == null || bytes.isEmpty) {
      throw StateError('相机没有返回照片。');
    }
    return bytes;
  }
}
