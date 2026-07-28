package com.sidescreen.app

import android.annotation.SuppressLint
import android.app.Dialog
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ActivityInfo
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.hardware.SensorManager
import android.hardware.usb.UsbManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.provider.Settings
import android.view.MotionEvent
import android.view.OrientationEventListener
import android.view.SurfaceHolder
import android.view.View
import android.view.Window
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.constraintlayout.widget.ConstraintLayout
import androidx.constraintlayout.widget.ConstraintSet
import androidx.lifecycle.lifecycleScope
import com.google.android.material.button.MaterialButton
import com.google.android.material.slider.Slider
import com.google.android.material.switchmaterial.SwitchMaterial
import com.sidescreen.app.databinding.ActivityMainBinding
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.hypot
import java.net.InetSocketAddress
import java.net.Socket

private fun mainDiag(msg: String) = DiagLog.log("MA", msg)

private const val MIN_VIEWPORT_SCALE = 1f
private const val MAX_VIEWPORT_SCALE = 4f

class MainActivity : AppCompatActivity() {
    private lateinit var wirelessController: WirelessTabController
    private val pairedHostStorage by lazy { PairedHostStorage(this) }
    private lateinit var binding: ActivityMainBinding
    private lateinit var prefs: PreferencesManager
    private var videoDecoder: VideoDecoder? = null
    private var streamClient: StreamClient? = null
    private var currentSurfaceHolder: SurfaceHolder? = null
    private var displayWidth = 0 // 0 = no config received yet
    private var displayHeight = 0 // 0 = no config received yet
    private var displayRotation = 0 // 0, 90, 180, 270 degrees
    private var wakeLock: PowerManager.WakeLock? = null
    private var pingJob: kotlinx.coroutines.Job? = null

    // For dragging stats overlay
    private var isDraggingOverlay = false
    private var overlayDx = 0f
    private var overlayDy = 0f

    // Local viewport zoom/pan. Two-finger gestures manipulate the Android
    // viewport, while one-finger input remains remote Mac touch input.
    private var viewportScale = 1f
    private var viewportPanX = 0f
    private var viewportPanY = 0f
    private var localGestureActive = false
    private var suppressRemoteUntilAllPointersUp = false
    private var remotePointerActive = false
    private var pinchStartDistance = 0f
    private var pinchLastMidX = 0f
    private var pinchLastMidY = 0f

    // Display rotation from the Mac. Rotation requests recreate the host
    // virtual display, so the client performs one reconnect after requesting it.
    private var reconnectAfterDisplayChange = false
    private var displayChangeReconnectJob: kotlinx.coroutines.Job? = null
    private var lastUsbHost = "127.0.0.1"
    private var lastUsbPort = 54321

    // Input prediction for low-latency gaming
    private val inputPredictor = InputPredictor()

    // Checklist status handler
    private val checklistHandler = Handler(Looper.getMainLooper())
    private var checklistRunnable: Runnable? = null
    private var isConnected = false // Track connection state to prevent checklist conflicts

    // Sensor-driven rotation
    private var orientationListener: OrientationEventListener? = null
    private var candidateRotation: Int? = null
    private var candidateSince = 0L

    // Idle auto-hide for the floating controls
    private val buttonHideHandler = Handler(Looper.getMainLooper())
    private val hideFloatingButtons = Runnable { setFloatingButtonsVisible(false, animated = true) }
    private var floatingButtonsVisible = true

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        DiagLog.init(applicationContext)
        prefs = PreferencesManager(this)

        // Allow rotation based on device sensor when not connected
        requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR

        // Keep screen on
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        wakeAndShowOverLockScreen()

        // Enable edge-to-edge display (draw behind system bars and cutout)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes.layoutInDisplayCutoutMode =
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }

        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        // Apply fullscreen mode immediately
        enableFullscreenMode()

        // Enable performance mode for gaming (after binding is initialized)
        enablePerformanceMode()

        setupSurface()
        setupUI()
        setupDraggableOverlay()
        setupSettingsButton()
        setupRotateButton()
        setupOrientationListener()
        restoreOverlayPosition()
        restoreSettingsButtonPosition()
        startChecklistUpdates()
        setupModeToggle()
        setupWirelessController()
        handlePairingIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        wakeAndShowOverLockScreen()
        enableFullscreenMode()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handlePairingIntent(intent)
    }

    private fun handlePairingIntent(intent: Intent?) {
        val uri = intent?.data ?: return
        if (launchGalaxyCameraIfNeeded(uri)) return

        val pairingUrl = uri.toString()
        if (PairingURL.parse(pairingUrl) == null) return

        if (isConnected) {
            disconnect()
        }
        prefs.connectionMode = ConnectionMode.WIRELESS
        binding.modeToggleGroup.check(R.id.modeWireless)
        applyModeVisibility(ConnectionMode.WIRELESS)
        wirelessController.show()
        wirelessController.onScanResult(pairingUrl)
    }

    private fun launchGalaxyCameraIfNeeded(uri: Uri): Boolean {
        if (uri.scheme != "sidescreen") return false
        if (uri.path?.trim('/') != "camera") return false
        val host = uri.host?.takeIf { it.isNotBlank() } ?: return false
        val port = uri.port.takeIf { it in 1..65535 } ?: 54323
        startActivity(GalaxyCameraActivity.createIntent(this, host, port))
        return true
    }

    private fun wakeAndShowOverLockScreen() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED
                    or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            )
        }
    }

    private fun setupModeToggle() {
        // Restore previous mode and reflect in toggle.
        val saved = prefs.connectionMode
        binding.modeToggleGroup.check(if (saved == ConnectionMode.WIRELESS) R.id.modeWireless else R.id.modeUSB)
        applyModeVisibility(saved)

        binding.modeToggleGroup.addOnButtonCheckedListener { _, checkedId, isChecked ->
            if (!isChecked) return@addOnButtonCheckedListener
            val mode = if (checkedId == R.id.modeWireless) ConnectionMode.WIRELESS else ConnectionMode.USB
            prefs.connectionMode = mode
            applyModeVisibility(mode)
            if (mode == ConnectionMode.WIRELESS) {
                wirelessController.show()
            }
        }
    }

    private fun applyModeVisibility(mode: ConnectionMode) {
        binding.usbModeContent.visibility = if (mode == ConnectionMode.USB) View.VISIBLE else View.GONE
        binding.wirelessModeContent.visibility = if (mode == ConnectionMode.WIRELESS) View.VISIBLE else View.GONE
        // USB checklist polls 127.0.0.1:port every 2s via adb-reverse to verify Mac
        // server reachability. While in Wireless mode that probe creates loopback
        // connections that fight the wireless session for the Mac's single client
        // slot — kicking the wireless client off seconds after it auths. Pause
        // checklist updates whenever Wireless is the active tab.
        if (mode == ConnectionMode.WIRELESS) {
            stopChecklistUpdates()
        } else {
            startChecklistUpdates()
        }
    }

    private fun setupWirelessController() {
        wirelessController =
            WirelessTabController(
                views =
                    WirelessTabController.Views(
                        connecting = binding.wirelessConnecting,
                        firstTime = binding.wirelessFirstTime,
                        connected = binding.wirelessConnected,
                        pairedIdle = binding.wirelessPairedIdle,
                        repair = binding.wirelessTokenMismatch,
                        scanButton = binding.wirelessScanButton,
                        rescanButton = binding.wirelessRescanButton,
                        disconnectButton = binding.wirelessDisconnectButton,
                        forgetButton = binding.wirelessForgetButton,
                        reconnectButton = binding.wirelessReconnectButton,
                        idleForgetButton = binding.wirelessIdleForgetButton,
                        connectedMacName = binding.connectedMacName,
                        connectedMacIp = binding.connectedMacIp,
                        connectingLabel = binding.connectingLabel,
                        connectingSubtitle = binding.connectingSubtitle,
                        idleMacName = binding.idleMacName,
                        idleMacIp = binding.idleMacIp,
                        repairTitle = binding.repairTitle,
                        repairMessage = binding.repairMessage,
                    ),
                storage = pairedHostStorage,
                onConnectRequested = { host, port, token, deviceName, macName ->
                    connectWireless(host, port, token, deviceName, macName)
                },
            )
        wirelessController.bind()
        binding.wirelessDisconnectButton.setOnClickListener { disconnect() }
        if (prefs.connectionMode == ConnectionMode.WIRELESS) {
            wirelessController.show()
        }
    }

    /**
     * Enable performance mode for streaming
     * NOTE: setSustainedPerformanceMode is DISABLED - it causes thermal throttling
     * which makes the entire device laggy. Normal power management is more efficient.
     */
    private fun enablePerformanceMode() {
        try {
            // REMOVED: setSustainedPerformanceMode(true)
            // Sustained performance mode forces max CPU/GPU clocks which causes
            // thermal throttling on extended use, making the device laggy.
            // Let the SoC manage power efficiently instead.

            // Use PARTIAL_WAKE_LOCK with timeout to prevent battery drain
            // Screen is already kept on via FLAG_KEEP_SCREEN_ON
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock =
                powerManager.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "SideScreen::PerformanceMode",
                )
            // 30 minute timeout instead of infinite acquire
            wakeLock?.acquire(30 * 60 * 1000L)

            log("🎮 Performance mode ENABLED (balanced)")
        } catch (e: Exception) {
            log("⚠️ Performance mode failed: ${e.message}")
        }
    }

    /**
     * Enable fullscreen immersive mode
     * Uses modern WindowInsets API on Android R+ for better system compatibility
     * Also handles display cutout (notch) to use full screen area
     */
    private fun enableFullscreenMode() {
        // Ensure we draw behind the cutout
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes.layoutInDisplayCutoutMode =
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.setDecorFitsSystemWindows(false)
            window.insetsController?.let { controller ->
                controller.hide(WindowInsets.Type.statusBars() or WindowInsets.Type.navigationBars())
                controller.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = (
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                    or View.SYSTEM_UI_FLAG_FULLSCREEN
                    or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                    or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                    or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                    or View.SYSTEM_UI_FLAG_LAYOUT_STABLE
            )
        }
    }

    /**
     * Disable fullscreen mode (when disconnected)
     */
    private fun disableFullscreenMode() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.insetsController?.show(WindowInsets.Type.statusBars() or WindowInsets.Type.navigationBars())
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_VISIBLE
        }
    }

    @SuppressLint("ClickableViewAccessibility")
    private fun setupSurface() {
        binding.surfaceView.holder.addCallback(
            object : SurfaceHolder.Callback {
                override fun surfaceCreated(holder: SurfaceHolder) {
                    mainDiag("surfaceCreated")
                    log("Surface created")
                }

                override fun surfaceChanged(
                    holder: SurfaceHolder,
                    format: Int,
                    width: Int,
                    height: Int,
                ) {
                    mainDiag("surfaceChanged: ${width}x$height")
                    log("Surface changed: ${width}x$height")
                    // Don't initialize decoder here — wait for display config
                    // from the server so we use the correct resolution.
                    // Store the holder so we can initialize later.
                    currentSurfaceHolder = holder
                    applyViewportTransform()
                    // If we already have a display config (reconnect case), init now
                    if (displayWidth > 0 && displayHeight > 0 && videoDecoder == null) {
                        initializeDecoder(holder)
                    }
                }

                override fun surfaceDestroyed(holder: SurfaceHolder) {
                    mainDiag("surfaceDestroyed")
                    log("Surface destroyed")
                    // Only release decoder, NOT the connection.
                    videoDecoder?.release()
                    videoDecoder = null
                }
            },
        )

        binding.surfaceView.setOnTouchListener { view, event ->
            if (event.actionMasked == MotionEvent.ACTION_DOWN) noteUserInteraction()
            handleTouch(view, event)
            true
        }
    }

    private fun setupUI() {
        binding.launchGalaxyCameraButton.setOnClickListener {
            startActivity(Intent(this, GalaxyCameraActivity::class.java))
        }

        binding.connectButton.setOnClickListener {
            var host =
                binding.hostInput.text
                    .toString()
                    .ifEmpty { "127.0.0.1" }
            val port =
                binding.portInput.text
                    .toString()
                    .toIntOrNull() ?: 54321

            // Convert localhost to 127.0.0.1 for better Android compatibility
            if (host.equals("localhost", ignoreCase = true)) {
                host = "127.0.0.1"
            }

            // Validate input
            if (host.isBlank()) {
                showError("Please enter a host address")
                return@setOnClickListener
            }

            updateStatus("Connecting...")
            connect(host, port)
        }

        binding.disconnectButton.setOnClickListener {
            disconnect()
        }

        // Advanced settings toggle
        var advancedVisible = false
        binding.showAdvanced.setOnClickListener {
            advancedVisible = !advancedVisible
            binding.advancedSettings.visibility = if (advancedVisible) View.VISIBLE else View.GONE
            binding.showAdvanced.text = if (advancedVisible) "Hide Advanced Settings" else "Advanced Settings"
        }

        // Initial status
        updateStatus("Ready to connect")
    }

    private fun showError(message: String) {
        runOnUiThread {
            android.app.AlertDialog
                .Builder(this)
                .setTitle("Connection Error")
                .setMessage(message)
                .setPositiveButton("OK", null)
                .show()
        }
    }

    private fun updateStatus(status: String) {
        runOnUiThread {
            binding.statusText.text = status
        }
    }

    @SuppressLint("ClickableViewAccessibility", "InflateParams")
    private fun setupDraggableOverlay() {
        binding.statusBar.setOnTouchListener { view, event ->
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    isDraggingOverlay = true
                    overlayDx = view.x - event.rawX
                    overlayDy = view.y - event.rawY
                    true
                }

                MotionEvent.ACTION_MOVE -> {
                    if (isDraggingOverlay) {
                        // Calculate new position
                        var newX = event.rawX + overlayDx
                        var newY = event.rawY + overlayDy

                        // Get screen bounds
                        val parent = view.parent as View
                        val maxX = parent.width - view.width.toFloat()
                        val maxY = parent.height - view.height.toFloat()

                        // Constrain to screen bounds
                        newX = newX.coerceIn(0f, maxX)
                        newY = newY.coerceIn(0f, maxY)

                        view
                            .animate()
                            .x(newX)
                            .y(newY)
                            .setDuration(0)
                            .start()
                    }
                    true
                }

                MotionEvent.ACTION_UP -> {
                    if (isDraggingOverlay) {
                        // Save position
                        prefs.overlayX = view.x
                        prefs.overlayY = view.y
                        isDraggingOverlay = false
                    }
                    true
                }

                else -> {
                    false
                }
            }
        }
    }

    private fun restoreOverlayPosition() {
        val x = prefs.overlayX
        val y = prefs.overlayY

        if (x >= 0 && y >= 0) {
            binding.statusBar.post {
                binding.statusBar.x = x
                binding.statusBar.y = y
            }
        }

        // Apply opacity to both overlay and settings button
        val opacity = prefs.overlayOpacity
        updateOverlayOpacity(opacity)
        updateSettingsButtonOpacity(opacity)

        // Apply visibility
        updateOverlayVisibility(prefs.showStatsOverlay)
    }

    private fun updateOverlayOpacity(opacity: Float) {
        binding.statusBar.alpha = opacity
    }

    private fun updateOverlayVisibility(show: Boolean) {
        if (streamClient != null && show) {
            binding.statusBar.visibility = View.VISIBLE
            // Restore position when showing
            val x = prefs.overlayX
            val y = prefs.overlayY
            if (x >= 0 && y >= 0) {
                binding.statusBar.post {
                    binding.statusBar.x = x
                    binding.statusBar.y = y
                }
            }
        } else {
            binding.statusBar.visibility = View.GONE
        }
    }

    @SuppressLint("InflateParams", "SetTextI18n")
    private fun showSettingsDialog() {
        val dialog = Dialog(this)
        dialog.requestWindowFeature(Window.FEATURE_NO_TITLE)
        dialog.setContentView(R.layout.dialog_settings)
        dialog.window?.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))

        val view = dialog.findViewById<View>(android.R.id.content)
        val showStatsSwitch = view.findViewById<SwitchMaterial>(R.id.showStatsSwitch)
        val autoRotateSwitch = view.findViewById<SwitchMaterial>(R.id.autoRotateSwitch)
        val autoHideButtonsSwitch = view.findViewById<SwitchMaterial>(R.id.autoHideButtonsSwitch)
        val opacitySlider = view.findViewById<Slider>(R.id.opacitySlider)
        val opacityValue = view.findViewById<TextView>(R.id.opacityValue)
        val resetButton = view.findViewById<View>(R.id.resetPositionButton)
        val resetSettingsBtn = view.findViewById<View>(R.id.resetSettingsButton)
        val disconnectButton = view.findViewById<View>(R.id.disconnectSettingsButton)
        val closeButton = view.findViewById<View>(R.id.closeButton)

        // Only show Disconnect when actually streaming. Otherwise the button is
        // a no-op and confuses users into clicking it twice.
        disconnectButton.visibility = if (isConnected) View.VISIBLE else View.GONE

        // Position buttons (8 directions)
        val cornerTopLeft = view.findViewById<MaterialButton>(R.id.cornerTopLeft)
        val cornerTopRight = view.findViewById<MaterialButton>(R.id.cornerTopRight)
        val cornerBottomLeft = view.findViewById<MaterialButton>(R.id.cornerBottomLeft)
        val cornerBottomRight = view.findViewById<MaterialButton>(R.id.cornerBottomRight)
        val positionTopCenter = view.findViewById<MaterialButton>(R.id.positionTopCenter)
        val positionBottomCenter = view.findViewById<MaterialButton>(R.id.positionBottomCenter)
        val positionCenterLeft = view.findViewById<MaterialButton>(R.id.positionCenterLeft)
        val positionCenterRight = view.findViewById<MaterialButton>(R.id.positionCenterRight)

        // Load current settings
        showStatsSwitch.isChecked = prefs.showStatsOverlay
        autoRotateSwitch.isChecked = prefs.autoRotate
        autoHideButtonsSwitch.isChecked = prefs.autoHideButtons

        autoRotateSwitch.setOnCheckedChangeListener { _, checked ->
            prefs.autoRotate = checked
            updateOrientationListenerState()
        }
        autoHideButtonsSwitch.setOnCheckedChangeListener { _, checked ->
            prefs.autoHideButtons = checked
            // Re-arm or cancel the countdown immediately so the switch feels live.
            noteUserInteraction()
        }
        opacitySlider.value = prefs.overlayOpacity
        opacityValue.text = "${(prefs.overlayOpacity * 100).toInt()}%"

        // Highlight current position selection (8 positions)
        // 0=BottomRight, 1=BottomLeft, 2=TopRight, 3=TopLeft
        // 4=TopCenter, 5=BottomCenter, 6=CenterLeft, 7=CenterRight
        fun updatePositionSelection(selectedPosition: Int) {
            val buttons =
                listOf(
                    cornerBottomRight,
                    cornerBottomLeft,
                    cornerTopRight,
                    cornerTopLeft,
                    positionTopCenter,
                    positionBottomCenter,
                    positionCenterLeft,
                    positionCenterRight,
                )
            buttons.forEachIndexed { index, button ->
                if (index == selectedPosition) {
                    button.backgroundTintList =
                        android.content.res.ColorStateList
                            .valueOf(0x334CAF50)
                } else {
                    button.backgroundTintList = null
                }
            }
        }
        updatePositionSelection(prefs.settingsButtonCorner)

        // Setup listeners
        showStatsSwitch.setOnCheckedChangeListener { _, isChecked ->
            prefs.showStatsOverlay = isChecked
            updateOverlayVisibility(isChecked)
        }

        opacitySlider.addOnChangeListener { _, value, _ ->
            prefs.overlayOpacity = value
            updateOverlayOpacity(value)
            updateSettingsButtonOpacity(value)
            opacityValue.text = "${(value * 100).toInt()}%"
        }

        resetButton.setOnClickListener {
            prefs.overlayX = -1f
            prefs.overlayY = -1f
            // Use displayMetrics for reliable positioning
            val dm = resources.displayMetrics
            binding.statusBar
                .animate()
                .x(dm.widthPixels - binding.statusBar.width - 48f)
                .y(48f)
                .setDuration(300)
                .start()
        }

        // Position button listeners (8 directions)
        cornerBottomRight.setOnClickListener {
            prefs.settingsButtonCorner = 0
            updatePositionSelection(0)
            updateSettingsButtonPosition(0)
        }

        cornerBottomLeft.setOnClickListener {
            prefs.settingsButtonCorner = 1
            updatePositionSelection(1)
            updateSettingsButtonPosition(1)
        }

        cornerTopRight.setOnClickListener {
            prefs.settingsButtonCorner = 2
            updatePositionSelection(2)
            updateSettingsButtonPosition(2)
        }

        cornerTopLeft.setOnClickListener {
            prefs.settingsButtonCorner = 3
            updatePositionSelection(3)
            updateSettingsButtonPosition(3)
        }

        positionTopCenter.setOnClickListener {
            prefs.settingsButtonCorner = 4
            updatePositionSelection(4)
            updateSettingsButtonPosition(4)
        }

        positionBottomCenter.setOnClickListener {
            prefs.settingsButtonCorner = 5
            updatePositionSelection(5)
            updateSettingsButtonPosition(5)
        }

        positionCenterLeft.setOnClickListener {
            prefs.settingsButtonCorner = 6
            updatePositionSelection(6)
            updateSettingsButtonPosition(6)
        }

        positionCenterRight.setOnClickListener {
            prefs.settingsButtonCorner = 7
            updatePositionSelection(7)
            updateSettingsButtonPosition(7)
        }

        resetSettingsBtn.setOnClickListener {
            prefs.settingsButtonCorner = 0
            updatePositionSelection(0)
            updateSettingsButtonPosition(0)
        }

        disconnectButton.setOnClickListener {
            dialog.dismiss()
            disconnect()
        }

        closeButton.setOnClickListener {
            dialog.dismiss()
        }

        dialog.show()

        // Cap dialog height to 85% of screen so content scrolls on smaller screens / landscape
        dialog.window?.let { win ->
            val maxH = (resources.displayMetrics.heightPixels * 0.85).toInt()
            win.setLayout(WindowManager.LayoutParams.MATCH_PARENT, maxH)
        }
    }

    private fun updateSettingsButtonOpacity(opacity: Float) {
        binding.settingsButton.alpha = opacity
    }

    private fun setupSettingsButton() {
        // Simple click to show settings dialog
        // Position can be changed via corner buttons in settings
        binding.settingsButton.setOnClickListener {
            showSettingsDialog()
        }
    }

    private fun setupRotateButton() {
        binding.rotateButton.setOnClickListener {
            requestHostOrientationToggle()
        }
    }

    private fun requestHostOrientationToggle() {
        val nextRotation =
            when (displayRotation) {
                90, 270 -> 0
                else -> 90
            }
        requestHostRotation(nextRotation, reason = "button")
    }

    /**
     * Ask the Mac to rotate the virtual display.
     *
     * The host destroys and recreates the display for this, so the client drops and
     * reconnects afterwards — several seconds of black screen. Every caller funnels
     * through here so that cost is paid at most once per actual orientation change.
     */
    private fun requestHostRotation(
        rotation: Int,
        reason: String,
    ) {
        if (!isConnected) return
        if (rotation == displayRotation) return
        if (reconnectAfterDisplayChange) {
            mainDiag("Rotation to $rotation ignored ($reason) — a display change is already in flight")
            return
        }
        reconnectAfterDisplayChange = true
        updateStatus("Rotating display...")
        streamClient?.sendRotationRequest(rotation)
        log("Rotation requested ($reason): ${if (rotation == 90) "Portrait" else "Landscape"}")
    }

    /**
     * Watches the physical device angle and mirrors it onto the host display.
     *
     * The activity locks its own orientation while streaming, so the usual
     * configuration-change route never fires; OrientationEventListener reports the
     * raw sensor angle regardless of that lock. A candidate orientation has to hold
     * still for [ORIENTATION_SETTLE_MS] before it counts, because the host pays a
     * full display rebuild per change and a wobble must not trigger one.
     */
    private fun setupOrientationListener() {
        orientationListener =
            object : OrientationEventListener(this, SensorManager.SENSOR_DELAY_NORMAL) {
                override fun onOrientationChanged(degrees: Int) {
                    if (degrees == ORIENTATION_UNKNOWN) return
                    if (!prefs.autoRotate || !isConnected) {
                        candidateRotation = null
                        return
                    }

                    // Collapse the angle to the two orientations the host supports,
                    // ignoring the ±30° band around each boundary so a tablet held
                    // near 45° does not flip-flop.
                    val target =
                        when {
                            degrees >= 330 || degrees < 30 -> 90 // upright
                            degrees in 60..119 -> 0 // rotated left
                            degrees in 150..209 -> 90 // upside down, still portrait
                            degrees in 240..299 -> 0 // rotated right
                            else -> return
                        }

                    if (target == displayRotation) {
                        candidateRotation = null
                        return
                    }
                    val now = SystemClock.elapsedRealtime()
                    if (candidateRotation != target) {
                        candidateRotation = target
                        candidateSince = now
                        return
                    }
                    if (now - candidateSince < ORIENTATION_SETTLE_MS) return

                    candidateRotation = null
                    requestHostRotation(target, reason = "sensor")
                }
            }
    }

    private fun updateOrientationListenerState() {
        val listener = orientationListener ?: return
        if (prefs.autoRotate && isConnected && listener.canDetectOrientation()) {
            listener.enable()
        } else {
            listener.disable()
            candidateRotation = null
        }
    }

    /**
     * Fade the floating controls out when they are not being used. They sit on top of
     * the stream, so leaving them up permanently costs picture area for no benefit.
     * Hidden buttons go INVISIBLE rather than merely transparent, so taps in that area
     * reach the stream underneath instead of hitting an invisible target.
     */
    private fun setFloatingButtonsVisible(
        visible: Boolean,
        animated: Boolean,
    ) {
        if (floatingButtonsVisible == visible) return
        floatingButtonsVisible = visible
        val buttons = listOf(binding.settingsButton, binding.rotateButton)
        buttons.forEach { button ->
            if (!animated) {
                button.alpha = if (visible) 1f else 0f
                button.visibility = if (visible) View.VISIBLE else View.INVISIBLE
                return@forEach
            }
            if (visible) {
                button.visibility = View.VISIBLE
                button.animate().alpha(1f).setDuration(BUTTON_FADE_MS).start()
            } else {
                button.animate().alpha(0f).setDuration(BUTTON_FADE_MS)
                    .withEndAction { button.visibility = View.INVISIBLE }
                    .start()
            }
        }
    }

    /** Reveal the controls and restart the idle countdown. */
    private fun noteUserInteraction() {
        buttonHideHandler.removeCallbacks(hideFloatingButtons)
        setFloatingButtonsVisible(true, animated = true)
        if (prefs.autoHideButtons) {
            buttonHideHandler.postDelayed(hideFloatingButtons, BUTTON_IDLE_TIMEOUT_MS)
        }
    }

    private fun scheduleReconnectAfterDisplayChange(mode: ConnectionMode) {
        displayChangeReconnectJob?.cancel()
        displayChangeReconnectJob =
            lifecycleScope.launch(Dispatchers.IO) {
                // The Mac recreates the virtual display after a rotation request.
                // Waiting here avoids reconnecting to the listener while it is
                // still being torn down, which can leave USB connected with no
                // display config/video frames.
                delay(6500)

                repeat(3) { attempt ->
                    if (isConnected && displayWidth > 0 && displayHeight > 0) return@launch

                    runOnUiThread {
                        if (isConnected && (displayWidth <= 0 || displayHeight <= 0)) {
                            disconnect()
                        }
                        if (!isConnected) {
                            updateStatus("Reconnecting after display change...")
                            when (mode) {
                                ConnectionMode.WIRELESS -> {
                                    val entry = pairedHostStorage.load()
                                    if (entry == null) {
                                        wirelessController.show()
                                    } else {
                                        val deviceName = (Build.MODEL ?: "Android").take(64)
                                        connectWireless(entry.host, entry.port, entry.token, deviceName, entry.macName)
                                    }
                                }
                                ConnectionMode.USB -> connect(lastUsbHost, lastUsbPort)
                            }
                        }
                    }

                    delay(if (attempt == 0) 5000 else 3500)
                }
            }
    }

    private fun restoreSettingsButtonPosition() {
        updateSettingsButtonPosition(prefs.settingsButtonCorner)
    }

    /**
     * Use ConstraintSet to position settings button - most reliable method
     * Works correctly with orientation changes
     * Supports 8 positions: 4 corners + 4 edges
     */
    private fun updateSettingsButtonPosition(position: Int) {
        val constraintLayout = binding.root as ConstraintLayout
        val constraintSet = ConstraintSet()
        constraintSet.clone(constraintLayout)

        val buttonId = binding.settingsButton.id
        val marginDp = (24 * resources.displayMetrics.density).toInt()

        // Clear all constraints first
        constraintSet.clear(buttonId, ConstraintSet.TOP)
        constraintSet.clear(buttonId, ConstraintSet.BOTTOM)
        constraintSet.clear(buttonId, ConstraintSet.START)
        constraintSet.clear(buttonId, ConstraintSet.END)

        when (position) {
            0 -> { // Bottom Right (default)
                constraintSet.connect(
                    buttonId,
                    ConstraintSet.BOTTOM,
                    ConstraintSet.PARENT_ID,
                    ConstraintSet.BOTTOM,
                    marginDp,
                )
                constraintSet.connect(buttonId, ConstraintSet.END, ConstraintSet.PARENT_ID, ConstraintSet.END, marginDp)
            }

            1 -> { // Bottom Left
                constraintSet.connect(
                    buttonId,
                    ConstraintSet.BOTTOM,
                    ConstraintSet.PARENT_ID,
                    ConstraintSet.BOTTOM,
                    marginDp,
                )
                constraintSet.connect(
                    buttonId,
                    ConstraintSet.START,
                    ConstraintSet.PARENT_ID,
                    ConstraintSet.START,
                    marginDp,
                )
            }

            2 -> { // Top Right
                constraintSet.connect(buttonId, ConstraintSet.TOP, ConstraintSet.PARENT_ID, ConstraintSet.TOP, marginDp)
                constraintSet.connect(buttonId, ConstraintSet.END, ConstraintSet.PARENT_ID, ConstraintSet.END, marginDp)
            }

            3 -> { // Top Left
                constraintSet.connect(buttonId, ConstraintSet.TOP, ConstraintSet.PARENT_ID, ConstraintSet.TOP, marginDp)
                constraintSet.connect(
                    buttonId,
                    ConstraintSet.START,
                    ConstraintSet.PARENT_ID,
                    ConstraintSet.START,
                    marginDp,
                )
            }

            4 -> { // Top Center
                constraintSet.connect(buttonId, ConstraintSet.TOP, ConstraintSet.PARENT_ID, ConstraintSet.TOP, marginDp)
                constraintSet.connect(buttonId, ConstraintSet.START, ConstraintSet.PARENT_ID, ConstraintSet.START, 0)
                constraintSet.connect(buttonId, ConstraintSet.END, ConstraintSet.PARENT_ID, ConstraintSet.END, 0)
            }

            5 -> { // Bottom Center
                constraintSet.connect(
                    buttonId,
                    ConstraintSet.BOTTOM,
                    ConstraintSet.PARENT_ID,
                    ConstraintSet.BOTTOM,
                    marginDp,
                )
                constraintSet.connect(buttonId, ConstraintSet.START, ConstraintSet.PARENT_ID, ConstraintSet.START, 0)
                constraintSet.connect(buttonId, ConstraintSet.END, ConstraintSet.PARENT_ID, ConstraintSet.END, 0)
            }

            6 -> { // Center Left
                constraintSet.connect(buttonId, ConstraintSet.TOP, ConstraintSet.PARENT_ID, ConstraintSet.TOP, 0)
                constraintSet.connect(buttonId, ConstraintSet.BOTTOM, ConstraintSet.PARENT_ID, ConstraintSet.BOTTOM, 0)
                constraintSet.connect(
                    buttonId,
                    ConstraintSet.START,
                    ConstraintSet.PARENT_ID,
                    ConstraintSet.START,
                    marginDp,
                )
            }

            7 -> { // Center Right
                constraintSet.connect(buttonId, ConstraintSet.TOP, ConstraintSet.PARENT_ID, ConstraintSet.TOP, 0)
                constraintSet.connect(buttonId, ConstraintSet.BOTTOM, ConstraintSet.PARENT_ID, ConstraintSet.BOTTOM, 0)
                constraintSet.connect(buttonId, ConstraintSet.END, ConstraintSet.PARENT_ID, ConstraintSet.END, marginDp)
            }

            else -> { // Default to bottom right
                constraintSet.connect(
                    buttonId,
                    ConstraintSet.BOTTOM,
                    ConstraintSet.PARENT_ID,
                    ConstraintSet.BOTTOM,
                    marginDp,
                )
                constraintSet.connect(buttonId, ConstraintSet.END, ConstraintSet.PARENT_ID, ConstraintSet.END, marginDp)
            }
        }

        // Reset any absolute positioning that might have been set
        binding.settingsButton.translationX = 0f
        binding.settingsButton.translationY = 0f

        constraintSet.applyTo(constraintLayout)
    }

    private fun initializeDecoder(holder: SurfaceHolder) {
        mainDiag(
            "initializeDecoder called, surface=${holder.surface}, " +
                "valid=${holder.surface.isValid}, res=${displayWidth}x$displayHeight",
        )
        if (displayWidth <= 0 || displayHeight <= 0) {
            mainDiag("initializeDecoder skipped — no display config yet")
            return
        }
        try {
            // Pass display for vsync-aligned frame presentation
            // Use modern API on Android R+, fallback to deprecated for older versions
            val displayObj =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    display // Activity.getDisplay() - modern API
                } else {
                    @Suppress("DEPRECATION")
                    windowManager.defaultDisplay
                }
            videoDecoder = VideoDecoder(holder.surface, displayObj, displayWidth, displayHeight)
            // Wire up buffer release callback
            videoDecoder?.onFrameDecoded = { buffer ->
                streamClient?.releaseBuffer(buffer)
            }
            videoDecoder?.onKeyframeRequired = { force, reason ->
                streamClient?.requestKeyframe(force = force, reason = reason)
            }
            streamClient?.requestKeyframe(force = true, reason = "decoder initialized")
            mainDiag("Decoder initialized OK ${displayWidth}x$displayHeight, videoDecoder=$videoDecoder")
            log("✅ Decoder initialized ${displayWidth}x$displayHeight (${displayObj?.refreshRate ?: 60f}Hz)")
        } catch (e: Exception) {
            mainDiag("Decoder init FAILED: ${e.message}")
            log("❌ Failed to initialize decoder: ${e.message}")
        }
    }

    /**
     * Wire up all StreamClient callbacks. Used by both USB connect() and wireless connectWireless().
     */
    private fun setupStreamClientCallbacks() {
        streamClient?.onFrameReceived = { frameData, frameSize, timestamp, isKeyframe ->
            val dec = videoDecoder
            if (dec != null) {
                dec.decode(frameData, frameSize, timestamp, isKeyframe)
            } else {
                mainDiag("FRAME DROPPED: videoDecoder is null!")
                streamClient?.releaseBuffer(frameData)
            }
        }

        videoDecoder?.onFrameDecoded = { buffer ->
            streamClient?.releaseBuffer(buffer)
        }

        streamClient?.onLatencyMeasured = { rttMs ->
            runOnUiThread {
                binding.latencyText.text = String.format("%.1f ms", rttMs)
            }
        }

        streamClient?.onConnectionStatus = { connected ->
            runOnUiThread {
                isConnected = connected
                updateOrientationListenerState()
                if (connected) {
                    updateStatus("Connected - Streaming active")
                    // Start the idle countdown so the controls clear the picture once
                    // the user stops interacting.
                    noteUserInteraction()
                } else {
                    updateStatus("Disconnected")
                    buttonHideHandler.removeCallbacks(hideFloatingButtons)
                    setFloatingButtonsVisible(true, animated = false)
                }
                binding.connectButton.isEnabled = !connected
                binding.disconnectButton.isEnabled = connected
                binding.statusIndicator.setBackgroundResource(
                    if (connected) android.R.color.holo_green_light else android.R.color.holo_red_light,
                )
                if (connected) {
                    startPingTimer()
                    stopChecklistUpdates()
                    enableFullscreenMode()
                    binding.settingsPanel.visibility = View.GONE
                    binding.settingsButton.visibility = View.VISIBLE
                    binding.rotateButton.visibility = View.VISIBLE
                    restoreSettingsButtonPosition()
                    updateOverlayVisibility(prefs.showStatsOverlay)
                    // For wireless mode, transition controller to CONNECTED here —
                    // not in MainActivity.connectWireless's coroutine after the
                    // receive loop returns (that runs AFTER disconnect, causing
                    // a stale CONNECTED transition that hides the PAIRED_IDLE UI).
                    if (prefs.connectionMode == ConnectionMode.WIRELESS) {
                        val entry = pairedHostStorage.load()
                        wirelessController.onConnectSuccess(
                            entry?.macName ?: "Mac",
                            entry?.host ?: "—",
                        )
                    }
                } else {
                    stopPingTimer()
                    disableFullscreenMode()
                    resetOrientationToSensor()
                    binding.settingsPanel.visibility = View.VISIBLE
                    binding.settingsButton.visibility = View.GONE
                    binding.rotateButton.visibility = View.GONE
                    binding.statusBar.visibility = View.GONE
                    resetViewportTransform()
                    val mode = prefs.connectionMode
                    if (reconnectAfterDisplayChange) {
                        reconnectAfterDisplayChange = false
                        scheduleReconnectAfterDisplayChange(mode)
                    }
                    val willTransition = mode == ConnectionMode.WIRELESS
                    android.util.Log.i(
                        "MainActivity",
                        "onConnectionStatus(false) — mode=$mode, willTransition=$willTransition",
                    )
                    if (mode == ConnectionMode.WIRELESS) {
                        // Don't restart checklist (it conflicts with wireless on Mac).
                        // Tell wireless controller to show the idle/reconnect UI.
                        wirelessController.onStreamDisconnected()
                    } else {
                        log("📋 Restarting checklist updates")
                        startChecklistUpdates()
                    }
                }
            }
        }

        streamClient?.onDisplaySize = { width, height, rotation ->
            mainDiag("onDisplaySize: ${width}x$height @ $rotation°")
            displayWidth = width
            displayHeight = height
            displayRotation = rotation
            if (videoDecoder != null) {
                videoDecoder?.updateResolution(width, height)
            } else {
                val holder = currentSurfaceHolder
                if (holder != null && holder.surface.isValid) {
                    mainDiag("Display config arrived, initializing decoder ${width}x$height")
                    runOnUiThread {
                        if (videoDecoder == null) {
                            initializeDecoder(holder)
                        }
                    }
                } else {
                    mainDiag("Display config arrived but no valid surface yet")
                }
            }
            runOnUiThread {
                binding.resolutionText.text = "${width}x$height"
                applyRotation(rotation)
            }
            log("Display: ${width}x$height @ $rotation°")
        }

        streamClient?.onStats = { fps, mbps ->
            runOnUiThread {
                binding.fpsText.text = String.format("%.1f", fps)
                binding.bitrateText.text = String.format("%.1f Mbps", mbps)
            }
        }
    }

    private fun connectWireless(
        host: String,
        port: Int,
        token: ByteArray,
        deviceName: String,
        macName: String,
    ) {
        lifecycleScope.launch(Dispatchers.IO) {
            try {
                log("Connecting wirelessly to $host:$port...")
                streamClient = StreamClient(host, port, applicationContext)
                setupStreamClientCallbacks()
                streamClient?.connectWireless(token, deviceName)
                // NOTE: onConnectSuccess is fired from the onConnectionStatus(true)
                // listener (above) right after handshake OK — not here. This line
                // would otherwise run AFTER the receive loop exits, i.e. AFTER
                // disconnect, incorrectly transitioning back to CONNECTED.
            } catch (e: StreamClient.WirelessConnectError) {
                runOnUiThread {
                    wirelessController.onConnectError(e)
                }
            } catch (e: Exception) {
                log("Wireless connect failed: ${e.message}")
                runOnUiThread {
                    wirelessController.onConnectError(StreamClient.WirelessConnectError.NetworkUnreachable)
                }
            }
        }
    }

    private fun connect(
        host: String,
        port: Int,
    ) {
        lastUsbHost = host
        lastUsbPort = port
        lifecycleScope.launch(Dispatchers.IO) {
            try {
                log("Connecting to $host:$port...")

                streamClient = StreamClient(host, port)
                setupStreamClientCallbacks()
                streamClient?.connect()
            } catch (e: Exception) {
                val errorMessage =
                    when {
                        e.message?.contains("ECONNREFUSED") == true -> {
                            "Mac server is not running.\n\nPlease start Side Screen.app on your Mac first."
                        }

                        e.message?.contains("Network is unreachable") == true -> {
                            "Cannot reach Mac.\n\n" +
                                "Make sure both devices are connected via USB cable and ADB reverse is configured."
                        }

                        e.message?.contains("timeout") == true -> {
                            "Connection timeout.\n\nCheck if Mac firewall is blocking port $port."
                        }

                        else -> {
                            "Connection failed: ${e.message}\n\n" +
                                "Try:\n• Start Side Screen.app on Mac\n" +
                                "• Check USB connection\n• Run: adb reverse tcp:$port tcp:$port"
                        }
                    }
                updateStatus("Connection failed")
                showError(errorMessage)
            }
        }
    }

    private fun disconnect() {
        stopPingTimer()
        streamClient?.disconnect()
        // Reset display config so next connect defers decoder init until config arrives
        displayWidth = 0
        displayHeight = 0
        log("Disconnected")
    }

    private fun startPingTimer() {
        stopPingTimer()
        pingJob =
            lifecycleScope.launch(Dispatchers.IO) {
                while (true) {
                    kotlinx.coroutines.delay(1000) // Ping every 1 second
                    streamClient?.sendPing()
                }
            }
    }

    private fun stopPingTimer() {
        pingJob?.cancel()
        pingJob = null
    }

    private fun cleanup() {
        try {
            disconnect()
            videoDecoder?.release()
            videoDecoder = null

            // Release wake lock safely
            try {
                if (wakeLock?.isHeld == true) {
                    wakeLock?.release()
                }
            } catch (e: Exception) {
                // Ignore wake lock release errors
            }
            wakeLock = null
            log("🎮 Performance mode DISABLED")
        } catch (e: Exception) {
            log("⚠️ Cleanup error: ${e.message}")
        }
    }

    private fun handleTouch(
        view: View,
        event: MotionEvent,
    ) {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                if (suppressRemoteUntilAllPointersUp) return
                val (x, y) = mapTouchToDisplay(view, event, 0)
                inputPredictor.reset()
                inputPredictor.addSample(x, y)
                streamClient?.sendTouch(x, y, 0, 1)
                remotePointerActive = true
            }

            MotionEvent.ACTION_POINTER_DOWN -> {
                if (event.pointerCount >= 2) {
                    if (remotePointerActive) {
                        val (x, y) = mapTouchToDisplay(view, event, 0)
                        streamClient?.sendTouch(x, y, 2, 1)
                        remotePointerActive = false
                    }
                    inputPredictor.reset()
                    beginLocalGesture(event)
                }
            }

            MotionEvent.ACTION_MOVE -> {
                if (localGestureActive && event.pointerCount >= 2) {
                    updateLocalGesture(view, event)
                } else if (!suppressRemoteUntilAllPointersUp && event.pointerCount == 1) {
                    val (x, y) = mapTouchToDisplay(view, event, 0)
                    inputPredictor.addSample(x, y)
                    val (px, py) = inputPredictor.predictPosition(12f)
                    streamClient?.sendTouch(px, py, 1, 1)
                }
            }

            MotionEvent.ACTION_UP -> {
                inputPredictor.reset()
                if (localGestureActive || suppressRemoteUntilAllPointersUp) {
                    endLocalGesture()
                } else {
                    val (x, y) = mapTouchToDisplay(view, event, 0)
                    streamClient?.sendTouch(x, y, 2, 1)
                }
                remotePointerActive = false
            }

            MotionEvent.ACTION_POINTER_UP -> {
                if (localGestureActive) {
                    suppressRemoteUntilAllPointersUp = true
                    if (event.pointerCount <= 2) {
                        localGestureActive = false
                    }
                }
            }

            MotionEvent.ACTION_CANCEL -> {
                inputPredictor.reset()
                if (remotePointerActive) {
                    val (x, y) = mapTouchToDisplay(view, event, 0)
                    streamClient?.sendTouch(x, y, 2, 1)
                }
                endLocalGesture()
                remotePointerActive = false
            }
        }
    }

    private fun beginLocalGesture(event: MotionEvent) {
        localGestureActive = true
        suppressRemoteUntilAllPointersUp = true
        pinchStartDistance = distanceBetweenFirstTwoPointers(event).coerceAtLeast(1f)
        val (midX, midY) = midpointOfFirstTwoPointers(event)
        pinchLastMidX = midX
        pinchLastMidY = midY
    }

    private fun updateLocalGesture(
        view: View,
        event: MotionEvent,
    ) {
        val distance = distanceBetweenFirstTwoPointers(event).coerceAtLeast(1f)
        val (midX, midY) = midpointOfFirstTwoPointers(event)

        val previousScale = viewportScale
        val scaleFactor = distance / pinchStartDistance
        val nextScale = (viewportScale * scaleFactor).coerceIn(MIN_VIEWPORT_SCALE, MAX_VIEWPORT_SCALE)

        if (nextScale != previousScale) {
            val ratio = nextScale / previousScale
            viewportPanX = midX - (midX - viewportPanX) * ratio
            viewportPanY = midY - (midY - viewportPanY) * ratio
            viewportScale = nextScale
        }

        if (viewportScale > MIN_VIEWPORT_SCALE) {
            viewportPanX += midX - pinchLastMidX
            viewportPanY += midY - pinchLastMidY
        }

        pinchStartDistance = distance
        pinchLastMidX = midX
        pinchLastMidY = midY
        clampViewportPan(view)
        applyViewportTransform()
    }

    private fun endLocalGesture() {
        localGestureActive = false
        suppressRemoteUntilAllPointersUp = false
        pinchStartDistance = 0f
    }

    private fun mapTouchToDisplay(
        view: View,
        event: MotionEvent,
        pointerIndex: Int,
    ): Pair<Float, Float> {
        val contentX = ((event.getX(pointerIndex) - viewportPanX) / viewportScale).coerceIn(0f, view.width.toFloat())
        val contentY = ((event.getY(pointerIndex) - viewportPanY) / viewportScale).coerceIn(0f, view.height.toFloat())
        return Pair(contentX / view.width.toFloat(), contentY / view.height.toFloat())
    }

    private fun distanceBetweenFirstTwoPointers(event: MotionEvent): Float {
        return hypot(event.getX(1) - event.getX(0), event.getY(1) - event.getY(0))
    }

    private fun midpointOfFirstTwoPointers(event: MotionEvent): Pair<Float, Float> {
        return Pair((event.getX(0) + event.getX(1)) / 2f, (event.getY(0) + event.getY(1)) / 2f)
    }

    private fun resetViewportTransform() {
        viewportScale = MIN_VIEWPORT_SCALE
        viewportPanX = 0f
        viewportPanY = 0f
        localGestureActive = false
        suppressRemoteUntilAllPointersUp = false
        remotePointerActive = false
        applyViewportTransform()
    }

    private fun clampViewportPan(view: View = binding.surfaceView) {
        if (viewportScale <= MIN_VIEWPORT_SCALE || view.width <= 0 || view.height <= 0) {
            viewportScale = MIN_VIEWPORT_SCALE
            viewportPanX = 0f
            viewportPanY = 0f
            return
        }

        val minPanX = view.width - view.width * viewportScale
        val minPanY = view.height - view.height * viewportScale
        viewportPanX = viewportPanX.coerceIn(minPanX, 0f)
        viewportPanY = viewportPanY.coerceIn(minPanY, 0f)
    }

    private fun applyViewportTransform() {
        binding.surfaceView.apply {
            pivotX = 0f
            pivotY = 0f
            scaleX = viewportScale
            scaleY = viewportScale
            translationX = viewportPanX
            translationY = viewportPanY
        }
    }

    /**
     * Apply rotation by changing the Activity's screen orientation
     * This provides proper fullscreen portrait/landscape support
     */
    private fun applyRotation(rotation: Int) {
        requestedOrientation =
            when (rotation) {
                90 -> ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                180 -> ActivityInfo.SCREEN_ORIENTATION_REVERSE_LANDSCAPE
                270 -> ActivityInfo.SCREEN_ORIENTATION_REVERSE_PORTRAIT
                else -> ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE // 0°
            }

        resetViewportTransform()

        // ConstraintSet handles orientation changes automatically
        // No need for postDelayed positioning

        log(
            "🔄 Orientation: ${when (rotation) {
                90 -> "Portrait"
                180 -> "Landscape (flipped)"
                270 -> "Portrait (flipped)"
                else -> "Landscape"
            }}",
        )
    }

    /**
     * Reset orientation to follow device sensor (when disconnected)
     */
    private fun resetOrientationToSensor() {
        requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR
    }

    private fun log(message: String) {
        runOnUiThread {
            val current = binding.logText.text.toString()
            val lines = current.split("\n").takeLast(5)
            binding.logText.text = (lines + message).joinToString("\n")
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        stopChecklistUpdates()
        orientationListener?.disable()
        buttonHideHandler.removeCallbacks(hideFloatingButtons)
        cleanup()
    }

    // ==================== Connection Checklist ====================

    private fun startChecklistUpdates() {
        // Stop any existing runnable first to prevent duplicates
        checklistRunnable?.let {
            checklistHandler.removeCallbacks(it)
        }

        checklistRunnable =
            object : Runnable {
                override fun run() {
                    updateChecklist()
                    checklistHandler.postDelayed(this, 2000) // Update every 2 seconds
                }
            }
        checklistHandler.post(checklistRunnable!!)
    }

    private fun stopChecklistUpdates() {
        checklistRunnable?.let {
            checklistHandler.removeCallbacks(it)
            checklistRunnable = null
        }
    }

    private fun updateChecklist() {
        // Skip if connected (to prevent socket conflicts)
        if (isConnected) return

        // Check Developer Mode (if we can run this app with USB debugging, dev mode is enabled)
        val isDeveloperModeEnabled =
            Settings.Secure.getInt(
                contentResolver,
                Settings.Global.DEVELOPMENT_SETTINGS_ENABLED,
                0,
            ) == 1
        updateChecklistItem(binding.checkDeveloperMode, isDeveloperModeEnabled)

        // Check USB Debugging (ADB enabled)
        val isAdbEnabled =
            Settings.Secure.getInt(
                contentResolver,
                Settings.Global.ADB_ENABLED,
                0,
            ) == 1
        updateChecklistItem(binding.checkUsbDebugging, isAdbEnabled)

        // Check USB connected (check if any USB device is connected)
        val usbManager = getSystemService(Context.USB_SERVICE) as UsbManager
        val isUsbConnected = usbManager.deviceList.isNotEmpty() || isCharging()
        updateChecklistItem(binding.checkUsbConnected, isUsbConnected)

        // Check Mac Server without touching the single-client video stream.
        lifecycleScope.launch(Dispatchers.IO) {
            // Double-check connection state before socket test
            if (isConnected) return@launch

            val port =
                binding.portInput.text
                    .toString()
                    .toIntOrNull() ?: 54321
            val isServerRunning = checkServerRunning("127.0.0.1", healthPortFor(port))
            runOnUiThread {
                // Final check before updating UI
                if (isConnected) return@runOnUiThread

                updateChecklistItem(binding.checkMacServer, isServerRunning)

                // Update main status indicator based on all checklist items
                val allReady = isDeveloperModeEnabled && isAdbEnabled && isUsbConnected && isServerRunning
                updateMainStatus(allReady)
            }
        }
    }

    private fun updateMainStatus(allReady: Boolean) {
        binding.statusIndicator.setBackgroundResource(
            if (allReady) {
                R.drawable.status_indicator_green
            } else {
                R.drawable.status_indicator_red
            },
        )
        binding.statusText.text = if (allReady) "Ready to connect" else "Not ready to connect"
    }

    private fun updateChecklistItem(
        indicator: View,
        isOk: Boolean,
    ) {
        indicator.setBackgroundResource(
            if (isOk) {
                R.drawable.status_indicator_green
            } else {
                R.drawable.status_indicator_red
            },
        )
    }

    private fun isCharging(): Boolean {
        val intentFilter = IntentFilter(Intent.ACTION_BATTERY_CHANGED)
        val batteryStatus = registerReceiver(null, intentFilter)
        val status = batteryStatus?.getIntExtra(android.os.BatteryManager.EXTRA_STATUS, -1) ?: -1
        return status == android.os.BatteryManager.BATTERY_STATUS_CHARGING ||
            status == android.os.BatteryManager.BATTERY_STATUS_FULL
    }

    /**
     * Check if Mac server is actually running (not just ADB reverse) via the
     * browser/health port. Never probe the video stream port here: the Mac
     * stream server intentionally allows one native client, so a readiness
     * probe on that port can kick off the real display session.
     *
     * Problem: When `adb reverse tcp:8888 tcp:8888` is active, ADB daemon listens on port 8888.
     * A simple socket connect will succeed to ADB daemon, not the actual Mac server.
     *
     * Solution: Request /health on the HTTP browser server. ADB daemon doesn't
     * send a valid HTTP response, so read will timeout or fail → false.
     */
    private fun checkServerRunning(
        host: String,
        port: Int,
    ): Boolean {
        var socket: Socket? = null
        return try {
            socket = Socket()
            socket.connect(InetSocketAddress(host, port), 300) // 300ms connect timeout
            socket.soTimeout = 300 // 300ms read timeout

            socket.getOutputStream().write(
                "GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
                    .toByteArray(Charsets.US_ASCII),
            )
            socket.getOutputStream().flush()

            val input = socket.getInputStream()
            val buffer = ByteArray(96)
            val read = input.read(buffer) // Blocks up to soTimeout

            if (read <= 0) return false
            val response = String(buffer, 0, read, Charsets.US_ASCII)
            response.startsWith("HTTP/1.1 200") || response.contains("\r\n\r\nok")
        } catch (e: Exception) {
            // Timeout, connection refused, or other error = server not running
            false
        } finally {
            try {
                socket?.close()
            } catch (e: Exception) {
                // ignore
            }
        }
    }

    private fun healthPortFor(streamPort: Int): Int = if (streamPort < 65535) streamPort + 1 else streamPort - 1

    companion object {
        /** How long a new orientation must hold before the host is asked to rotate. */
        private const val ORIENTATION_SETTLE_MS = 1_500L

        /** Idle time before the floating controls fade away. */
        private const val BUTTON_IDLE_TIMEOUT_MS = 4_000L
        private const val BUTTON_FADE_MS = 250L
    }
}
