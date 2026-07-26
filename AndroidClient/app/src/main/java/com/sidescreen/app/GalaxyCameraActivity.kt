package com.sidescreen.app

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.media.ImageReader
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.util.Size
import android.view.Surface
import android.view.TextureView
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import com.sidescreen.app.databinding.ActivityGalaxyCameraBinding
import java.io.BufferedOutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

private const val DEFAULT_CAMERA_HOST = "127.0.0.1"
private const val DEFAULT_CAMERA_PORT = 54323
private const val MAX_UI_ZOOM = 20f

private data class CameraOption(
    val id: String,
    val facing: Int?,
    val label: String,
)

class GalaxyCameraActivity : AppCompatActivity() {
    companion object {
        private const val EXTRA_CAMERA_HOST = "com.sidescreen.app.CAMERA_HOST"
        private const val EXTRA_CAMERA_PORT = "com.sidescreen.app.CAMERA_PORT"

        fun createIntent(context: Context, host: String = DEFAULT_CAMERA_HOST, port: Int = DEFAULT_CAMERA_PORT): Intent {
            return Intent(context, GalaxyCameraActivity::class.java)
                .putExtra(EXTRA_CAMERA_HOST, host)
                .putExtra(EXTRA_CAMERA_PORT, port)
        }
    }

    private lateinit var binding: ActivityGalaxyCameraBinding
    private lateinit var cameraManager: CameraManager
    private var cameraThread: HandlerThread? = null
    private var cameraHandler: Handler? = null
    private var cameraDevice: CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null
    private var imageReader: ImageReader? = null
    private var previewSurface: Surface? = null
    private var currentCameraId: String? = null
    private var cameraOptions: List<CameraOption> = emptyList()
    private var selectedCameraIndex = 0
    private var captureRequestBuilder: CaptureRequest.Builder? = null
    private var activeArraySize: Rect? = null
    private var zoomRatio = 1f
    private var maxZoomRatio = 1f
    private var socket: Socket? = null
    private var output: BufferedOutputStream? = null
    private var cameraHost = DEFAULT_CAMERA_HOST
    private var cameraPort = DEFAULT_CAMERA_PORT
    private val networkExecutor = Executors.newSingleThreadExecutor()
    private val sendingFrame = AtomicBoolean(false)
    private var framesSent = 0
    private var framesDropped = 0
    private var lastStatsAt = System.currentTimeMillis()

    private val cameraPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            if (granted) {
                startCameraWhenReady()
            } else {
                setStatus("Camera permission required")
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityGalaxyCameraBinding.inflate(layoutInflater)
        setContentView(binding.root)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        enableFullscreen()
        configureEndpoint(intent)

        cameraManager = getSystemService(Context.CAMERA_SERVICE) as CameraManager
        cameraOptions = discoverCameraOptions()
        selectedCameraIndex = defaultCameraIndex()
        updateCameraControls()
        binding.stopCameraButton.setOnClickListener { finish() }
        binding.nextCameraButton.setOnClickListener {
            if (cameraOptions.isNotEmpty()) {
                selectCamera((selectedCameraIndex + 1) % cameraOptions.size)
            }
        }
        binding.frontCameraButton.setOnClickListener { selectFacing(CameraCharacteristics.LENS_FACING_FRONT) }
        binding.backCameraButton.setOnClickListener { selectFacing(CameraCharacteristics.LENS_FACING_BACK) }
        binding.cameraZoomSlider.addOnChangeListener { _, value, fromUser ->
            if (fromUser) setZoom(value)
        }

        binding.cameraPreview.surfaceTextureListener =
            object : TextureView.SurfaceTextureListener {
                override fun onSurfaceTextureAvailable(surface: SurfaceTexture, width: Int, height: Int) {
                    startCameraWhenReady()
                }

                override fun onSurfaceTextureSizeChanged(surface: SurfaceTexture, width: Int, height: Int) = Unit
                override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean = true
                override fun onSurfaceTextureUpdated(surface: SurfaceTexture) = Unit
            }

        ensureCameraPermission()
    }

    private fun configureEndpoint(intent: Intent?) {
        cameraHost = intent?.getStringExtra(EXTRA_CAMERA_HOST)?.takeIf { it.isNotBlank() } ?: DEFAULT_CAMERA_HOST
        cameraPort = intent?.getIntExtra(EXTRA_CAMERA_PORT, DEFAULT_CAMERA_PORT)
            ?.takeIf { it in 1..65535 }
            ?: DEFAULT_CAMERA_PORT
        val modeLabel = if (cameraHost == DEFAULT_CAMERA_HOST) "USB" else "Wi-Fi"
        binding.cameraTitle.text = "Galaxy Camera · $modeLabel"
    }

    override fun onDestroy() {
        super.onDestroy()
        stopCamera()
        networkExecutor.shutdownNow()
    }

    private fun enableFullscreen() {
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
            window.setDecorFitsSystemWindows(false)
            window.insetsController?.let { controller ->
                controller.hide(WindowInsets.Type.statusBars() or WindowInsets.Type.navigationBars())
                controller.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility =
                android.view.View.SYSTEM_UI_FLAG_FULLSCREEN or
                    android.view.View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                    android.view.View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
        }
    }

    private fun ensureCameraPermission() {
        if (checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            startCameraWhenReady()
        } else {
            cameraPermission.launch(Manifest.permission.CAMERA)
        }
    }

    private fun startCameraWhenReady() {
        if (!binding.cameraPreview.isAvailable) return
        startCameraThread()
        connectToMac()
        openCamera(selectedCameraId())
    }

    private fun startCameraThread() {
        if (cameraThread != null) return
        cameraThread = HandlerThread("GalaxyCamera").also { thread ->
            thread.start()
            cameraHandler = Handler(thread.looper)
        }
    }

    @SuppressLint("MissingPermission")
    private fun openCamera(cameraId: String?) {
        val nextCameraId = cameraId ?: run {
            setStatus("No camera")
            return
        }
        currentCameraId = nextCameraId
        updateCameraCapabilities(nextCameraId)
        val size = chooseOutputSize(nextCameraId)
        val texture = binding.cameraPreview.surfaceTexture ?: return
        texture.setDefaultBufferSize(size.width, size.height)
        previewSurface = Surface(texture)

        imageReader = ImageReader.newInstance(size.width, size.height, ImageFormat.JPEG, 2).apply {
            setOnImageAvailableListener({ reader ->
                val image = reader.acquireLatestImage() ?: return@setOnImageAvailableListener
                try {
                    val buffer = image.planes[0].buffer
                    val bytes = ByteArray(buffer.remaining())
                    buffer.get(bytes)
                    sendFrame(bytes)
                } finally {
                    image.close()
                }
            }, cameraHandler)
        }

        cameraManager.openCamera(
            nextCameraId,
            object : CameraDevice.StateCallback() {
                override fun onOpened(camera: CameraDevice) {
                    cameraDevice = camera
                    createSession(nextCameraId, size)
                }

                override fun onDisconnected(camera: CameraDevice) {
                    camera.close()
                    cameraDevice = null
                    setStatus("Camera disconnected")
                }

                override fun onError(camera: CameraDevice, error: Int) {
                    camera.close()
                    cameraDevice = null
                    setStatus("Camera error: $error")
                }
            },
            cameraHandler,
        )
    }

    private fun createSession(cameraId: String, size: Size) {
        val camera = cameraDevice ?: return
        val preview = previewSurface ?: return
        val readerSurface = imageReader?.surface ?: return
        val targets = listOf(preview, readerSurface)
        val jpegOrientation = calculateJpegOrientation(cameraId)

        camera.createCaptureSession(
            targets,
            object : CameraCaptureSession.StateCallback() {
                override fun onConfigured(session: CameraCaptureSession) {
                    captureSession = session
                    captureRequestBuilder =
                        camera.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
                            addTarget(preview)
                            addTarget(readerSurface)
                            setBaseCaptureOptions(this, jpegOrientation)
                        }
                    updateRepeatingRequest()
                    setStatus("Streaming ${size.width}x${size.height} to Mac")
                }

                override fun onConfigureFailed(session: CameraCaptureSession) {
                    setStatus("Camera session failed")
                }
            },
            cameraHandler,
        )
    }

    private fun setBaseCaptureOptions(builder: CaptureRequest.Builder, jpegOrientation: Int) {
        builder.set(CaptureRequest.JPEG_QUALITY, 70.toByte())
        builder.set(CaptureRequest.JPEG_ORIENTATION, jpegOrientation)
        builder.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
        builder.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
        applyZoom(builder)
    }

    private fun discoverCameraOptions(): List<CameraOption> {
        return cameraManager.cameraIdList.mapNotNull { id ->
            runCatching {
                val characteristics = cameraManager.getCameraCharacteristics(id)
                val facing = characteristics.get(CameraCharacteristics.LENS_FACING)
                CameraOption(id = id, facing = facing, label = cameraLabel(id, characteristics))
            }.getOrNull()
        }
    }

    private fun cameraLabel(id: String, characteristics: CameraCharacteristics): String {
        val facing = characteristics.get(CameraCharacteristics.LENS_FACING)
        val facingLabel =
            when (facing) {
                CameraCharacteristics.LENS_FACING_FRONT -> "Front"
                CameraCharacteristics.LENS_FACING_BACK -> "Back"
                CameraCharacteristics.LENS_FACING_EXTERNAL -> "External"
                else -> "Camera"
            }
        val focalLengths = characteristics.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
        val focal = focalLengths?.minOrNull()
        val type =
            when {
                facing == CameraCharacteristics.LENS_FACING_FRONT -> "Selfie"
                focal == null -> "Lens"
                focal < 2.5f -> "Ultra wide"
                focal > 6.0f -> "Tele"
                else -> "Wide"
            }
        val focalLabel = focal?.let { " · %.1fmm".format(it) } ?: ""
        return "$facingLabel $type #$id$focalLabel"
    }

    private fun defaultCameraIndex(): Int {
        val backIndex = cameraOptions.indexOfFirst { it.facing == CameraCharacteristics.LENS_FACING_BACK }
        return if (backIndex >= 0) backIndex else 0
    }

    private fun selectedCameraId(): String? {
        return cameraOptions.getOrNull(selectedCameraIndex)?.id
    }

    private fun selectFacing(facing: Int) {
        val index = cameraOptions.indexOfFirst { it.facing == facing }
        if (index >= 0) {
            selectCamera(index)
        } else {
            setStatus(if (facing == CameraCharacteristics.LENS_FACING_FRONT) "No front camera" else "No rear camera")
        }
    }

    private fun selectCamera(index: Int) {
        if (cameraOptions.isEmpty()) return
        selectedCameraIndex = index.coerceIn(0, cameraOptions.lastIndex)
        zoomRatio = 1f
        updateCameraControls()
        closeCameraCapture()
        openCamera(selectedCameraId())
    }

    private fun calculateJpegOrientation(cameraId: String): Int {
        val characteristics = cameraManager.getCameraCharacteristics(cameraId)
        val sensorOrientation = characteristics.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0
        val facing = characteristics.get(CameraCharacteristics.LENS_FACING)
        val deviceRotation =
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
                display?.rotation ?: Surface.ROTATION_0
            } else {
                @Suppress("DEPRECATION")
                windowManager.defaultDisplay.rotation
            }
        val deviceDegrees =
            when (deviceRotation) {
                Surface.ROTATION_90 -> 90
                Surface.ROTATION_180 -> 180
                Surface.ROTATION_270 -> 270
                else -> 0
            }

        return if (facing == CameraCharacteristics.LENS_FACING_FRONT) {
            (sensorOrientation + deviceDegrees) % 360
        } else {
            (sensorOrientation - deviceDegrees + 360) % 360
        }
    }

    private fun chooseOutputSize(cameraId: String): Size {
        val characteristics = cameraManager.getCameraCharacteristics(cameraId)
        val map = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        val sizes = map?.getOutputSizes(ImageFormat.JPEG)?.toList().orEmpty()
        return sizes
            .filter { it.width <= 1280 && it.height <= 720 }
            .maxByOrNull { it.width * it.height }
            ?: Size(1280, 720)
    }

    private fun updateCameraCapabilities(cameraId: String) {
        val characteristics = cameraManager.getCameraCharacteristics(cameraId)
        activeArraySize = characteristics.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE)
        maxZoomRatio = characteristics.get(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM) ?: 1f
        zoomRatio = zoomRatio.coerceIn(1f, maxZoomRatio.coerceAtLeast(1f))
        updateCameraControls()
    }

    private fun setZoom(value: Float) {
        zoomRatio = value.coerceIn(1f, maxZoomRatio.coerceAtLeast(1f))
        updateCameraControls()
        updateRepeatingRequest()
    }

    private fun applyZoom(builder: CaptureRequest.Builder) {
        val activeArray = activeArraySize ?: return
        if (zoomRatio <= 1.01f) {
            builder.set(CaptureRequest.SCALER_CROP_REGION, activeArray)
            return
        }

        val cropWidth = (activeArray.width() / zoomRatio).toInt()
        val cropHeight = (activeArray.height() / zoomRatio).toInt()
        val left = activeArray.left + (activeArray.width() - cropWidth) / 2
        val top = activeArray.top + (activeArray.height() - cropHeight) / 2
        builder.set(CaptureRequest.SCALER_CROP_REGION, Rect(left, top, left + cropWidth, top + cropHeight))
    }

    private fun updateRepeatingRequest() {
        val session = captureSession ?: return
        val builder = captureRequestBuilder ?: return
        applyZoom(builder)
        session.setRepeatingRequest(builder.build(), null, cameraHandler)
    }

    private fun updateCameraControls() {
        runOnUiThread {
            val option = cameraOptions.getOrNull(selectedCameraIndex)
            binding.cameraLensText.text = option?.label ?: "Camera"
            val sliderMax = maxZoomRatio.coerceAtLeast(1f).coerceAtMost(MAX_UI_ZOOM)
            binding.cameraZoomSlider.valueFrom = 1f
            binding.cameraZoomSlider.valueTo = maxOf(2f, sliderMax)
            binding.cameraZoomSlider.isEnabled = sliderMax > 1.05f
            binding.cameraZoomSlider.value = zoomRatio.coerceIn(1f, binding.cameraZoomSlider.valueTo)
            binding.cameraZoomText.text = "Zoom %.1fx".format(zoomRatio)
            binding.nextCameraButton.isEnabled = cameraOptions.size > 1
            binding.frontCameraButton.isEnabled =
                cameraOptions.any { it.facing == CameraCharacteristics.LENS_FACING_FRONT }
            binding.backCameraButton.isEnabled =
                cameraOptions.any { it.facing == CameraCharacteristics.LENS_FACING_BACK }
        }
    }

    private fun connectToMac() {
        networkExecutor.execute {
            closeSocket()
            try {
                setStatus("Connecting to $cameraHost:$cameraPort")
                val nextSocket = Socket()
                nextSocket.tcpNoDelay = true
                nextSocket.connect(InetSocketAddress(cameraHost, cameraPort), 3000)
                socket = nextSocket
                output = BufferedOutputStream(nextSocket.getOutputStream())
                setStatus("Connected to $cameraHost:$cameraPort")
            } catch (e: Exception) {
                setStatus("Mac camera receiver not ready: $cameraHost:$cameraPort")
            }
        }
    }

    private fun sendFrame(bytes: ByteArray) {
        if (!sendingFrame.compareAndSet(false, true)) {
            framesDropped += 1
            return
        }

        networkExecutor.execute {
            try {
                val stream = output
                if (stream == null) {
                    framesDropped += 1
                    return@execute
                }
                stream.write((bytes.size ushr 24) and 0xff)
                stream.write((bytes.size ushr 16) and 0xff)
                stream.write((bytes.size ushr 8) and 0xff)
                stream.write(bytes.size and 0xff)
                stream.write(bytes)
                stream.flush()
                framesSent += 1
                maybeUpdateStats()
            } catch (e: Exception) {
                closeSocket()
                setStatus("Camera stream disconnected")
            } finally {
                sendingFrame.set(false)
            }
        }
    }

    private fun maybeUpdateStats() {
        val now = System.currentTimeMillis()
        val elapsed = now - lastStatsAt
        if (elapsed < 1000) return
        val fps = framesSent * 1000f / elapsed
        val dropped = framesDropped
        framesSent = 0
        framesDropped = 0
        lastStatsAt = now
        setStatus(String.format("Streaming to Mac: %.1ffps, dropped %d", fps, dropped))
    }

    private fun stopCamera() {
        closeCameraCapture()
        closeSocket()
        cameraThread?.quitSafely()
        cameraThread = null
        cameraHandler = null
    }

    private fun closeCameraCapture() {
        captureSession?.close()
        captureSession = null
        captureRequestBuilder = null
        cameraDevice?.close()
        cameraDevice = null
        imageReader?.close()
        imageReader = null
        previewSurface?.release()
        previewSurface = null
    }

    private fun closeSocket() {
        try {
            output?.close()
        } catch (_: Exception) {
        }
        try {
            socket?.close()
        } catch (_: Exception) {
        }
        output = null
        socket = null
    }

    private fun setStatus(text: String) {
        runOnUiThread {
            binding.cameraStatusText.text = text
        }
    }
}
