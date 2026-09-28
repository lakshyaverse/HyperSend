package com.hypersend.app

import android.Manifest
import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.Typeface
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.IBinder
import android.provider.OpenableColumns
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/**
 * HyperSend for Android — the connector.
 *
 * Not a form with a button. The app is three layers deep:
 *
 *   chrome  — a glass header, a glass dock, and a sky behind both. The Mac's
 *             window, translated to a phone's proportions.
 *   screens — Home / Received / Settings, each an independently built tree,
 *             pushed with a real transition and a back stack.
 *   flows   — picking files, choosing a device, a live transfer sheet with
 *             per-lane meters and a throughput shape, then a verified result.
 *
 * The engine underneath is the same v2 protocol the Mac and this phone already
 * speak; nothing here changes a byte on the wire. Every visual comes from
 * Design.kt and Widgets.kt — no platform widget is used for looks.
 */
class MainActivity : Activity() {

    // ── State ────────────────────────────────────────────────────────────

    private lateinit var pal: Pal

    private var service: ReceiveService? = null
    private var bound = false
    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            service = (binder as ReceiveService.LocalBinder).service
            bound = true
            service?.listener = { runOnUiThread { refreshReceive() } }
            refreshReceive()
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            bound = false
            service = null
        }
    }

    private val sendRunning = AtomicBoolean(false)
    private val sendEngine = AtomicReference<SendEngine?>(null)
    private val probeGeneration = AtomicInteger(0)
    private val lastProgress = AtomicReference<SendEngine.Progress?>(null)

    private class Staged(val uri: Uri, val destPath: String, val size: Long)

    private val staged = ArrayList<Staged>()
    private var stagedBytes = 0L
    private var selectedPeerKey: String? = null
    private var usbLaneUp = false
    private var sendLaneUsb = true
    private var socketsPerLane = 2

    private var multicastLock: WifiManager.MulticastLock? = null
    private var watcher: Net.BeaconWatcher? = null

    // ── Views ────────────────────────────────────────────────────────────

    private lateinit var root: FrameLayout
    private lateinit var scene: SceneView
    private lateinit var content: FrameLayout
    private lateinit var headerCard: GlassCard
    private lateinit var dockCard: GlassCard
    private lateinit var dock: Dock
    private lateinit var statusDot: DotView
    private lateinit var statusLabel: TextView

    private var screen = -1
    private var current: View? = null
    private val screens = HashMap<Int, View>()
    private val padded = ArrayList<View>()
    private var insetTop = 0
    private var insetBottom = 0

    // Home
    private lateinit var heroCard: GlassCard
    private lateinit var ball: BallView
    private lateinit var heroTitle: TextView
    private lateinit var heroCaption: TextView
    private lateinit var heroMeta: TextView
    private lateinit var heroMeter: MeterView
    private lateinit var heroCta: PillButton
    private lateinit var stagedRow: LinearLayout
    private lateinit var devicesBox: LinearLayout
    private lateinit var devicesEmpty: TextView
    private lateinit var laneWifiMeter: MeterView
    private lateinit var laneUsbMeter: MeterView
    private lateinit var laneWifiRate: TextView
    private lateinit var laneUsbRate: TextView
    private lateinit var laneWifiNote: TextView
    private lateinit var laneUsbNote: TextView
    private lateinit var laneUsbTile: IconTile
    private lateinit var combinedRate: TextView
    private lateinit var combinedFill: MeterView
    private lateinit var spark: SparkView
    private lateinit var sparkWrap: View
    private lateinit var console: ConsoleView
    private lateinit var receivedCount: TextView
    private lateinit var receivedBytes: TextView
    private lateinit var receiveToggle: GlassToggle
    private lateinit var listenNote: TextView

    // Files
    private lateinit var filesBox: LinearLayout
    private lateinit var filesSummary: TextView

    // ── Lifecycle ────────────────────────────────────────────────────────

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Density.init(this)
        Theme.load(this)
        pal = Theme.current(this)
        socketsPerLane = prefs().getInt("streams", 2)

        window.apply {
            addFlags(WindowManager.LayoutParams.FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS)
            statusBarColor = Color.TRANSPARENT
            navigationBarColor = Color.TRANSPARENT
        }
        @Suppress("DEPRECATION")
        window.decorView.systemUiVisibility =
            View.SYSTEM_UI_FLAG_LAYOUT_STABLE or
            View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
            View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or
            (if (pal.lightBars) View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR else 0) or
            (if (pal.lightBars) View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR else 0)

        root = FrameLayout(this)

        scene = SceneView(this, pal)
        root.addView(scene, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        scene.startAmbient()

        content = FrameLayout(this)
        root.addView(content, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))

        headerCard = GlassCard(this, Tok.R_PANEL, 1, lifted = true, pal = pal)
        headerCard.glowOnPress()
        buildHeader()
        root.addView(headerCard, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
        ).apply { gravity = Gravity.TOP })

        dock = Dock(this, listOf(Ico.HOUSE, Ico.DOWNLOAD, Ico.GEAR), listOf("Send", "Received", "Settings"), pal)
        dock.onSelect = { index -> showScreen(index) }
        dockCard = GlassCard(this, 26f, 2, lifted = true, pal = pal)
        dockCard.addView(dock, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        root.addView(dockCard, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
        ).apply { gravity = Gravity.BOTTOM })

        root.setOnApplyWindowInsetsListener { _, insets ->
            @Suppress("DEPRECATION")
            insetTop = insets.systemWindowInsetTop
            @Suppress("DEPRECATION")
            insetBottom = insets.systemWindowInsetBottom
            applyInsets()
            insets
        }

        setContentView(root)
        applyInsets()
        showScreen(0, animate = false)
        console.log("HyperSend $VERSION ready — listening on :${Protocol.DEFAULT_PORT}", pal.ok)

        startWatcher()
        refreshReceive()

        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        }
    }

    private fun prefs() = getSharedPreferences("hypersend", Context.MODE_PRIVATE)

    private fun applyInsets() {
        (headerCard.layoutParams as FrameLayout.LayoutParams).apply {
            topMargin = insetTop + dpi(10f)
            leftMargin = dpi(Tok.GUTTER)
            rightMargin = dpi(Tok.GUTTER)
            headerCard.layoutParams = this
        }
        (dockCard.layoutParams as FrameLayout.LayoutParams).apply {
            bottomMargin = insetBottom + dpi(10f)
            leftMargin = dpi(Tok.GUTTER)
            rightMargin = dpi(Tok.GUTTER)
            dockCard.layoutParams = this
        }
        val top = insetTop + dpi(96f)
        val bottom = insetBottom + dpi(104f)
        padded.forEach { v ->
            v.setPadding(dpi(Tok.GUTTER), top, dpi(Tok.GUTTER), bottom)
        }
        root.requestApplyInsets()
    }

    override fun onStart() {
        super.onStart()
        bindService(Intent(this, ReceiveService::class.java), connection, Context.BIND_AUTO_CREATE)
        startWatcher()
    }

    override fun onStop() {
        super.onStop()
        if (bound) {
            unbindService(connection)
            bound = false
        }
        stopWatcher()
    }

    override fun onDestroy() {
        scene.stopAmbient()
        ball.stopAmbient()
        stopWatcher()
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleInboundIntent(intent)
    }

    @Suppress("DEPRECATION")
    override fun onBackPressed() {
        val sheet = root.getTag(R.id.sheet_tag) as? Sheet
        if (sheet != null) {
            sheet.dismiss()
            return
        }
        if (screen != 0) {
            dock.select(0, true)
            return
        }
        super.onBackPressed()
    }

    // ── Chrome ───────────────────────────────────────────────────────────

    private fun buildHeader() {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dpi(14f), dpi(11f), dpi(12f), dpi(11f))
        }

        val mark = ImageView(this).apply {
            setImageResource(R.drawable.hypersend_icon)
            scaleType = ImageView.ScaleType.CENTER_CROP
            clipToOutline = true
            outlineProvider = object : android.view.ViewOutlineProvider() {
                override fun getOutline(view: View, outline: android.graphics.Outline) {
                    outline.setOval(0, 0, view.width, view.height)
                }
            }
            elevation = dp(6f)
        }
        row.addView(mark, LinearLayout.LayoutParams(dpi(38f), dpi(38f)))

        val col = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dpi(12f), 0, 0, 0)
        }
        col.addView(label(this, "HyperSend", Type.CARD, pal.textPrimary, Type.medium, -0.01f))
        col.addView(label(this, "Wi-Fi + USB, bonded", Type.MICRO, pal.textDim, Type.regular, 0.02f).apply {
            setPadding(0, dpi(2f), 0, 0)
        })
        row.addView(col, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))

        statusDot = DotView(this, pal.ok, 8f, glowing = true)
        row.addView(statusDot, LinearLayout.LayoutParams(dpi(14f), dpi(14f)).apply {
            rightMargin = dpi(6f)
            gravity = Gravity.CENTER_VERTICAL
        })
        statusLabel = label(this, "scanning…", Type.CAPTION, pal.textSecondary, Type.medium)
        row.addView(statusLabel, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT,
        ).apply { rightMargin = dpi(10f) })

        val settings = IconButton(this, Ico.GEAR, 38f, pal)
        settings.setOnClickListener {
            Motion.haptic(it)
            dock.select(2, true)
        }
        Motion.pressable(settings, 0.9f)
        row.addView(settings, LinearLayout.LayoutParams(dpi(38f), dpi(38f)))

        headerCard.addView(row, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
    }

    /** Swaps the visible screen with a real push transition. */
    private fun showScreen(index: Int, animate: Boolean = true) {
        if (index == screen) return
        val forwards = index > screen
        val next = screens.getOrPut(index) { buildScreen(index) }
        if (current === next) return
        val old = current
        screen = index
        current = next
        next.alpha = 0f
        next.translationX = 0f
        content.addView(next, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        if (animate && old != null) {
            Motion.pageIn(next, forwards)
            old.animate().alpha(0f)
                .translationX(dp(if (forwards) -30f else 30f))
                .setDuration(210).setInterpolator(Ease.inOut)
                .withEndAction { content.removeView(old) }.start()
        } else {
            old?.let { content.removeView(it) }
            next.alpha = 1f
        }
        if (index == 1) refreshFiles()
    }

    private fun buildScreen(index: Int): View = when (index) {
        0 -> buildHome()
        1 -> buildFiles()
        else -> buildSettings()
    }

    /** A scrolling screen body with the content gutter baked in. */
    private fun screenBody(): Pair<ScrollView, LinearLayout> {
        val scroll = ScrollView(this).apply {
            isVerticalScrollBarEnabled = false
            clipToPadding = false
            setPadding(dpi(Tok.GUTTER), insetTop + dpi(96f), dpi(Tok.GUTTER), insetBottom + dpi(104f))
            overScrollMode = View.OVER_SCROLL_NEVER
        }
        val stack = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        scroll.addView(stack, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        padded.add(scroll)
        return scroll to stack
    }

    private fun card(
        pad: Float = Tok.S4,
        radius: Float = Tok.R_PANEL,
        level: Int = 1,
        lifted: Boolean = true,
    ): GlassCard = GlassCard(this, radius, level, lifted, pal).apply {
        setPadding(dpi(pad), dpi(pad), dpi(pad), dpi(pad))
    }

    private fun sectionLabel(text: String): TextView = capsLabel(this, text, pal.textDim)

    private fun addToStack(stack: LinearLayout, v: View, margin: Float = 14f, height: Int? = null) {
        stack.addView(v, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            height ?: ViewGroup.LayoutParams.WRAP_CONTENT,
        ).apply { bottomMargin = dpi(margin) })
    }

    // ── Screen 0: Home ───────────────────────────────────────────────────

    private fun buildHome(): View {
        val (scroll, stack) = screenBody()

        // ── hero
        // Double-bezel: a soft outer shell, and inside it a recessed glass tray
        // holding the ball — the Mac's drop well, one layer deeper on a phone.
        heroCard = card(pad = 10f, radius = Tok.R_PANEL)
        val well = GlassCard(this, 20f, 0, false, pal)
        ball = BallView(this, pal)
        ball.isClickable = true
        ball.setOnClickListener { pickFiles() }
        Motion.pressable(ball, 0.97f, haptic = false)
        well.addView(ball, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, dpi(192f)))
        heroCard.addView(well, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, dpi(192f)))

        val inner = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dpi(10f), 0, dpi(10f), dpi(8f))
        }

        val eyebrowRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
        }
        val eyebrow = GlassCard(this, 999f, 2, false, pal).apply {
            setPadding(dpi(11f), dpi(5f), dpi(11f), dpi(5f))
            // A tinted rim, so the tag reads as a tag on white glass too.
            setAccentRing(Ink.withAlpha(pal.accent, if (pal.dark) 0.55f else 0.40f))
        }
        eyebrow.addView(capsLabel(this, "TWO LANES · SHA-256 VERIFIED", pal.textDim))
        eyebrowRow.addView(eyebrow, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        inner.addView(eyebrowRow, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
        ).apply { topMargin = dpi(16f) })

        heroTitle = label(this, "Send files to your Mac", Type.TITLE, pal.textPrimary, Type.medium, -0.02f)
        heroTitle.gravity = Gravity.CENTER
        inner.addView(heroTitle, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
        ).apply { topMargin = dpi(10f) })

        heroCaption = label(
            this,
            "They go down every lane at once — Wi-Fi and the USB cable — and every byte is SHA-256 verified on arrival.",
            Type.SUB, pal.textSecondary, Type.regular, 0.005f,
        ).apply {
            gravity = Gravity.CENTER
            setLineSpacing(0f, 1.3f)
            setPadding(dpi(4f), dpi(8f), dpi(4f), 0)
        }
        inner.addView(heroCaption, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))

        heroMeta = label(this, "", Type.CAPTION, pal.textDim, Type.mono).apply {
            gravity = Gravity.CENTER
            setPadding(0, dpi(12f), 0, 0)
            visibility = View.GONE
        }
        inner.addView(heroMeta, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))

        heroMeter = MeterView(this, pal.accent, 8f, pal).apply {
            visibility = View.GONE
        }
        inner.addView(heroMeter, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, dpi(8f),
        ).apply { topMargin = dpi(12f) })

        stagedRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            visibility = View.GONE
            setPadding(0, dpi(12f), 0, 0)
        }
        inner.addView(stagedRow, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))

        heroCta = PillButton(this, "Pick files to send", PillButton.FILLED, Ico.PLUS, pal)
        heroCta.setOnClickListener {
            if (sendRunning.get()) return@setOnClickListener
            if (staged.isEmpty()) pickFiles() else openSendSheet()
        }
        Motion.pressable(heroCta)
        inner.addView(heroCta, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, dpi(56f),
        ).apply { topMargin = dpi(16f) })

        heroCard.addView(inner, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        addToStack(stack, heroCard)

        // ── devices
        val devices = card(pad = Tok.S4)
        val devHead = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        devHead.addView(sectionLabel("DEVICES"), LinearLayout.LayoutParams(
            0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        val refresh = IconButton(this, Ico.REFRESH, 34f, pal)
        refresh.setOnClickListener {
            Motion.haptic(it)
            console.log("re-scanning the local network", pal.textDim)
            refreshDevices()
        }
        Motion.pressable(refresh, 0.9f)
        devHead.addView(refresh, LinearLayout.LayoutParams(dpi(34f), dpi(34f)))
        devices.addView(devHead, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))

        devicesEmpty = label(this, "Scanning for Macs on this network…", Type.SUB, pal.textDim)
            .apply { setPadding(0, dpi(12f), 0, 0) }
        devices.addView(devicesEmpty, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))

        devicesBox = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, dpi(12f), 0, 0)
        }
        devices.addView(devicesBox, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))

        val addByIp = label(this, "+  Add by IP address", Type.SUB, pal.textDim, Type.medium)
            .apply { setPadding(0, dpi(12f), 0, dpi(2f)) }
        addByIp.isClickable = true
        addByIp.setOnClickListener { toast("Manual entry arrives with the discovery rewrite.") }
        devices.addView(addByIp, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        addToStack(stack, devices)

        // ── lanes
        val lanes = card(pad = Tok.S4)
        val lanesHead = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        lanesHead.addView(sectionLabel("LANES"), LinearLayout.LayoutParams(
            0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        combinedRate = label(this, "idle", Type.CAPTION, pal.textDim, Type.mono)
        lanesHead.addView(combinedRate)
        lanes.addView(lanesHead, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))

        laneWifiMeter = MeterView(this, pal.wifi, 7f, pal)
        laneUsbMeter = MeterView(this, pal.usb, 7f, pal)
        laneWifiRate = label(this, "", Type.CAPTION, pal.textDim, Type.mono)
        laneUsbRate = label(this, "", Type.CAPTION, pal.textDim, Type.mono)
        laneWifiNote = label(this, "always available", Type.MICRO, pal.textDim, Type.medium, 0.04f)
        laneUsbNote = label(this, "no tunnel", Type.MICRO, pal.textDim, Type.medium, 0.04f)
        laneUsbTile = IconTile(this, Ico.USB, pal.textDim, 36f, pal = pal)

        lanes.addView(
            laneBlock("Wi-Fi", Ico.WIFI, pal.wifi, laneWifiNote, laneWifiMeter, laneWifiRate, null),
            FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT),
        )
        lanes.addView(vspace(this, 14f))
        lanes.addView(
            laneBlock("USB cable", Ico.USB, pal.usb, laneUsbNote, laneUsbMeter, laneUsbRate, laneUsbTile),
            FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT),
        )

        combinedFill = MeterView(this, pal.accent, 5f, pal)
        lanes.addView(combinedFill, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, dpi(5f),
        ).apply { topMargin = dpi(16f) })

        spark = SparkView(this, pal.accent, 52f, pal)
        sparkWrap = spark
        sparkWrap.visibility = View.GONE
        lanes.addView(sparkWrap, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, dpi(52f),
        ).apply { topMargin = dpi(8f) })
        addToStack(stack, lanes)

        // ── activity
        val activity = card(pad = Tok.S4)
        val actHead = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        actHead.addView(sectionLabel("ACTIVITY"), LinearLayout.LayoutParams(
            0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        val clear = IconButton(this, Ico.X, 32f, pal)
        clear.setOnClickListener { console.clear() }
        Motion.pressable(clear, 0.9f)
        actHead.addView(clear, LinearLayout.LayoutParams(dpi(32f), dpi(32f)))
        activity.addView(actHead, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))

        console = ConsoleView(this, pal, 148f)
        activity.addView(console, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, dpi(148f),
        ).apply { topMargin = dpi(10f) })
        addToStack(stack, activity)

        // ── receive
        val receive = card(pad = Tok.S4)
        val recHead = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        recHead.addView(sectionLabel("RECEIVE"), LinearLayout.LayoutParams(
            0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        receiveToggle = GlassToggle(this, pal, true)
        receiveToggle.onChanged = { on ->
            if (on) startForegroundService(Intent(this, ReceiveService::class.java))
            else {
                service?.setRunning(false)
                stopService(Intent(this, ReceiveService::class.java))
            }
            console.log(if (on) "receiver armed" else "receiver stopped", if (on) pal.ok else pal.warn)
            root.postDelayed({ refreshReceive() }, 120)
        }
        recHead.addView(receiveToggle, LinearLayout.LayoutParams(dpi(54f), dpi(32f)))
        receive.addView(recHead, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))

        listenNote = label(this, "", Type.MICRO, pal.textDim, Type.mono).apply {
            setPadding(0, dpi(8f), 0, 0)
        }
        receive.addView(listenNote, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        receive.addView(vspace(this, 12f))

        receive.addView(infoRow("Folder", "Download/HyperSend", Ico.FOLDER, onClick = { openFilesScreen() }))
        receive.addView(vspace(this, 10f))
        receivedCount = label(this, "0", Type.SUB, pal.textPrimary, Type.mono)
        receive.addView(infoRow("Received", "", Ico.ARCHIVE, null, receivedCount))
        receive.addView(vspace(this, 4f))
        receivedBytes = label(this, "", Type.MICRO, pal.textDim, Type.mono)
        receive.addView(receivedBytes, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        addToStack(stack, receive)

        // ── footer
        val footer = label(
            this,
            "MIT licensed  ·  no accounts, no cloud, no telemetry  ·  v$VERSION",
            Type.MICRO, pal.textDim, Type.regular, 0.02f,
        ).apply { gravity = Gravity.CENTER }
        footer.isClickable = true
        footer.setOnClickListener { openRepo() }
        stack.addView(footer, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
        ).apply { bottomMargin = dpi(8f) })

        Motion.cascade(
            (0 until stack.childCount).map { stack.getChildAt(it) },
            delay = 40, step = 55,
        )
        refreshHome()
        refreshDevices()
        return scroll
    }

    /** A lane: tile, name, status note, rate, and the meter under it. */
    private fun laneBlock(
        name: String,
        icon: Ico,
        tint: Int,
        noteView: TextView,
        meter: MeterView,
        rateView: TextView,
        reuseTile: IconTile?,
    ): View {
        val block = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val top = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        val tile = reuseTile ?: IconTile(this, icon, tint, 36f, pal = pal)
        top.addView(tile, LinearLayout.LayoutParams(dpi(36f), dpi(36f)))
        val mid = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dpi(11f), 0, dpi(8f), 0)
        }
        mid.addView(label(this, name, Type.CARD, pal.textPrimary, Type.medium))
        val stateRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dpi(3f), 0, 0)
        }
        stateRow.addView(noteView)
        mid.addView(stateRow)
        top.addView(mid, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        top.addView(rateView)
        block.addView(top, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        block.addView(meter, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, dpi(7f),
        ).apply { topMargin = dpi(10f) })
        return block
    }

    /** label … value  [chevron] — the inspector's key/value row. */
    private fun infoRow(
        keyText: String,
        valueText: String,
        icon: Ico,
        onClick: (() -> Unit)? = null,
        valueOverride: TextView? = null,
    ): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            if (onClick != null) {
                isClickable = true
                setOnClickListener { v -> Motion.haptic(v); onClick() }
                Motion.pressable(this, 0.98f, haptic = false)
            }
        }
        row.addView(IconView(this, icon, 17f, pal.textDim, 1.8f), LinearLayout.LayoutParams(
            dpi(17f), dpi(17f)).apply { rightMargin = dpi(9f) })
        row.addView(label(this, keyText, Type.SUB, pal.textSecondary), LinearLayout.LayoutParams(
            0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        val value = valueOverride ?: label(this, valueText, Type.SUB, pal.textPrimary, Type.mono)
        row.addView(value)
        if (onClick != null) {
            row.addView(IconView(this, Ico.CHEVRON, 13f, pal.textDim, 1.8f), LinearLayout.LayoutParams(
                dpi(13f), dpi(13f)).apply { leftMargin = dpi(7f) })
        }
        return row
    }
    // ── Discovery ────────────────────────────────────────────────────────

    private fun startWatcher() {
        if (watcher != null) return
        multicastLock = Net.acquireMulticastLock(this)
        val w = Net.BeaconWatcher(
            ownHosts = { Net.localAddresses().map { it.address }.toSet() },
            onPeers = { runOnUiThread { refreshDevices() } },
        )
        w.start()
        watcher = w
        refreshDevices()
    }

    private fun stopWatcher() {
        watcher?.stop()
        watcher = null
        try { multicastLock?.release() } catch (ignored: Exception) {}
        multicastLock = null
    }

    /**
     * Peers render immediately, then again once the background probe has
     * answered. DNS and the USB probe both stay off the main thread —
     * getAllByName on the UI thread is an instant NetworkOnMainThreadException.
     */
    private fun refreshDevices() {
        val peers = watcher?.snapshot() ?: emptyList()
        val generation = probeGeneration.incrementAndGet()
        renderDevices(peers, probing = true, resolved = emptyMap())
        if (peers.isEmpty()) {
            updateStatus()
            return
        }
        Thread {
            val usb = Net.probe("127.0.0.1", USB_REVERSE_PORT, 400)
            val resolved = peers.associate { peer ->
                peer.host to Net.candidates(peer.host).mapNotNull { it.hostAddress }.distinct()
            }
            if (probeGeneration.get() == generation) {
                runOnUiThread {
                    if (!usbLaneUp && usb) console.log("USB tunnel open — two lanes available", pal.ok)
                    usbLaneUp = usb
                    renderDevices(peers, probing = false, resolved = resolved)
                    updateStatus()
                    refreshHome()
                }
            }
        }.apply { isDaemon = true; name = "hypersend.probe"; start() }
    }

    private fun renderDevices(
        peers: List<Net.PeerRec>,
        probing: Boolean,
        resolved: Map<String, List<String>>,
    ) {
        if (!::devicesBox.isInitialized) return
        devicesBox.removeAllViews()
        devicesEmpty.visibility = if (peers.isEmpty()) View.VISIBLE else View.GONE
        if (peers.isEmpty()) return

        if (peers.none { it.host + ":" + it.port == selectedPeerKey }) {
            selectedPeerKey = peers.first().host + ":" + peers.first().port
            console.log("found ${peers.size} device(s) — ${peers.first().name}", pal.accent)
        }

        peers.forEachIndexed { i, peer ->
            val row = deviceRow(peer, probing, resolved[peer.host].orEmpty())
            devicesBox.addView(row, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply { bottomMargin = if (i == peers.lastIndex) 0 else dpi(9f) })
            row.alpha = 0f
            row.translationY = dp(16f)
            row.animate().alpha(1f).translationY(0f).setStartDelay(60L + i * 60L)
                .setDuration(360).setInterpolator(Ease.out).start()
        }
        updateStatus()
    }

    private fun deviceRow(peer: Net.PeerRec, probing: Boolean, hosts: List<String>): View {
        val key = peer.host + ":" + peer.port
        val selected = key == selectedPeerKey
        val row = GlassCard(this, 18f, 2, false, pal).apply {
            setPadding(dpi(12f), dpi(12f), dpi(12f), dpi(12f))
            if (selected) setAccentRing(pal.accent)
            isClickable = true
            tag = key
        }
        val line = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        line.addView(IconTile(this, Ico.LAPTOP, if (selected) pal.accent else pal.textSecondary, 40f, pal = pal),
            LinearLayout.LayoutParams(dpi(40f), dpi(40f)))

        val col = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dpi(12f), 0, dpi(8f), 0)
        }
        col.addView(label(this, peer.name, Type.CARD, pal.textPrimary, Type.medium, -0.01f))
        val address = when {
            probing -> "probing lanes…"
            else -> {
                val host = hosts.firstOrNull() ?: peer.host
                host + if (usbLaneUp) "  ·  wi-fi + usb" else "  ·  wi-fi only"
            }
        }
        col.addView(label(this, address, Type.CAPTION, pal.textSecondary, Type.mono).apply {
            setPadding(0, dpi(3f), 0, 0)
        })
        line.addView(col, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))

        val dot = DotView(this, if (probing || !usbLaneUp) pal.warn else pal.ok, 8f, !probing)
        line.addView(dot, LinearLayout.LayoutParams(dpi(16f), dpi(16f)).apply { rightMargin = dpi(6f) })
        line.addView(IconView(this, Ico.CHEVRON, 14f, pal.textDim, 1.8f), LinearLayout.LayoutParams(
            dpi(14f), dpi(14f)))
        row.addView(line, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))

        row.setOnClickListener {
            if (sendRunning.get()) {
                toast("a transfer is already running")
                return@setOnClickListener
            }
            if (hosts.isEmpty() && !probing) {
                toast("still resolving ${peer.host}")
                return@setOnClickListener
            }
            selectedPeerKey = key
            Motion.ringPulse(devicesBox, row.width / 2f, row.height / 2f, dpi(90f), pal.accent)
            refreshDevices()
            refreshHome()
        }
        Motion.pressable(row, 0.98f, haptic = false)
        return row
    }

    private fun updateStatus() {
        if (!::statusLabel.isInitialized) return
        val peers = watcher?.snapshot() ?: emptyList()
        when {
            peers.isEmpty() -> { statusDot.set(pal.warn, true); statusLabel.text = "scanning…" }
            usbLaneUp -> { statusDot.set(pal.ok, true); statusLabel.text = "2 lanes" }
            else -> { statusDot.set(pal.wifi, true); statusLabel.text = "wi-fi" }
        }
    }

    private fun selectedPeer(): Net.PeerRec? {
        val peers = watcher?.snapshot() ?: return null
        return peers.firstOrNull { it.host + ":" + it.port == selectedPeerKey } ?: peers.firstOrNull()
    }

    // ── Home state ───────────────────────────────────────────────────────

    private fun refreshHome() {
        if (!::heroTitle.isInitialized) return
        val peer = selectedPeer()
        val n = staged.size
        val running = sendRunning.get()
        if (!running) {
            ball.set(if (n > 0) BallView.Mode.SEND else BallView.Mode.IDLE)
            heroTitle.text = when {
                n > 0 -> "$n file${if (n == 1) "" else "s"} ready"
                peer != null -> "Send to ${peer.name}"
                else -> "Send files to your Mac"
            }
            heroCaption.text = if (n > 0)
                Protocol.humanBytes(stagedBytes) + " staged — tap a device below, then send."
            else
                "They go down every lane at once — Wi-Fi and the USB cable — and every byte is SHA-256 verified on arrival."
            heroMeta.visibility = View.GONE
            heroMeter.visibility = View.GONE
            combinedRate.text = "idle"
            combinedFill.setFraction(0f, false)
            laneWifiMeter.setFraction(0f, true)
            laneUsbMeter.setFraction(0f, true)
            laneWifiMeter.setActive(false)
            laneUsbMeter.setActive(false)
            sparkWrap.visibility = View.GONE
            laneWifiRate.text = ""
            laneUsbRate.text = ""
        }
        heroCta.setLabel(
            when {
                running -> "Sending — view"
                n > 0 -> "Send ${Protocol.humanBytes(stagedBytes)}"
                else -> "Pick files to send"
            },
            if (n > 0) Ico.ARROW_UP else Ico.PLUS,
        )
        renderStagedChips()
        laneWifiNote.text = "always available"
        laneUsbNote.text = if (usbLaneUp) "tunnel open" else "plug in the cable"
        laneUsbNote.setTextColor(if (usbLaneUp) pal.ok else pal.textDim)
    }

    private fun renderStagedChips() {
        if (!::stagedRow.isInitialized) return
        stagedRow.removeAllViews()
        if (staged.isEmpty()) {
            stagedRow.visibility = View.GONE
            return
        }
        stagedRow.visibility = View.VISIBLE
        val chip = GlassCard(this, Tok.R_PILL, 2, false, pal).apply {
            setPadding(dpi(14f), dpi(7f), dpi(12f), dpi(7f))
        }
        val line = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        val list = synchronized(staged) { staged.toList() }
        line.addView(IconView(this, Ico.FILE, 14f, pal.accent, 1.8f), LinearLayout.LayoutParams(
            dpi(14f), dpi(14f)).apply { rightMargin = dpi(8f) })
        val names = if (list.size == 1) list[0].destPath else "${list[0].destPath} +${list.size - 1} more"
        line.addView(label(this, names, Type.CAPTION, pal.textPrimary, Type.medium).apply {
            maxWidth = dpi(150f)
            ellipsize = android.text.TextUtils.TruncateAt.MIDDLE
            maxLines = 1
        })
        line.addView(IconView(this, Ico.X, 14f, pal.textDim, 1.9f), LinearLayout.LayoutParams(
            dpi(14f), dpi(14f)).apply { leftMargin = dpi(10f) })
        chip.addView(line, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        chip.setOnClickListener {
            synchronized(staged) { staged.clear(); stagedBytes = 0L }
            console.log("staged files cleared", pal.textDim)
            refreshHome()
        }
        Motion.pressable(chip, 0.95f)
        stagedRow.addView(chip, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        chip.scaleX = 0.9f
        chip.scaleY = 0.9f
        chip.animate().scaleX(1f).scaleY(1f).setDuration(300).setInterpolator(Ease.settle).start()
    }

    // ── Receive state ────────────────────────────────────────────────────

    private fun refreshReceive() {
        val svc = service
        val running = svc?.isRunning == true
        if (::receiveToggle.isInitialized && receiveToggle.isOn != running) {
            receiveToggle.setChecked(running, animate = false)
        }
        val count = svc?.engine?.receivedCount ?: 0
        if (::receivedCount.isInitialized) {
            receivedCount.text = "$count"
            val folder = receiveFolder()
            val total = folder.listFiles()?.sumOf { it.length() } ?: 0L
            receivedBytes.text = Protocol.humanBytes(total) + " in " + folder.name
            listenNote.text = if (running)
                "listening on ${svc?.ipAddress ?: Net.localAddresses().firstOrNull()?.address ?: "—"}:${Protocol.DEFAULT_PORT}"
            else "receiver stopped"
            listenNote.setTextColor(if (running) pal.ok else pal.textDim)
        }
    }

    private fun receiveFolder(): File = File(
        Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), "HyperSend",
    )

    // ── Screen 1: Received ───────────────────────────────────────────────

    private fun buildFiles(): View {
        val (scroll, stack) = screenBody()

        val head = card(pad = Tok.S4)
        val top = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        val col = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        col.addView(label(this, "Received", Type.TITLE, pal.textPrimary, Type.medium, -0.02f))
        filesSummary = label(this, "nothing yet", Type.CAPTION, pal.textDim, Type.mono).apply {
            setPadding(0, dpi(3f), 0, 0)
        }
        col.addView(filesSummary)
        top.addView(col, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        val open = IconButton(this, Ico.FOLDER, 38f, pal)
        open.setOnClickListener { v -> Motion.haptic(v); openDownloadFolder() }
        Motion.pressable(open, 0.9f)
        top.addView(open, LinearLayout.LayoutParams(dpi(38f), dpi(38f)))
        head.addView(top, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        addToStack(stack, head)

        filesBox = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        stack.addView(filesBox, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        return scroll
    }

    private fun refreshFiles() {
        if (!::filesBox.isInitialized) return
        filesBox.removeAllViews()
        val folder = receiveFolder()
        val files = folder.listFiles()?.filter { it.isFile }
            ?.sortedByDescending { it.lastModified() } ?: emptyList()
        val total = files.sumOf { it.length() }
        filesSummary.text = "${files.size} file(s) · ${Protocol.humanBytes(total)} · Download/HyperSend"

        if (files.isEmpty()) {
            val empty = card(pad = Tok.S6)
            val icon = IconView(this, Ico.FOLDER, 46f, pal.textDim, 1.5f)
            val holder = FrameLayout(this)
            holder.addView(icon, FrameLayout.LayoutParams(dpi(46f), dpi(46f)).apply { gravity = Gravity.CENTER })
            empty.addView(holder, FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dpi(64f)))
            val t = label(this, "Nothing received yet", Type.CARD, pal.textPrimary, Type.medium)
            t.gravity = Gravity.CENTER
            empty.addView(t, FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
            val s = label(
                this,
                "Files the Mac sends land in Download/HyperSend, each one SHA-256 verified before it is written.",
                Type.SUB, pal.textDim,
            ).apply {
                gravity = Gravity.CENTER
                setPadding(dpi(10f), dpi(7f), dpi(10f), 0)
                setLineSpacing(0f, 1.25f)
            }
            empty.addView(s, FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
            filesBox.addView(empty, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
            return
        }

        val stamp = SimpleDateFormat("d MMM · HH:mm", Locale.getDefault())
        files.forEachIndexed { i, file ->
            val row = GlassCard(this, 18f, 2, false, pal).apply {
                setPadding(dpi(12f), dpi(11f), dpi(10f), dpi(11f))
                isClickable = true
            }
            val line = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
            }
            line.addView(IconTile(this, iconFor(file.name), pal.accent, 40f, pal = pal),
                LinearLayout.LayoutParams(dpi(40f), dpi(40f)))
            val col = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(dpi(12f), 0, dpi(10f), 0)
            }
            col.addView(label(this, file.name, Type.SUB, pal.textPrimary, Type.medium).apply {
                maxLines = 1
                ellipsize = android.text.TextUtils.TruncateAt.MIDDLE
            })
            col.addView(label(
                this,
                Protocol.humanBytes(file.length()) + "  ·  " + stamp.format(Date(file.lastModified())),
                Type.MICRO, pal.textDim, Type.mono,
            ).apply { setPadding(0, dpi(3f), 0, 0) })
            line.addView(col, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            val share = IconButton(this, Ico.SHARE, 34f, pal)
            share.setOnClickListener { v -> Motion.haptic(v); shareFile(file) }
            Motion.pressable(share, 0.9f)
            line.addView(share, LinearLayout.LayoutParams(dpi(34f), dpi(34f)))
            row.addView(line, FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
            row.setOnClickListener { openFile(file) }
            Motion.pressable(row, 0.98f, haptic = false)
            filesBox.addView(row, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply { bottomMargin = dpi(10f) })
            row.alpha = 0f
            row.translationY = dp(14f)
            row.animate().alpha(1f).translationY(0f).setStartDelay(30L + i * 36L)
                .setDuration(340).setInterpolator(Ease.out).start()
        }
    }

    // ── Screen 2: Settings ───────────────────────────────────────────────

    private fun buildSettings(): View {
        val (scroll, stack) = screenBody()

        val title = label(this, "Settings", Type.TITLE, pal.textPrimary, Type.medium, -0.02f)
        stack.addView(title, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
        ).apply { bottomMargin = dpi(14f) })

        // Appearance
        val look = card(pad = Tok.S4)
        look.addView(sectionLabel("APPEARANCE"), FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        val seg = Segmented(this, listOf("System", "Light", "Dark"), pal)
        seg.select(Theme.override, notify = false)
        seg.onSelect = { index ->
            Theme.save(this, index)
            console.log("appearance → " + listOf("system", "light", "dark")[index], pal.textDim)
            recreate()
        }
        look.addView(seg, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, dpi(46f),
        ).apply { topMargin = dpi(12f) })
        addToStack(stack, look)

        // Receive
        val receive = card(pad = Tok.S4)
        receive.addView(sectionLabel("RECEIVE"), FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        receive.addView(vspace(this, 12f))
        val auto = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        auto.addView(label(this, "Accept automatically", Type.SUB, pal.textPrimary), LinearLayout.LayoutParams(
            0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        val autoToggle = GlassToggle(this, pal, true)
        autoToggle.onChanged = { on ->
            if (on) startForegroundService(Intent(this, ReceiveService::class.java))
            else service?.setRunning(false)
            root.postDelayed({ refreshReceive() }, 120)
        }
        auto.addView(autoToggle, LinearLayout.LayoutParams(dpi(54f), dpi(32f)))
        receive.addView(auto, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        receive.addView(vspace(this, 12f))
        receive.addView(infoRow("Folder", "Download/HyperSend", Ico.FOLDER, onClick = { openDownloadFolder() }))
        addToStack(stack, receive)

        // Transfer
        val transfer = card(pad = Tok.S4)
        transfer.addView(sectionLabel("TRANSFER"), FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        transfer.addView(vspace(this, 12f))
        val streamRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        streamRow.addView(label(this, "Sockets per lane", Type.SUB, pal.textPrimary), LinearLayout.LayoutParams(
            0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        val segStreams = Segmented(this, listOf("1", "2", "4"), pal, compact = true)
        segStreams.select(listOf(1, 2, 4).indexOf(socketsPerLane).coerceAtLeast(0), notify = false)
        segStreams.onSelect = { index ->
            socketsPerLane = listOf(1, 2, 4)[index]
            prefs().edit().putInt("streams", socketsPerLane).apply()
        }
        streamRow.addView(segStreams, LinearLayout.LayoutParams(dpi(132f), dpi(38f)))
        transfer.addView(streamRow, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        transfer.addView(vspace(this, 14f))
        transfer.addView(kv("Chunk size", "2 MiB"))
        transfer.addView(vspace(this, 8f))
        transfer.addView(kv("Control", "tcp :${Protocol.DEFAULT_PORT}"))
        transfer.addView(vspace(this, 8f))
        transfer.addView(kv("Data", "tcp :44012"))
        transfer.addView(vspace(this, 8f))
        transfer.addView(kv("Discovery", "udp :44011"))
        addToStack(stack, transfer)

        // Integrity
        val integrity = card(pad = Tok.S4)
        integrity.addView(sectionLabel("INTEGRITY"), FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        integrity.addView(vspace(this, 12f))
        integrity.addView(kv("Checksum", "SHA-256, per file"))
        integrity.addView(vspace(this, 8f))
        integrity.addView(kv("Resume", "byte offset, on either side"))
        integrity.addView(vspace(this, 8f))
        integrity.addView(kv("Protocol", "v2, shared with macOS"))
        addToStack(stack, integrity)

        // About
        val about = card(pad = Tok.S4)
        about.addView(sectionLabel("ABOUT"), FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        about.addView(vspace(this, 12f))
        about.addView(infoRow("Version", VERSION, Ico.INFO))
        about.addView(vspace(this, 10f))
        about.addView(infoRow("License", "MIT", Ico.SHIELD))
        about.addView(vspace(this, 10f))
        about.addView(infoRow("Source", "Repository", Ico.LINK, onClick = { openRepo() }))
        addToStack(stack, about, margin = 4f)

        Motion.cascade((0 until stack.childCount).map { stack.getChildAt(it) }, 30, 45)
        return scroll
    }

    private fun kv(key: String, value: String): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        row.addView(label(this, key, Type.SUB, pal.textSecondary), LinearLayout.LayoutParams(
            0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        row.addView(label(this, value, Type.SUB, pal.textPrimary, Type.mono))
        return row
    }

    // ── Staging (SAF) ────────────────────────────────────────────────────

    private fun pickFiles() {
        Motion.haptic(heroCta)
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        }
        startActivityForResult(Intent.createChooser(intent, "Files to send"), REQ_FILES)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (resultCode != RESULT_OK || data == null) return
        if (requestCode == REQ_FILES) {
            val uris = mutableListOf<Uri>()
            data.clipData?.let { clip ->
                for (i in 0 until clip.itemCount) uris.add(clip.getItemAt(i).uri)
            } ?: data.data?.let { uris.add(it) }
            if (uris.isNotEmpty()) stageUris(uris)
        }
    }

    private fun stageUris(uris: List<Uri>) {
        var bytes = 0L
        val list = ArrayList<Staged>(uris.size)
        for (uri in uris) {
            val name = queryDisplayName(uri) ?: "file-${list.size}"
            val size = querySize(uri)
            bytes += size
            list.add(Staged(uri, name, size))
        }
        synchronized(staged) {
            staged.clear()
            staged.addAll(list)
            stagedBytes = bytes
        }
        console.log("staged ${list.size} file(s) · ${Protocol.humanBytes(bytes)}", pal.accent)
        refreshHome()
        openSendSheet()
    }

    private fun queryDisplayName(uri: Uri): String? = try {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) c.getString(0) else null
        }
    } catch (ignored: Exception) {
        null
    }

    private fun querySize(uri: Uri): Long = try {
        contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { c ->
            if (c.moveToFirst() && !c.isNull(0)) c.getLong(0) else 0L
        } ?: 0L
    } catch (ignored: Exception) {
        0L
    }

    private fun handleInboundIntent(intent: Intent?) {
        val action = intent?.action ?: return
        val uris = when (action) {
            Intent.ACTION_SEND -> listOfNotNull(
                @Suppress("DEPRECATION")
                intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM),
            )
            Intent.ACTION_SEND_MULTIPLE ->
                @Suppress("DEPRECATION")
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.toList()
            else -> null
        } ?: return
        if (uris.isEmpty()) return
        stageUris(uris)
    }

    // ── The transfer sheet ───────────────────────────────────────────────

    private var sheet: Sheet? = null
    private lateinit var sheetBall: BallView
    private lateinit var sheetTitle: TextView
    private lateinit var sheetSub: TextView
    private lateinit var sheetDevices: LinearLayout
    private lateinit var sheetDevicesWrap: View
    private lateinit var sheetWifiMeter: MeterView
    private lateinit var sheetUsbMeter: MeterView
    private lateinit var sheetWifiRate: TextView
    private lateinit var sheetUsbRate: TextView
    private lateinit var sheetUsbToggle: GlassToggle
    private lateinit var sheetSpark: SparkView
    private lateinit var sheetFileLine: TextView
    private lateinit var sheetCta: PillButton
    private var sheetMode = -1
    private var laneUsbOn = true

    private fun openSendSheet() {
        val s = sheet ?: buildTransferSheet().also { sheet = it }
        setSheetMode(0)
        if (s.parent == null) {
            root.addView(s, FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
            root.setTag(R.id.sheet_tag, s)
            s.onDismissed = { root.setTag(R.id.sheet_tag, null) }
            s.present()
        } else {
            root.setTag(R.id.sheet_tag, s)
            s.present()
        }
    }

    private fun buildTransferSheet(): Sheet {
        val s = Sheet(this, pal)
        val card = GlassCard(this, 30f, 2, true, pal).apply {
            setPadding(dpi(18f), dpi(9f), dpi(18f), dpi(18f))
        }

        val handle = View(this)
        handle.background = android.graphics.drawable.GradientDrawable().apply {
            cornerRadius = dp(3f)
            setColor(Ink.withAlpha(pal.textDim, 0.5f))
        }
        card.addView(handle, FrameLayout.LayoutParams(dpi(46f), dpi(5f)).apply {
            gravity = Gravity.CENTER_HORIZONTAL
            topMargin = dpi(2f)
        })
        s.dragHandle(handle)

        val body = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }

        sheetBall = BallView(this, pal).apply { startAmbient() }
        body.addView(sheetBall, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, dpi(132f)).apply { topMargin = dpi(4f) })

        sheetTitle = label(this, "Ready to send", Type.HEADLINE, pal.textPrimary, Type.medium, -0.015f)
        sheetTitle.gravity = Gravity.CENTER
        body.addView(sheetTitle, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))

        sheetSub = label(this, "", Type.CAPTION, pal.textSecondary, Type.mono).apply {
            gravity = Gravity.CENTER
            setPadding(0, dpi(5f), 0, 0)
        }
        body.addView(sheetSub, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))

        // destinations
        sheetDevicesWrap = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        (sheetDevicesWrap as LinearLayout).addView(capsLabel(this, "SEND TO", pal.textDim).apply {
            setPadding(0, dpi(18f), 0, dpi(8f))
        })
        sheetDevices = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        (sheetDevicesWrap as LinearLayout).addView(sheetDevices)
        body.addView(sheetDevicesWrap, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))

        // lanes
        val lanesWrap = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        lanesWrap.addView(capsLabel(this, "LANES", pal.textDim).apply {
            setPadding(0, dpi(18f), 0, dpi(8f))
        })
        sheetWifiMeter = MeterView(this, pal.wifi, 6f, pal)
        sheetUsbMeter = MeterView(this, pal.usb, 6f, pal)
        sheetWifiRate = label(this, "required", Type.MICRO, pal.textDim, Type.mono)
        sheetUsbRate = label(this, if (usbLaneUp) "ready" else "no tunnel", Type.MICRO,
            if (usbLaneUp) pal.ok else pal.textDim, Type.mono)
        sheetUsbToggle = GlassToggle(this, pal, true)
        sheetUsbToggle.onChanged = { on ->
            laneUsbOn = on
            sheetUsbMeter.alpha = if (on) 1f else 0.3f
        }
        lanesWrap.addView(sheetLane("Wi-Fi", Ico.WIFI, pal.wifi, sheetWifiRate, sheetWifiMeter, null))
        lanesWrap.addView(vspace(this, 14f))
        lanesWrap.addView(sheetLane("USB cable", Ico.USB, pal.usb, sheetUsbRate, sheetUsbMeter, sheetUsbToggle))
        body.addView(lanesWrap, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))

        sheetFileLine = label(this, "", Type.CAPTION, pal.textSecondary, Type.mono).apply {
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.MIDDLE
            setPadding(0, dpi(14f), 0, 0)
        }
        body.addView(sheetFileLine, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))

        sheetSpark = SparkView(this, pal.accent, 46f, pal)
        body.addView(sheetSpark, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, dpi(46f)).apply { topMargin = dpi(6f) })

        sheetCta = PillButton(this, "Send", PillButton.FILLED, Ico.ARROW_UP, pal)
        sheetCta.setOnClickListener { onSheetCta() }
        Motion.pressable(sheetCta)
        body.addView(sheetCta, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, dpi(56f)).apply { topMargin = dpi(16f) })

        val scroll = ScrollView(this).apply {
            isVerticalScrollBarEnabled = false
            overScrollMode = View.OVER_SCROLL_NEVER
            clipToPadding = false
        }
        scroll.addView(body, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        card.addView(scroll, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            (resources.displayMetrics.heightPixels * 0.70f).toInt(),
        ))

        s.content(card)
        return s
    }

    private fun sheetLane(
        name: String,
        icon: Ico,
        tint: Int,
        rate: TextView,
        meter: MeterView,
        toggle: GlassToggle?,
    ): View {
        val block = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val top = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        top.addView(IconView(this, icon, 17f, tint, 1.9f), LinearLayout.LayoutParams(
            dpi(17f), dpi(17f)).apply { rightMargin = dpi(9f) })
        top.addView(label(this, name, Type.SUB, pal.textPrimary, Type.medium), LinearLayout.LayoutParams(
            0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        top.addView(rate, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT,
        ).apply { rightMargin = if (toggle != null) dpi(10f) else 0 })
        if (toggle != null) {
            top.addView(toggle, LinearLayout.LayoutParams(dpi(50f), dpi(30f)))
        }
        block.addView(top, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        block.addView(meter, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, dpi(6f)).apply { topMargin = dpi(9f) })
        return block
    }

    private fun setSheetMode(mode: Int) {
        if (!::sheetTitle.isInitialized) return
        sheetMode = mode
        val live = mode == 1
        val done = mode == 2
        val failed = mode == 3
        sheetDevicesWrap.visibility = if (mode == 0) View.VISIBLE else View.GONE
        sheetUsbToggle.visibility = if (mode == 0) View.VISIBLE else View.GONE
        sheetSpark.visibility = if (live || done) View.VISIBLE else View.GONE
        sheetFileLine.visibility = if (live) View.VISIBLE else View.GONE
        when (mode) {
            0 -> {
                sheetBall.set(BallView.Mode.IDLE)
                sheetTitle.text = "Ready to send"
                sheetSub.text = "${staged.size} file(s) · ${Protocol.humanBytes(stagedBytes)} · SHA-256 verified"
                sheetCta.setStyle(PillButton.FILLED)
                sheetCta.setLabel("Send to ${selectedPeer()?.name ?: "device"}", Ico.ARROW_UP)
                renderSheetDevices()
                sheetWifiRate.text = "required"
                sheetUsbRate.text = if (usbLaneUp) "ready" else "no tunnel"
                sheetUsbMeter.setFraction(0f, false)
                sheetWifiMeter.setFraction(0f, false)
            }
            1 -> {
                sheetBall.set(BallView.Mode.SEND, 0f)
                sheetBall.pop()
                sheetTitle.text = "Sending"
                sheetCta.setStyle(PillButton.DANGER)
                sheetCta.setLabel("Cancel transfer", Ico.X)
                sheetWifiMeter.setActive(true)
                sheetUsbMeter.setActive(laneUsbOn && usbLaneUp)
            }
            2 -> {
                sheetBall.set(BallView.Mode.DONE)
                sheetBall.pop()
                sheetTitle.text = "Verified on arrival"
                sheetWifiMeter.setActive(false)
                sheetUsbMeter.setActive(false)
                sheetCta.setStyle(PillButton.FILLED)
                sheetCta.setLabel("Done", Ico.CHECK)
            }
            else -> {
                sheetBall.set(BallView.Mode.FAIL)
                sheetBall.pop()
                sheetTitle.text = "Transfer failed"
                sheetWifiMeter.setActive(false)
                sheetUsbMeter.setActive(false)
                sheetCta.setStyle(PillButton.GHOST)
                sheetCta.setLabel("Close", Ico.X)
            }
        }
        if (failed) sheetSub.setTextColor(pal.bad) else sheetSub.setTextColor(pal.textSecondary)
    }

    private fun renderSheetDevices() {
        if (!::sheetDevices.isInitialized) return
        sheetDevices.removeAllViews()
        val peers = watcher?.snapshot() ?: emptyList()
        if (peers.isEmpty()) {
            sheetDevices.addView(label(this, "Scanning…", Type.SUB, pal.textDim))
            return
        }
        peers.forEachIndexed { i, peer ->
            val key = peer.host + ":" + peer.port
            val chosen = key == selectedPeerKey
            val chip = GlassCard(this, 16f, 2, false, pal).apply {
                setPadding(dpi(12f), dpi(11f), dpi(12f), dpi(11f))
                if (chosen) setAccentRing(pal.accent)
                isClickable = true
            }
            val line = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
            }
            line.addView(IconView(this, Ico.LAPTOP, 18f, if (chosen) pal.accent else pal.textSecondary, 1.9f),
                LinearLayout.LayoutParams(dpi(18f), dpi(18f)).apply { rightMargin = dpi(10f) })
            line.addView(label(this, peer.name, Type.SUB, pal.textPrimary, Type.medium), LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            line.addView(label(this, peer.host, Type.MICRO, pal.textDim, Type.mono))
            chip.addView(line, FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
            chip.setOnClickListener {
                selectedPeerKey = key
                Motion.haptic(chip)
                setSheetMode(0)
            }
            Motion.pressable(chip, 0.97f, haptic = false)
            sheetDevices.addView(chip, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply { bottomMargin = if (i == peers.lastIndex) 0 else dpi(8f) })
        }
    }

    private fun onSheetCta() {
        when (sheetMode) {
            0 -> beginSend()
            1 -> {
                sendEngine.get()?.cancel()
                console.log("transfer cancelled", pal.warn)
                setSheetMode(0)
            }
            else -> sheet?.dismiss()
        }
    }

    // ── Send flow ────────────────────────────────────────────────────────

    private fun beginSend() {
        val peer = selectedPeer() ?: run { toast("no device found yet"); return }
        val items = synchronized(staged) { staged.toList() }
        if (items.isEmpty()) {
            toast("pick files first")
            setSheetMode(0)
            return
        }
        if (sendRunning.get()) return

        setSheetMode(1)
        sendRunning.set(true)
        lastProgress.set(null)
        heroMeta.visibility = View.VISIBLE
        heroMeter.visibility = View.VISIBLE
        heroMeter.setFraction(0f, false)
        heroMeta.text = "0 B · 0 MB/s"
        ball.set(BallView.Mode.SEND, 0f)
        spark.reset()
        sheetSpark.reset()
        Motion.ringPulse(heroCard, heroCard.width / 2f, dp(120f), dpi(96f), pal.accent)
        console.log("sending ${items.size} file(s) to ${peer.name} over ${if (usbLaneUp && laneUsbOn) "2 lanes" else "1 lane"}", pal.accent)
        refreshHome()

        Thread {
            try {
                val hosts = Net.candidates(peer.host).mapNotNull { it.hostAddress }.distinct()
                if (hosts.isEmpty()) throw IllegalStateException("cannot resolve ${peer.host}")

                val dir = File(cacheDir, "outgoing")
                dir.deleteRecursively()
                dir.mkdirs()
                val files = ArrayList<File>(items.size)
                val dests = ArrayList<String>(items.size)
                items.forEachIndexed { i, item ->
                    val dst = File(dir, item.destPath.replace('/', '_'))
                    contentResolver.openInputStream(item.uri)?.use { input ->
                        dst.outputStream().use { output -> input.copyTo(output, 1 shl 16) }
                    }
                    files.add(dst)
                    dests.add(item.destPath)
                    val label = "preparing ${i + 1}/${items.size} · ${item.destPath}"
                    runOnUiThread { sheetSub.text = label }
                }

                val lanes = ArrayList<SendEngine.Lane>()
                lanes.add(SendEngine.Lane("wifi", hosts))
                if (usbLaneUp && laneUsbOn) {
                    lanes.add(SendEngine.Lane("usb", listOf("127.0.0.1"), USB_REVERSE_PORT))
                }

                val engine = SendEngine(
                    running = AtomicBoolean(true),
                    log = { },
                    onStateChange = { },
                )
                sendEngine.set(engine)
                val summary = engine.send(
                    files = files,
                    destPaths = dests,
                    lanes = lanes,
                    socketsPerLane = socketsPerLane,
                    progress = { pr ->
                        lastProgress.set(pr)
                        runOnUiThread { renderProgress(pr) }
                    },
                )
                dir.deleteRecursively()
                runOnUiThread { onSendDone(summary) }
            } catch (e: Exception) {
                runOnUiThread { onSendFailed(e) }
            } finally {
                sendEngine.set(null)
                sendRunning.set(false)
            }
        }.apply { name = "hypersend.send"; isDaemon = true; start() }
    }

    private var lastRenderMs = 0L

    private fun renderProgress(pr: SendEngine.Progress) {
        val now = System.currentTimeMillis()
        if (now - lastRenderMs < 120) return
        lastRenderMs = now

        val mbps = pr.bytesPerSec / (1024.0 * 1024.0)
        ball.set(BallView.Mode.SEND, pr.fraction.toFloat())
        heroTitle.text = "Sending to ${selectedPeer()?.name ?: "device"}"
        heroCaption.text = "${pr.fileIndex} of ${pr.fileCount} · ${pr.fileName}"
        heroMeta.text = String.format(
            Locale.US, "%s / %s · %.1f MB/s",
            Protocol.humanBytes(pr.bytesDone), Protocol.humanBytes(pr.bytesTotal), mbps,
        )
        heroMeter.setFraction(pr.fraction.toFloat())
        heroCta.setLabel(
            String.format(Locale.US, "%.0f%% · %.1f MB/s", pr.fraction * 100, mbps),
            Ico.ARROW_UP,
        )

        combinedRate.text = String.format(Locale.US, "%.1f MB/s", mbps)
        combinedFill.setFraction(pr.fraction.toFloat())
        sparkWrap.visibility = View.VISIBLE
        spark.push(mbps.toFloat())

        val wifiBytes = pr.laneBytes["wifi"] ?: 0L
        val usbBytes = pr.laneBytes["usb"] ?: 0L
        val laneTotal = (wifiBytes + usbBytes).coerceAtLeast(1L)
        laneWifiMeter.setFraction(wifiBytes.toFloat() / laneTotal)
        laneUsbMeter.setFraction(usbBytes.toFloat() / laneTotal)
        laneWifiMeter.setActive(wifiBytes > 0)
        laneUsbMeter.setActive(usbBytes > 0)
        val secs = pr.seconds.coerceAtLeast(0.001)
        laneWifiRate.text = if (wifiBytes > 0)
            String.format(Locale.US, "%.1f MB/s", wifiBytes / secs / (1024.0 * 1024.0)) else ""
        laneUsbRate.text = if (usbBytes > 0)
            String.format(Locale.US, "%.1f MB/s", usbBytes / secs / (1024.0 * 1024.0)) else ""

        if (::sheetBall.isInitialized) {
            sheetBall.set(BallView.Mode.SEND, pr.fraction.toFloat())
            val eta = if (pr.bytesPerSec > 0)
                (pr.bytesTotal - pr.bytesDone) / pr.bytesPerSec else 0.0
            sheetSub.text = String.format(
                Locale.US, "%.0f%% · %s / %s · %.1f MB/s · %.0fs left",
                pr.fraction * 100, Protocol.humanBytes(pr.bytesDone),
                Protocol.humanBytes(pr.bytesTotal), mbps, eta,
            )
            sheetFileLine.text = "${pr.fileIndex}/${pr.fileCount}  ${pr.fileName}"
            sheetSpark.push(mbps.toFloat())
            sheetWifiMeter.setFraction(wifiBytes.toFloat() / laneTotal)
            sheetUsbMeter.setFraction(usbBytes.toFloat() / laneTotal)
            sheetWifiRate.text = String.format(Locale.US, "%.1f MB/s", wifiBytes / secs / (1024.0 * 1024.0))
            sheetUsbRate.text = if (usbBytes > 0)
                String.format(Locale.US, "%.1f MB/s", usbBytes / secs / (1024.0 * 1024.0)) else "idle"
        }
    }

    private fun onSendDone(summary: SendEngine.Summary) {
        val mbps = summary.bytesPerSec / (1024.0 * 1024.0)
        ball.set(BallView.Mode.DONE, 1f)
        ball.pop()
        heroTitle.text = "Sent ${summary.files} file(s)"
        heroCaption.text = if (summary.declined > 0) {
            "Every byte verified with SHA-256 on arrival · ${summary.declined} declined by the receiver."
        } else {
            "Every byte verified with SHA-256 on arrival."
        }
        heroMeta.text = String.format(
            Locale.US, "%s in %.1fs · %.1f MB/s",
            Protocol.humanBytes(summary.bytes), summary.seconds, mbps,
        )
        heroMeter.setFraction(1f)
        combinedFill.setFraction(1f)
        combinedRate.text = String.format(Locale.US, "%.1f MB/s avg", mbps)
        laneWifiMeter.setActive(false)
        laneUsbMeter.setActive(false)
        synchronized(staged) { staged.clear(); stagedBytes = 0L }
        renderStagedChips()
        console.log(
            "done — ${summary.files} file(s), ${Protocol.humanBytes(summary.bytes)} in " +
                String.format(Locale.US, "%.1fs (%.1f MB/s)", summary.seconds, mbps),
            pal.ok,
        )
        refreshHome()
        heroTitle.text = "Sent ${summary.files} file(s)"
        heroMeta.text = String.format(
            Locale.US, "%s · %.1f MB/s · verified", Protocol.humanBytes(summary.bytes), mbps,
        )
        heroMeta.visibility = View.VISIBLE
        if (::sheetSub.isInitialized) {
            sheetSub.text = String.format(
                Locale.US, "%d file(s) · %s · %.1fs · %.1f MB/s",
                summary.files, Protocol.humanBytes(summary.bytes), summary.seconds, mbps,
            )
            sheetFileLine.text = "SHA-256 verified on the Mac"
            sheetFileLine.visibility = View.VISIBLE
            setSheetMode(2)
        }
        toast("sent ${summary.files} file(s)")
    }

    private fun onSendFailed(e: Exception) {
        ball.set(BallView.Mode.FAIL)
        ball.pop()
        heroTitle.text = "Send failed"
        heroCaption.text = e.message?.take(120) ?: "unknown error"
        heroMeta.visibility = View.GONE
        heroMeter.visibility = View.GONE
        combinedRate.text = "failed"
        laneWifiMeter.setActive(false)
        laneUsbMeter.setActive(false)
        console.log("failed — ${e.message?.take(90) ?: "unknown"}", pal.bad)
        if (::sheetSub.isInitialized) {
            sheetSub.text = e.message?.take(120) ?: "unknown error"
            setSheetMode(3)
        }
        refreshHome()
        heroTitle.text = "Send failed"
        heroCaption.text = e.message?.take(120) ?: ""
        toast("send failed — see activity")
    }

    // ── File helpers ─────────────────────────────────────────────────────

    private fun iconFor(name: String): Ico = when (name.substringAfterLast('.', "").lowercase(Locale.US)) {
        "png", "jpg", "jpeg", "webp", "gif", "heic" -> Ico.IMAGE
        "mp4", "mov", "mkv", "webm", "avi" -> Ico.VIDEO
        "mp3", "wav", "flac", "m4a", "opus" -> Ico.MUSIC
        "zip", "tar", "gz", "7z", "rar" -> Ico.ARCHIVE
        "pdf", "md", "txt", "json", "kt", "swift", "ts", "sh" -> Ico.FILE
        else -> Ico.FILE
    }

    private fun mimeOf(file: File): String = android.webkit.MimeTypeMap.getSingleton()
        .getMimeTypeFromExtension(file.extension.lowercase(Locale.US)) ?: "*/*"

    /**
     * There is no androidx here, so no FileProvider — the content URI comes
     * from MediaStore instead, with a scan kicked off when the file has not
     * been indexed yet (a transfer lands in Download and is usually indexed
     * within seconds).
     */
    private fun contentUriFor(file: File): Uri? = try {
        val collection = android.provider.MediaStore.Files.getContentUri("external")
        @Suppress("DEPRECATION")
        val dataColumn = android.provider.MediaStore.Files.FileColumns.DATA
        contentResolver.query(
            collection,
            arrayOf(android.provider.MediaStore.Files.FileColumns._ID),
            "$dataColumn=?", arrayOf(file.absolutePath), null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) android.content.ContentUris.withAppendedId(collection, cursor.getLong(0)) else null
        }
    } catch (ignored: Exception) {
        null
    }

    private fun openFile(file: File) {
        Motion.haptic(root)
        val uri = contentUriFor(file)
        if (uri == null) {
            android.media.MediaScannerConnection.scanFile(this, arrayOf(file.absolutePath), null) { _, _ -> }
            toast("indexing ${file.name} — try again in a moment")
            return
        }
        try {
            startActivity(
                Intent(Intent.ACTION_VIEW)
                    .setDataAndType(uri, mimeOf(file))
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION),
            )
        } catch (ignored: Exception) {
            toast("nothing on this phone opens .${file.extension}")
        }
    }

    private fun shareFile(file: File) {
        val uri = contentUriFor(file) ?: run {
            toast("still indexing — try again in a moment")
            return
        }
        try {
            startActivity(
                Intent.createChooser(
                    Intent(Intent.ACTION_SEND)
                        .setType(mimeOf(file))
                        .putExtra(Intent.EXTRA_STREAM, uri)
                        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION),
                    "Share ${file.name}",
                ),
            )
        } catch (ignored: Exception) {
            toast("no app can share this file")
        }
    }

    private fun openDownloadFolder() {
        try {
            startActivity(Intent(android.app.DownloadManager.ACTION_VIEW_DOWNLOADS))
        } catch (ignored: Exception) {
            toast("Download/HyperSend")
        }
    }

    private fun openFilesScreen() {
        dock.select(1, true)
    }

    private fun openRepo() {
        try {
            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://github.com/lakshyaverse/HyperSend")))
        } catch (ignored: Exception) {
            toast("github.com/lakshyaverse/HyperSend")
        }
    }

    private fun toast(message: String) {
        if (isFinishing || isDestroyed) return
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
    }

    companion object {
        const val VERSION = "0.4.2"

        /** adb reverse tunnel as seen from the phone: 127.0.0.1:44014 → Mac :44012. */
        const val USB_REVERSE_PORT = 44014
        private const val REQ_FILES = 11
    }
}
