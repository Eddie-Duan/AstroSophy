package com.astrosophy.app

import android.content.Context
import android.graphics.ImageFormat
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.media.ImageReader
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "astrosophy/camera_pro"
    private var device: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var reader: ImageReader? = null
    private var pendingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "capabilities" -> result.success(capabilities())
                    "capture" -> {
                        val exposureNs = (call.argument<Number>("exposureNs"))?.toLong()
                            ?: 500_000_000L
                        val iso = (call.argument<Number>("iso"))?.toInt() ?: 800
                        capture(exposureNs, iso, result)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun backCameraId(): String? {
        val manager = getSystemService(Context.CAMERA_SERVICE) as CameraManager
        return manager.cameraIdList.firstOrNull { id ->
            manager.getCameraCharacteristics(id)
                .get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_BACK
        } ?: manager.cameraIdList.firstOrNull()
    }

    private fun capabilities(): Map<String, Any?> {
        val manager = getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val id = backCameraId()
            ?: return mapOf("supported" to false)
        val c = manager.getCameraCharacteristics(id)
        val exposure = c.get(CameraCharacteristics.SENSOR_INFO_EXPOSURE_TIME_RANGE)
        val iso = c.get(CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE)
        val sizes = c.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            ?.getOutputSizes(ImageFormat.JPEG)
        val largest = sizes?.maxByOrNull { it.width.toLong() * it.height }
        return mapOf(
            "supported" to (exposure != null && iso != null && largest != null),
            "exposureMinNs" to (exposure?.lower ?: 0L),
            "exposureMaxNs" to (exposure?.upper ?: 0L),
            "isoMin" to (iso?.lower ?: 100),
            "isoMax" to (iso?.upper ?: 3200),
            "width" to (largest?.width ?: 0),
            "height" to (largest?.height ?: 0),
        )
    }

    private fun capture(exposureNs: Long, iso: Int, result: MethodChannel.Result) {
        if (pendingResult != null) {
            result.error("busy", "A capture is already running", null)
            return
        }
        pendingResult = result
        val manager = getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val id = backCameraId()
        if (id == null) {
            finishError("no_camera", "No camera available")
            return
        }
        val characteristics = manager.getCameraCharacteristics(id)
        val sizes = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            ?.getOutputSizes(ImageFormat.JPEG)
        val largest = sizes?.maxByOrNull { it.width.toLong() * it.height }
        if (largest == null) {
            finishError("no_jpeg", "Camera has no JPEG output")
            return
        }
        val imageReader = ImageReader.newInstance(
            largest.width, largest.height, ImageFormat.JPEG, 1
        )
        reader = imageReader
        val handler = Handler(Looper.getMainLooper())
        imageReader.setOnImageAvailableListener({ r ->
            val image = r.acquireNextImage()
            if (image == null) {
                finishError("no_image", "Empty capture")
                return@setOnImageAvailableListener
            }
            val buffer = image.planes[0].buffer
            val bytes = ByteArray(buffer.remaining())
            buffer.get(bytes)
            image.close()
            val out = pendingResult
            cleanup()
            pendingResult = null
            out?.success(bytes)
        }, handler)

        try {
            manager.openCamera(id, object : CameraDevice.StateCallback() {
                override fun onOpened(camera: CameraDevice) {
                    device = camera
                    try {
                        camera.createCaptureSession(
                            listOf(imageReader.surface),
                            object : CameraCaptureSession.StateCallback() {
                                override fun onConfigured(s: CameraCaptureSession) {
                                    session = s
                                    try {
                                        val request = camera.createCaptureRequest(
                                            CameraDevice.TEMPLATE_STILL_CAPTURE
                                        ).apply {
                                            addTarget(imageReader.surface)
                                            set(
                                                CaptureRequest.CONTROL_AE_MODE,
                                                CaptureRequest.CONTROL_AE_MODE_OFF
                                            )
                                            set(
                                                CaptureRequest.SENSOR_EXPOSURE_TIME,
                                                exposureNs
                                            )
                                            set(
                                                CaptureRequest.SENSOR_SENSITIVITY,
                                                iso
                                            )
                                            set(
                                                CaptureRequest.CONTROL_AF_MODE,
                                                CaptureRequest.CONTROL_AF_MODE_OFF
                                            )
                                            set(
                                                CaptureRequest.CONTROL_AWB_MODE,
                                                CaptureRequest.CONTROL_AWB_MODE_AUTO
                                            )
                                        }
                                        if ((characteristics.get(
                                                CameraCharacteristics.LENS_INFO_MINIMUM_FOCUS_DISTANCE
                                            ) ?: 0f) > 0f
                                        ) {
                                            request.set(
                                                CaptureRequest.LENS_FOCUS_DISTANCE, 0f
                                            )
                                        }
                                        s.capture(request.build(), null, handler)
                                    } catch (e: Exception) {
                                        finishError("capture_failed", e.message)
                                    }
                                }

                                override fun onConfigureFailed(s: CameraCaptureSession) {
                                    finishError("session_failed", "Could not configure camera")
                                }
                            },
                            handler
                        )
                    } catch (e: Exception) {
                        finishError("session_failed", e.message)
                    }
                }

                override fun onDisconnected(camera: CameraDevice) {
                    finishError("disconnected", "Camera disconnected")
                }

                override fun onError(camera: CameraDevice, error: Int) {
                    finishError("camera_error", "Camera error $error")
                }
            }, handler)
        } catch (e: SecurityException) {
            finishError("permission", "Camera permission is required")
        } catch (e: Exception) {
            finishError("open_failed", e.message)
        }
    }

    private fun finishError(code: String, message: String?) {
        val out = pendingResult
        cleanup()
        pendingResult = null
        out?.error(code, message ?: code, null)
    }

    private fun cleanup() {
        try {
            session?.close()
        } catch (_: Exception) {
        }
        try {
            device?.close()
        } catch (_: Exception) {
        }
        try {
            reader?.close()
        } catch (_: Exception) {
        }
        session = null
        device = null
        reader = null
    }
}
