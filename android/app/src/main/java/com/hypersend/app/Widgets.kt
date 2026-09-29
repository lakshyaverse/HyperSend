package com.hypersend.app

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RadialGradient
import android.graphics.RectF
import android.graphics.Shader
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.animation.ValueAnimator
import android.view.animation.OvershootInterpolator
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import java.io.File
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

// HyperSend for Android — the component library.
//
// Every pixel the app draws comes from here. Nothing uses a platform widget
// for looks: switches, buttons, meters, sheets and the bottom dock are all
// custom-drawn so they can carry the Mac window's glass, one at a time.
//
// Layer order in the app, back to front:
//   1. SceneView   — sky gradient + coloured blooms + film grain
//   2. GlassCard   — fill, sheen, specular rim, shadow (nested freely)
//   3. content     — type, icons, meters, the ball
//   4. Dock / Sheet — the two floating chrome pieces

// ── 1. The scene ─────────────────────────────────────────────────────────

/**
 * The sky behind everything. Three gradients and a grain tile, the Android
 * answer to the Mac's pastel scene: glass can only look like glass if there is
 * something behind it worth bending.
 *
 * The blooms drift on a 24-second loop, so the window is never quite still.
 */
class SceneView(ctx: Context, var pal: Pal) : View(ctx) {

    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private var layers: List<SceneLayer> = emptyList()
    private var builtFor = Float.NaN
    private var drift = 0f
    private var lastInvalidate = 0L
    private var animator: ValueAnimator? = null

    init {
        setWillNotDraw(false)
        // Lets the lens be put into probe mode from adb instead of by rebuilding.
        Glass.debugFile = File(ctx.filesDir, "hs_dbg")
    }

    fun setPalette(p: Pal) {
        pal = p
        layers = emptyList()
        // The glass samples this snapshot, so it has to follow the palette.
        Glass.snapshot(width, height, p, drift)
        invalidate()
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        layers = emptyList()
        Glass.snapshot(w, h, pal, drift)
    }

    /**
     * The scene, as a stack of full-bleed layers. Built from `sceneLayers()` so
     * that the window and the lens snapshot cannot disagree about it.
     */
    private fun ensureLayers() {
        if (layers.isNotEmpty() && builtFor == drift) return
        if (width <= 0 || height <= 0) return
        builtFor = drift
        layers = sceneLayers(width.toFloat(), height.toFloat(), pal, drift, 1f)
    }

    fun startAmbient() {
        if (animator != null) return
        animator = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 24_000
            repeatCount = ValueAnimator.INFINITE
            repeatMode = ValueAnimator.REVERSE
            addUpdateListener {
                drift = it.animatedValue as Float
                val now = System.currentTimeMillis()
                // The blooms are enormous and soft, so they only need a few
                // frames a second to read as alive. Anything faster re-runs the
                // lens on every glass surface for no visible gain.
                if (now - lastInvalidate > 220) {
                    lastInvalidate = now
                    // The snapshot has to be refreshed alongside the window, or
                    // the glass goes on refracting blooms that have since moved.
                    Glass.snapshot(width, height, pal, drift)
                    invalidate()
                }
            }
            start()
        }
    }

    fun stopAmbient() {
        animator?.cancel()
        animator = null
    }

    override fun onDraw(canvas: Canvas) {
        ensureLayers()
        val w = width.toFloat()
        val h = height.toFloat()
        layers.forEach { layer ->
            paint.shader = layer.shader
            paint.alpha = layer.alpha
            canvas.drawRect(0f, 0f, w, h, paint)
        }
        paint.alpha = 255
        paint.shader = null
    }
}

/** One full-bleed pass of the scene: a shader and the alpha to draw it at. */
internal class SceneLayer(val shader: Shader, val alpha: Int = 255)

/**
 * The scene, back to front, in one place.
 *
 * `SceneView` paints this into the window and `Glass` paints it into the bitmap
 * the lens samples. Those two must agree pixel for pixel — if the glass bends a
 * backdrop that is not the one behind it, every surface picks up an artefact
 * that no amount of tuning the optics can remove, because the optics are not
 * what is wrong.
 *
 * This is the second time this file has had to learn that lesson. The blooms
 * were unified first; the **grain and the vignette were left out of the
 * snapshot**, and the grain is the only thing giving the sky any texture at
 * all. So the window's sky was speckled and the lens's copy was smooth, which
 * is why every card wore a flat, off-colour band along its edge: the refraction
 * was faithfully magnifying a backdrop that did not exist.
 *
 * @param grainScale the snapshot is rendered at half scale, so its grain has to
 *                   be half scale with it or the speckle the glass bends would
 *                   be twice the size of the speckle on screen.
 */
internal fun sceneLayers(
    w: Float,
    h: Float,
    pal: Pal,
    drift: Float,
    grainScale: Float,
): List<SceneLayer> {
    if (w <= 0f || h <= 0f) return emptyList()
    val out = ArrayList<SceneLayer>(6)
    out += SceneLayer(
        LinearGradient(
            0f, 0f, w * 0.18f, h,
            intArrayOf(pal.skyTop, pal.skyMid, pal.skyBottom),
            floatArrayOf(0f, 0.52f, 1f), Shader.TileMode.CLAMP,
        ),
    )
    blooms(w, h, pal, drift).forEach { b ->
        out += SceneLayer(
            RadialGradient(
                b.cx, b.cy, b.radius,
                intArrayOf(b.color, Ink.withAlpha(b.color, 0f)), null, Shader.TileMode.CLAMP,
            ),
        )
    }
    out += SceneLayer(Grain.shader(grainScale), pal.grainAlpha)
    out += SceneLayer(
        LinearGradient(
            0f, h * 0.62f, 0f, h,
            intArrayOf(Ink.withAlpha(pal.skyBottom, 0f), Ink.withAlpha(pal.skyBottom, 0.85f)),
            null, Shader.TileMode.CLAMP,
        ),
    )
    return out
}

/** Deterministic xorshift grain tile — the same speckle the Mac composites. */
object Grain {
    private val cache = HashMap<Float, BitmapShader>()

    /**
     * @param scale 1 in the window; 0.5 inside the half-scale lens snapshot, so
     *              the speckle is the same physical size in both.
     */
    fun shader(scale: Float = 1f): BitmapShader {
        cache[scale]?.let { return it }
        val size = 96
        var s = 0x9E3779B97F4A7C15uL
        val px = IntArray(size * size)
        for (i in px.indices) {
            s = s xor (s shl 13); s = s xor (s shr 7); s = s xor (s shl 17)
            val v = (s and 0xFFuL).toInt()
            px[i] = Color.argb(255, v, v, v)
        }
        val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        bmp.setPixels(px, 0, size, 0, 0, size, size)
        val sh = BitmapShader(bmp, Shader.TileMode.REPEAT, Shader.TileMode.REPEAT)
        if (scale != 1f) {
            sh.setLocalMatrix(Matrix().apply { setScale(scale, scale) })
        }
        return sh.also { cache[scale] = it }
    }
}

// ── 2. Glass ─────────────────────────────────────────────────────────────

/**
 * True when this view sits inside another pane.
 *
 * Apple's rule is *one* glass layer. Its own session is explicit: "always avoid
 * glass on glass... when placing elements on top of Liquid Glass, avoid applying
 * the material to both layers. Instead, use fills, transparency and vibrancy for
 * the top elements to make them feel like a thin overlay that is part of the
 * material." Walking the parent chain is how a view knows which of the two it is
 * without every call site having to remember — and it is also why a chip stops
 * refracting the sky through the card it is sitting on.
 */
internal fun View.nestedInGlass(): Boolean {
    var p = parent
    while (p != null) {
        if (p is GlassCard || p is PillButton) return true
        p = p.parent
    }
    return false
}

/**
 * A flat pane — the vibrancy overlay that lives *on* the material.
 *
 * Fill, a whisper of vertical gradient, and the same hairline rim the lens
 * draws for itself. No refraction, no lensing, no shadow: an overlay on a pane
 * is not a second pane, and treating it as one is the single biggest reason a
 * glass UI turns into a pile of white outlined slabs.
 *
 * `recessed` inverts the gradient and adds an inner shadow at the crown, so a
 * recess reads as a depression in the pane rather than as a lighter chip on it.
 */
internal fun drawPane(
    canvas: Canvas,
    outline: Path,
    rect: RectF,
    fill: Int,
    rimTop: Int,
    rimBottom: Int,
    hairline: Float,
    paint: Paint,
    recessed: Boolean = false,
) {
    paint.shader = null
    paint.style = Paint.Style.FILL
    paint.color = fill
    canvas.drawPath(outline, paint)
    if (recessed) {
        paint.shader = LinearGradient(
            0f, rect.top, 0f, rect.top + rect.height() * 0.34f,
            0x3A060C22, 0x00060C22, Shader.TileMode.CLAMP,
        )
    } else {
        paint.shader = LinearGradient(
            0f, rect.top, 0f, rect.bottom,
            Ink.mix(fill, Color.WHITE, 0.14f), Ink.mix(fill, Color.BLACK, 0.05f),
            Shader.TileMode.CLAMP,
        )
    }
    canvas.drawPath(outline, paint)

    paint.shader = null
    paint.style = Paint.Style.STROKE
    paint.color = 0
    Ink.rim(rect, rimTop, rimBottom, paint)
    paint.strokeWidth = hairline
    canvas.drawPath(outline, paint)
    paint.style = Paint.Style.FILL
}

/**
 * A glass panel. Four overlapping layers, which is what separates this from a
 * one-colour rounded rectangle:
 *
 *   1. body   — the fill, a hair lighter at the top than the bottom
 *   2. sheen  — a white cone falling from the top edge (the "specular")
 *   3. rim    — 1 dp hairline, bright at the crown, dissolved by the waist
 *   4. depth  — an elevation shadow, or an inner top shadow when recessed
 *
 * level 0 = recessed well, 1 = panel, 2 = raised card.
 */
class GlassCard(
    ctx: Context,
    var radius: Float = Tok.R_CARD,
    var level: Int = 1,
    var lifted: Boolean = false,
    var pal: Pal = Theme.current(ctx),
) : FrameLayout(ctx) {

    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val rect = RectF()
    private val shape = Shape()
    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }
    private var accentRing = 0
    private var pressT = 0f

    /**
     * Cards draw the glass, and hold their content in one vertical column —
     * so callers can keep adding children in reading order and everything
     * stacks the way a panel should, rather than piling up in the middle.
     */
    private val column = LinearLayout(ctx).apply { orientation = LinearLayout.VERTICAL }

    /**
     * False only while this card installs its own column. ViewGroup.addView
     * re-enters addView(child, index, params) internally, so without this the
     * override would try to make the column a child of itself and the layout
     * pass would recurse until the stack blew up.
     */
    private var forwarding = false

    init {
        setWillNotDraw(false)
        super.addView(column, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        forwarding = true
        // Deliberately no framework `elevation`. It paints the hard, near-black
        // band Material wants and then `Ink.shadow` paints a soft one over it,
        // which is two shadows under every card — the giveaway that a UI was
        // assembled rather than designed. The painted penumbra is the shadow.
    }

    fun setAccentRing(color: Int) {
        accentRing = color
        invalidate()
    }

    // ── content forwarding ──

    private fun asParams(params: ViewGroup.LayoutParams?): LinearLayout.LayoutParams {
        if (params is LinearLayout.LayoutParams) return params
        val lp = LinearLayout.LayoutParams(
            params?.width ?: ViewGroup.LayoutParams.MATCH_PARENT,
            params?.height ?: ViewGroup.LayoutParams.WRAP_CONTENT,
        )
        if (params is FrameLayout.LayoutParams) {
            lp.leftMargin = params.leftMargin
            lp.topMargin = params.topMargin
            lp.rightMargin = params.rightMargin
            lp.bottomMargin = params.bottomMargin
            lp.gravity = params.gravity
        }
        return lp
    }

    override fun addView(child: View) {
        if (forwarding) column.addView(child) else super.addView(child)
    }

    override fun addView(child: View, params: ViewGroup.LayoutParams?) {
        if (forwarding) column.addView(child, asParams(params)) else super.addView(child, params)
    }

    override fun addView(child: View, index: Int, params: ViewGroup.LayoutParams?) {
        if (forwarding) column.addView(child, index, asParams(params)) else super.addView(child, index, params)
    }

    override fun addView(child: View, width: Int, height: Int) {
        if (forwarding) column.addView(child, width, height) else super.addView(child, width, height)
    }

    override fun removeAllViews() {
        column.removeAllViews()
        invalidate()
    }

    fun removeContentView(view: View) {
        column.removeView(view)
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        rect.set(0f, 0f, w.toFloat(), h.toFloat())
    }

    fun setPalette(p: Pal) {
        pal = p
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        // One outline for every layer, so the body, the rim and the shadow can
        // never disagree — and the corner is continuous, not quarter-circular.
        val outline = shape.of(width, height, radius)

        // Depth sits outside the silhouette, so it is drawn before the clip.
        if (level > 0 && !nestedInGlass() && Glass.canRefract) {
            val lift = if (lifted) dp(22f) else dp(if (level == 2) 15f else 11f)
            Ink.shadow(canvas, outline, rect, pal.shadow, lift, dp(if (lifted) 9f else 5f), paint)
        }

        canvas.save()
        canvas.clipPath(outline)

        val base = when (level) {
            0 -> pal.well
            2 -> pal.panelRaised
            else -> pal.panel
        }

        var lensed = false
        if (level > 0 && !nestedInGlass() && Glass.canRefract) {
            lensed = Glass.fill(
                this, canvas, outline, rect, pal,
                tint = base,
                radiusPx = dp(radius),
                thickness = if (level == 2) 1.15f else 1f,
                // Measured off the Mac: a big panel's own edge carries no
                // highlight at all, so a card gets almost none. Held back on
                // purpose — this is the term that turns glass into a white
                // outline the moment it is turned up.
                spec = if (level == 2) 0.30f else 0.16f,
            )
        }
        if (!lensed) {
            // A recess, a nested overlay, or a device without AGSL. All three
            // are a flat pane: the material is already accounted for by the
            // layer underneath.
            drawPane(
                canvas, outline, rect,
                if (level == 0) pal.well else base,
                pal.rimTop, pal.rimBottom,
                if (accentRing != 0) dp(1.6f) else max(1f, Density.d),
                paint,
                recessed = level == 0,
            )
        }

        // The selection wash belongs *to* the glass, so it is drawn under the
        // clip rather than smeared past the silhouette.
        if (accentRing != 0) {
            paint.shader = null
            paint.color = Ink.withAlpha(accentRing, (if (pal.dark) 0.12f else 0.09f) + 0.10f * pressT)
            canvas.drawPath(outline, paint)
            Ink.glow(rect.centerX(), rect.centerY(), max(rect.width(), rect.height()) * 0.7f,
                Ink.withAlpha(accentRing, 0.10f), paint)
            canvas.drawPath(outline, paint)
        }
        canvas.restore()

        // The lens paints its own hairline inside the material; a flat pane
        // needs one drawn for it.
        if (!lensed) {
            stroke.color = 0
            Ink.rim(rect, pal.rimTop, pal.rimBottom, stroke)
            stroke.strokeWidth = if (accentRing != 0) dp(1.6f) else max(1f, Density.d)
            canvas.drawPath(outline, stroke)
        }
    }

    /** Rim brightens under the finger — the same courtesy the system glass gives. */
    fun glowOnPress() {
        setOnTouchListener { v, ev ->
            when (ev.actionMasked) {
                MotionEvent.ACTION_DOWN -> animatePress(1f)
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> animatePress(0f)
            }
            false
        }
    }

    private fun animatePress(target: Float) {
        ValueAnimator.ofFloat(pressT, target).apply {
            duration = 220
            addUpdateListener { pressT = it.animatedValue as Float; invalidate() }
            start()
        }
    }
}

/** Hairline separator. */
fun divider(ctx: Context, color: Int): View = View(ctx).apply {
    layoutParams = LinearLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT, max(1, dpi(0.7f)),
    )
    setBackgroundColor(color)
}

/**
 * Measure every child against an at-most box of this size. Custom ViewGroups
 * in this file set their own dimensions, so they have to do this by hand —
 * skipping it silently lays children out at zero and the content disappears.
 */
fun ViewGroup.childrenAtMost(width: Int, height: Int) {
    val wSpec = View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.AT_MOST)
    val hSpec = View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.AT_MOST)
    for (i in 0 until childCount) getChildAt(i).measure(wSpec, hSpec)
}

/**
 * Measure children at exactly this size. Weighted rows need this: a weighted
 * child only receives its share of space when its parent is measured EXACTLY,
 * otherwise the row wraps to its natural width and the tabs collapse into
 * each other.
 */
fun ViewGroup.childrenExactly(width: Int, height: Int) {
    val wSpec = View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY)
    val hSpec = View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.EXACTLY)
    for (i in 0 until childCount) getChildAt(i).measure(wSpec, hSpec)
}

/** Fixed-size gap. */
fun gap(ctx: Context, sizeDp: Float): View = View(ctx).apply {
    layoutParams = LinearLayout.LayoutParams(dpi(sizeDp), dpi(sizeDp))
}

fun gapH(ctx: Context, sizeDp: Float): View = View(ctx).apply {
    layoutParams = LinearLayout.LayoutParams(dpi(sizeDp), 1)
}

fun vspace(ctx: Context, sizeDp: Float): View = View(ctx).apply {
    layoutParams = LinearLayout.LayoutParams(1, dpi(sizeDp))
}

/** A text label with no opinions beyond the one you give it. */
fun label(
    ctx: Context,
    text: String,
    size: Float,
    color: Int,
    face: android.graphics.Typeface = Type.regular,
    tracking: Float = 0f,
): TextView = TextView(ctx).apply {
    this.text = text
    style(size, color, face, tracking)
}

/** Micro tracked-out section label. */
fun capsLabel(ctx: Context, text: String, color: Int): TextView = TextView(ctx).apply {
    this.text = text
    capsStyle(color)
}

/** Everything a machine produced gets mono: addresses, sizes, rates. */
fun monoStyle(v: TextView): TextView = v.style(Type.CAPTION, v.currentTextColor, Type.mono, 0f, 1.1f)

/** A small glowing status dot. */
class DotView(ctx: Context, var color: Int, private var sizeDp: Float = 9f, var glowing: Boolean = false) : View(ctx) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)

    fun set(color: Int, glowing: Boolean) {
        this.color = color
        this.glowing = glowing
        Motion.dotPulse(this, glowing)
        invalidate()
    }

    override fun onMeasure(w: Int, h: Int) {
        val px = dpi(sizeDp + if (glowing) 6f else 0f)
        setMeasuredDimension(resolveSize(px, w), resolveSize(px, h))
    }

    override fun onDraw(canvas: Canvas) {
        val cx = width / 2f
        val cy = height / 2f
        val r = dpi(sizeDp) / 2f
        if (glowing) {
            Ink.glow(cx, cy, r * 2.6f, Ink.withAlpha(color, 0.5f), paint)
            canvas.drawCircle(cx, cy, r * 2.6f, paint)
            paint.shader = null
        }
        paint.color = color
        canvas.drawCircle(cx, cy, r, paint)
    }
}

/** An icon in a soft rounded tile — the Mac's sidebar glyph treatment. */
class IconTile(
    ctx: Context,
    icon: Ico,
    tint: Int,
    private val sizeDp: Float = 38f,
    fill: Int = 0,
    private val pal: Pal = Theme.current(ctx),
) : FrameLayout(ctx) {

    val iconView = IconView(ctx, icon, sizeDp * 0.5f, tint, 1.7f)
    private val bg = Paint(Paint.ANTI_ALIAS_FLAG)
    private val rect = RectF()
    private val shape = Shape()
    private var fillColor = fill
    private val radius = sizeDp * 0.32f

    init {
        addView(iconView, LayoutParams(dpi(sizeDp * 0.5f), dpi(sizeDp * 0.5f)).apply {
            gravity = Gravity.CENTER
        })
        setWillNotDraw(false)
    }

    fun setTint(color: Int) {
        fillColor = color
        invalidate()
    }

    override fun onMeasure(w: Int, h: Int) {
        val px = dpi(sizeDp)
        val side = resolveSize(px, w)
        // A ViewGroup that fixes its own size still has to measure its child —
        // otherwise the glyph inside gets laid out at 0×0 and vanishes.
        childrenAtMost(side, side)
        setMeasuredDimension(side, side)
    }

    override fun onSizeChanged(w: Int, h: Int, ow: Int, oh: Int) {
        rect.set(0f, 0f, w.toFloat(), h.toFloat())
    }

    override fun onDraw(canvas: Canvas) {
        val outline = shape.of(width, height, radius)
        // A glyph well sitting *on* a pane. A lens here would refract the scene
        // straight through the card it is supposed to be resting on, which is
        // exactly how these read as holes punched in their parents.
        val body = if (fillColor != 0) fillColor else Ink.withAlpha(Color.WHITE, if (pal.dark) 0.10f else 0.24f)
        drawPane(
            canvas, outline, rect, body,
            Ink.withAlpha(Color.WHITE, if (pal.dark) 0.13f else 0.30f), pal.rimBottom,
            max(1f, Density.d), bg,
        )
    }
}
// ── 3. The ball ──────────────────────────────────────────────────────────

/**
 * The hero. On the Mac this is the drop well: a glossy ball, radar rings, and
 * the state word underneath. On the phone it is also the button — one object
 * that means "send".
 *
 * Rings pulse outward on a 3.3 s loop, the ball breathes and bobs on the same
 * clock, and while a transfer runs a progress arc wraps the whole thing.
 */
class BallView(ctx: Context, var pal: Pal) : View(ctx) {

    enum class Mode { IDLE, SEND, RECEIVE, DONE, FAIL }

    var mode: Mode = Mode.IDLE
        private set
    var progress: Float = 0f
        private set

    private var phase = 0f
    private var lastFrame = 0L
    private var ambient: ValueAnimator? = null
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val arcPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
    }
    private val iconPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
        strokeWidth = 2.1f
    }

    private val baseR get() = min(width, height) * 0.20f

    fun setPalette(p: Pal) { pal = p; invalidate() }

    fun set(state: Mode, fraction: Float = progress) {
        mode = state
        progress = fraction.coerceIn(0f, 1f)
        invalidate()
    }

    fun startAmbient() {
        if (ambient != null) return
        ambient = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 3300
            repeatCount = ValueAnimator.INFINITE
            addUpdateListener {
                phase = it.animatedValue as Float
                translationY = -dp(3f) * (0.5f + 0.5f * kotlin.math.sin(phase * 2 * Math.PI).toFloat())
                // The bob and the breath are a 3.3 s sine. They do not need 60
                // fps — and every frame here makes the card this ball sits in
                // re-run its whole lens, so an unhurried animation is not a
                // nicety, it is most of the app's frame budget.
                val now = System.currentTimeMillis()
                if (now - lastFrame > 50) {
                    lastFrame = now
                    invalidate()
                }
            }
            start()
        }
    }

    fun stopAmbient() {
        ambient?.cancel()
        ambient = null
    }

    /** A little pop when the state changes — nothing moves without a reason. */
    fun pop() {
        scaleX = 0.94f
        scaleY = 0.94f
        animate().scaleX(1f).scaleY(1f).setDuration(360)
            .setInterpolator(Ease.settle).start()
    }

    override fun onDraw(canvas: Canvas) {
        val cx = width / 2f
        val cy = height / 2f
        val r = baseR * (1f + 0.028f * kotlin.math.sin(phase * 2 * Math.PI).toFloat())
        if (r <= 0f) return

        val tint = when (mode) {
            Mode.DONE -> pal.ok
            Mode.FAIL -> pal.bad
            else -> pal.accent
        }

        // radar rings
        for (i in 0 until 3) {
            val p = (phase + i / 3f) % 1f
            val rr = r * 1.15f + (r * 2.15f - r * 1.15f) * Math.pow(p.toDouble(), 0.82).toFloat()
            val alpha = Math.pow(1.0 - p.toDouble(), 1.9).toFloat() * 0.55f
            paint.shader = null
            paint.style = Paint.Style.STROKE
            paint.strokeWidth = dp(1.3f)
            paint.color = Ink.withAlpha(tint, alpha)
            canvas.drawCircle(cx, cy, rr, paint)
        }

        // halo behind the ball
        paint.style = Paint.Style.FILL
        Ink.glow(cx, cy, r * 2.1f, Ink.withAlpha(tint, 0.20f), paint)
        canvas.drawCircle(cx, cy, r * 2.1f, paint)

        // contact shadow
        Ink.glow(cx, cy + r * 1.02f, r * 1.5f, 0x3A060C22, paint)
        canvas.drawCircle(cx, cy + r * 1.02f, r * 1.5f, paint)

        // the sphere: a light source up and to the left
        val core = Color.WHITE
        val mid = Ink.mix(tint, Color.WHITE, if (pal.dark) 0.58f else 0.80f)
        val edge = Ink.mix(tint, if (pal.dark) Color.BLACK else Color.WHITE, if (pal.dark) 0.22f else 0.30f)
        paint.shader = RadialGradient(
            cx - r * 0.34f, cy - r * 0.40f, r * 1.85f,
            intArrayOf(core, core, mid, edge),
            floatArrayOf(0f, 0.30f, 0.72f, 1f), Shader.TileMode.CLAMP,
        )
        canvas.drawCircle(cx, cy, r, paint)
        paint.shader = null

        // rim light along the bottom-right, where the scene shows through
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = dp(1.1f)
        paint.color = Ink.withAlpha(Color.WHITE, 0.55f)
        canvas.drawCircle(cx, cy, r - dp(0.6f), paint)

        // the specular hit
        paint.style = Paint.Style.FILL
        Ink.glow(cx - r * 0.34f, cy - r * 0.40f, r * 0.62f, Ink.withAlpha(Color.WHITE, 0.92f), paint)
        canvas.drawCircle(cx - r * 0.34f, cy - r * 0.40f, r * 0.62f, paint)

        // the state glyph
        val glyph = when (mode) {
            Mode.RECEIVE -> Ico.ARROW_DOWN
            Mode.SEND -> Ico.ARROW_UP
            Mode.DONE -> Ico.CHECK
            Mode.FAIL -> Ico.X
            else -> Ico.ARROW_UP
        }
        val gs = r * 0.78f
        iconPaint.color = Ink.mix(tint, Color.BLACK, 0.58f)
        iconPaint.strokeWidth = 2.1f
        canvas.save()
        canvas.translate(cx - gs / 2f, cy - gs / 2f)
        canvas.scale(gs / 24f, gs / 24f)
        Icons.draw(canvas, iconPaint, glyph)
        canvas.restore()

        // progress arc, wrapping the rings
        if (progress > 0.001f && (mode == Mode.SEND || mode == Mode.RECEIVE)) {
            val ar = r * 1.52f
            arcPaint.strokeWidth = dp(3.4f)
            paint.style = Paint.Style.STROKE
            paint.strokeWidth = dp(3.4f)
            paint.color = Ink.withAlpha(tint, 0.20f)
            canvas.drawCircle(cx, cy, ar, paint)
            arcPaint.color = tint
            canvas.drawArc(
                RectF(cx - ar, cy - ar, cx + ar, cy + ar),
                -90f, 360f * progress, false, arcPaint,
            )
            val head = Math.toRadians((-90f + 360f * progress).toDouble())
            val hx = cx + (ar * Math.cos(head)).toFloat()
            val hy = cy + (ar * Math.sin(head)).toFloat()
            paint.style = Paint.Style.FILL
            Ink.glow(hx, hy, dp(9f), Ink.withAlpha(tint, 0.85f), paint)
            canvas.drawCircle(hx, hy, dp(9f), paint)
            paint.color = Color.WHITE
            canvas.drawCircle(hx, hy, dp(2.2f), paint)
        }
    }
}

// ── 4. Meters ────────────────────────────────────────────────────────────

/**
 * One lane's throughput: a track, a fill that springs to its target, a glow at
 * the head, and a highlight that sweeps while the lane is carrying bytes.
 */
class MeterView(
    ctx: Context,
    var color: Int,
    private var heightDp: Float = 7f,
    var pal: Pal = Theme.current(ctx),
) : View(ctx) {

    private var target = 0f
    private var shown = 0f
    private var sweep = 0f
    private var runner: ValueAnimator? = null
    private var sweeper: ValueAnimator? = null
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val rect = RectF()

    var active: Boolean = false
        private set

    fun setFraction(fraction: Float, animate: Boolean = true) {
        val f = fraction.coerceIn(0f, 1f)
        target = f
        runner?.cancel()
        if (!animate) {
            shown = f
            invalidate()
            return
        }
        runner = ValueAnimator.ofFloat(shown, f).apply {
            duration = 460
            interpolator = Ease.out
            addUpdateListener { shown = it.animatedValue as Float; invalidate() }
            start()
        }
    }

    fun setActive(on: Boolean) {
        if (active == on) return
        active = on
        sweeper?.cancel()
        sweeper = null
        if (on) {
            sweeper = ValueAnimator.ofFloat(0f, 1f).apply {
                duration = 2100
                repeatCount = ValueAnimator.INFINITE
                addUpdateListener { sweep = it.animatedValue as Float; invalidate() }
                start()
            }
        } else {
            sweep = 0f
            invalidate()
        }
    }

    fun recolor(c: Int) {
        color = c
        invalidate()
    }

    override fun onMeasure(w: Int, h: Int) {
        setMeasuredDimension(resolveSize(dpi(120f), w), resolveSize(dpi(heightDp), h))
    }

    override fun onSizeChanged(w: Int, h: Int, ow: Int, oh: Int) {
        rect.set(0f, 0f, w.toFloat(), h.toFloat())
    }

    override fun onDraw(canvas: Canvas) {
        val r = height / 2f
        paint.shader = null
        paint.color = pal.track
        canvas.drawRoundRect(rect, r, r, paint)

        val fw = max(0f, width * shown)
        if (fw < 1f) return
        val fillRect = RectF(0f, 0f, fw, height.toFloat())
        paint.shader = LinearGradient(
            0f, 0f, 0f, height.toFloat(),
            Ink.mix(color, Color.WHITE, 0.35f), color, Shader.TileMode.CLAMP,
        )
        canvas.drawRoundRect(fillRect, r, r, paint)

        // specular line along the top of the fill
        paint.shader = LinearGradient(
            0f, 0f, 0f, height.toFloat(),
            Ink.withAlpha(Color.WHITE, 0.42f), Ink.withAlpha(Color.WHITE, 0f), Shader.TileMode.CLAMP,
        )
        canvas.drawRoundRect(RectF(0f, 0f, fw, height * 0.5f), r, r, paint)

        if (active) {
            val band = fw * sweep
            val half = dp(14f)
            val left = max(0f, band - half)
            paint.shader = LinearGradient(
                left, 0f, band + half * 0.4f, 0f,
                intArrayOf(Ink.withAlpha(Color.WHITE, 0f), Ink.withAlpha(Color.WHITE, 0.42f), Ink.withAlpha(Color.WHITE, 0f)),
                null, Shader.TileMode.CLAMP,
            )
            canvas.drawRoundRect(RectF(left, 0f, min(fw, band + half), height.toFloat()), r, r, paint)
            paint.shader = null
            Ink.glow(fw, r, height * 2.4f, Ink.withAlpha(color, 0.75f), paint)
            canvas.drawCircle(fw, r, height * 2.4f, paint)
        }
        paint.shader = null
    }
}

/**
 * A throughput history as a soft area chart. The Mac prints numbers; a phone
 * reads a shape faster, so both are here.
 */
class SparkView(
    ctx: Context,
    var color: Int,
    private var heightDp: Float = 44f,
    var pal: Pal = Theme.current(ctx),
) : View(ctx) {

    private val ring = FloatArray(72)
    private var count = 0
    private var cursor = 0
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val path = Path()
    private val fillPath = Path()

    fun push(v: Float) {
        ring[cursor] = v
        cursor = (cursor + 1) % ring.size
        count = min(ring.size, count + 1)
        invalidate()
    }

    fun reset() {
        ring.fill(0f)
        count = 0
        cursor = 0
        invalidate()
    }

    override fun onMeasure(w: Int, h: Int) {
        setMeasuredDimension(resolveSize(dpi(120f), w), resolveSize(dpi(heightDp), h))
    }

    override fun onDraw(canvas: Canvas) {
        if (count < 2) return
        val peak = max(ring.maxOrNull() ?: 0f, 0.35f)
        val n = count
        val stepX = width / (n - 1).toFloat()
        path.reset()
        fillPath.reset()
        var prevY = height - (ring[(cursor - n + ring.size) % ring.size] / peak) * (height * 0.86f) - height * 0.07f
        path.moveTo(0f, prevY)
        for (i in 1 until n) {
            val v = ring[(cursor - n + i + ring.size) % ring.size]
            val y = height - (v / peak) * (height * 0.86f) - height * 0.07f
            val x = i * stepX
            path.quadTo(x - stepX / 2f, prevY, x, y)
            prevY = y
        }
        fillPath.addPath(path)
        fillPath.lineTo(width.toFloat(), height.toFloat())
        fillPath.lineTo(0f, height.toFloat())
        fillPath.close()

        paint.shader = LinearGradient(
            0f, 0f, 0f, height.toFloat(),
            Ink.withAlpha(color, 0.32f), Ink.withAlpha(color, 0f), Shader.TileMode.CLAMP,
        )
        paint.style = Paint.Style.FILL
        canvas.drawPath(fillPath, paint)

        paint.shader = null
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = dp(2f)
        paint.strokeCap = Paint.Cap.ROUND
        paint.strokeJoin = Paint.Join.ROUND
        paint.color = color
        canvas.drawPath(path, paint)

        // the head of the line, glowing like the meter's tip
        paint.style = Paint.Style.FILL
        val hx = width.toFloat()
        val hy = prevY
        Ink.glow(hx, hy, dp(8f), Ink.withAlpha(color, 0.8f), paint)
        canvas.drawCircle(hx, hy, dp(8f), paint)
        paint.color = Color.WHITE
        canvas.drawCircle(hx, hy, dp(2.1f), paint)
    }
}
// ── 5. Controls ──────────────────────────────────────────────────────────

/**
 * The primary call to action — the Mac's filled blue pill, at thumb scale.
 * Four variants, all glass: filled accent, outlined, ghost, destructive.
 */
class PillButton(
    ctx: Context,
    text: String,
    var variant: Int = FILLED,
    icon: Ico? = null,
    var pal: Pal = Theme.current(ctx),
) : FrameLayout(ctx) {

    companion object {
        const val FILLED = 0
        const val OUTLINE = 1
        const val GHOST = 2
        const val DANGER = 3
    }

    val textView: TextView = TextView(ctx).apply {
        this.text = text
        gravity = Gravity.CENTER
        style(Type.CARD, Color.WHITE, Type.medium, 0.005f)
    }
    var iconView: IconView? = null

    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val rect = RectF()
    private val shape = Shape()
    private var busy = false
    private var island: GlassCard? = null

    init {
        setWillNotDraw(false)
        val row = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
        }
        // Button-in-button: on a filled pill the glyph rides in its own
        // circular well at the trailing edge, never naked next to the label.
        val iv = icon?.let { IconView(ctx, it, 18f, tint(), 1.75f) }
        iconView = iv
        if (iv != null && (variant == FILLED || variant == DANGER)) {
            row.addView(textView)
            val disc = GlassCard(ctx, 999f, 2, false, pal)
            disc.addView(iv, LayoutParams(dpi(17f), dpi(17f)).apply { gravity = Gravity.CENTER })
            island = disc
            row.addView(disc, LinearLayout.LayoutParams(dpi(32f), dpi(32f)).apply {
                leftMargin = dpi(11f)
            })
        } else {
            if (iv != null) {
                row.addView(iv, LinearLayout.LayoutParams(dpi(18f), dpi(18f)))
                row.addView(View(ctx), LinearLayout.LayoutParams(dpi(9f), 1))
            }
            row.addView(textView)
        }
        addView(row, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply {
            gravity = Gravity.CENTER
        })
        // The painted penumbra in onDraw is the shadow; a framework elevation
        // on top of it would double every button.
    }

    private fun tint(): Int = when (variant) {
        FILLED, DANGER -> pal.onAccent
        OUTLINE -> pal.accent
        else -> pal.textSecondary
    }

    fun setBusy(on: Boolean) {
        busy = on
        alpha = if (on) 0.75f else 1f
    }

    fun setLabel(text: String, icon: Ico? = null) {
        textView.text = text
        iconView?.set(icon ?: Ico.CHECK, tint())
    }

    /** Trailing glyph colours for the island variant, and vice versa. */
    private fun refreshTint() {
        val c = tint()
        textView.setTextColor(c)
        iconView?.color = c
        iconView?.invalidate()
    }

    fun setStyle(v: Int) {
        variant = v
        refreshTint()
        invalidate()
    }

    override fun onMeasure(w: Int, h: Int) {
        val height = max(dpi(56f), resolveSize(dpi(56f), h))
        val width = resolveSize(dpi(160f), w)
        childrenAtMost(width, height)
        setMeasuredDimension(width, height)
    }

    override fun onSizeChanged(w: Int, h: Int, ow: Int, oh: Int) {
        rect.set(0f, 0f, w.toFloat(), h.toFloat())
        refreshTint()
    }

    override fun onDraw(canvas: Canvas) {
        val outline = shape.ofPx(width, height, height / 2f)
        val filled = variant == FILLED || variant == DANGER
        val accentCol = if (variant == DANGER) pal.bad else pal.accent

        // The accent arrives as a *tint*, never as paint. Apple is blunt about
        // this one: a button using a solid fill "is completely opaque and breaks
        // the visual character of Liquid Glass", where the tinted version stays
        // transparent and grounded in its environment. So the fill is the accent
        // at eighty-odd percent — enough to read as the primary action, thin
        // enough that the pane underneath still shows through it.
        val fill = when (variant) {
            FILLED, DANGER -> Ink.withAlpha(accentCol, if (pal.dark) 0.78f else 0.84f)
            OUTLINE -> Ink.withAlpha(pal.textPrimary, if (pal.dark) 0.05f else 0.04f)
            else -> Ink.withAlpha(pal.textPrimary, if (pal.dark) 0.09f else 0.06f)
        }

        Ink.shadow(canvas, outline, rect, pal.shadow, dp(if (filled) 10f else 7f), dp(4f), paint)

        var lensed = false
        if (!nestedInGlass() && Glass.canRefract) {
            lensed = Glass.fill(
                this, canvas, outline, rect, pal,
                tint = fill,
                radiusPx = height / 2f,
                thickness = 0.9f,
                desat = pal.desat * 0.7f,
                // A pill turns over faster at its rim than a panel does, so it
                // catches the light — this is the surface the specular is for.
                spec = if (filled) 1f else 0.85f,
            )
        }
        if (!lensed) {
            drawPane(
                canvas, outline, rect, fill,
                Ink.withAlpha(Color.WHITE, if (filled) 0.28f else 0.22f),
                if (variant == OUTLINE) Ink.withAlpha(pal.accent, 0.55f) else pal.rimBottom,
                if (variant == OUTLINE) dp(1.5f) else max(1f, Density.d),
                paint,
            )
        }

        if (busy) {
            paint.shader = null
            paint.style = Paint.Style.FILL
            paint.color = Ink.withAlpha(tint(), 0.5f)
            canvas.drawCircle(width - dp(22f), height / 2f, dp(3.5f), paint)
        }
    }
}

/** A round glass button with a glyph in it — the Mac's toolbar buttons. */
class IconButton(
    ctx: Context,
    icon: Ico,
    private var sizeDp: Float = 42f,
    var pal: Pal = Theme.current(ctx),
    tint: Int = 0,
) : FrameLayout(ctx) {

    val iconView = IconView(ctx, icon, sizeDp * 0.46f, if (tint != 0) tint else pal.textPrimary, 1.75f)
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val rect = RectF()
    private val circle = Path()

    init {
        setWillNotDraw(false)
        addView(iconView, LayoutParams(dpi(sizeDp * 0.46f), dpi(sizeDp * 0.46f)).apply {
            gravity = Gravity.CENTER
        })
        // No framework elevation: `Ink.shadow` is the only shadow in this file.
    }

    fun tint(color: Int) {
        iconView.color = color
        iconView.invalidate()
    }

    override fun onMeasure(w: Int, h: Int) {
        val px = dpi(sizeDp)
        val side = resolveSize(px, w)
        childrenAtMost(side, side)
        setMeasuredDimension(side, side)
    }

    override fun onSizeChanged(w: Int, h: Int, ow: Int, oh: Int) {
        rect.set(0f, 0f, w.toFloat(), h.toFloat())
        circle.reset()
        circle.addOval(rect, Path.Direction.CW)
    }

    override fun onDraw(canvas: Canvas) {
        // A round control on the pane. Same rule as the tiles: a fill, never a
        // second pane.
        drawPane(
            canvas, circle, rect,
            Ink.withAlpha(Color.WHITE, if (pal.dark) 0.11f else 0.24f),
            pal.rimTop, pal.rimBottom,
            max(1f, Density.d), paint,
        )
    }
}

/** A switch that belongs to the glass: pill track, raised thumb, accent when on. */
class GlassToggle(
    ctx: Context,
    var pal: Pal = Theme.current(ctx),
    checked: Boolean = true,
) : View(ctx) {

    var onChanged: ((Boolean) -> Unit)? = null
    private var t = if (checked) 1f else 0f
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val rect = RectF()

    var isOn: Boolean = checked
        private set

    fun setChecked(on: Boolean, animate: Boolean = true) {
        if (isOn == on && t == if (on) 1f else 0f) return
        isOn = on
        val from = t
        val to = if (on) 1f else 0f
        if (!animate) {
            t = to
            invalidate()
            return
        }
        ValueAnimator.ofFloat(from, to).apply {
            duration = 300
            interpolator = OvershootInterpolator(1.6f)
            addUpdateListener { t = (it.animatedValue as Float).coerceIn(0f, 1.08f); invalidate() }
            start()
        }
        invalidate()
    }

    init {
        setWillNotDraw(false)
        setOnClickListener {
            setChecked(!isOn)
            Motion.haptic(this, android.view.HapticFeedbackConstants.CONTEXT_CLICK)
            onChanged?.invoke(isOn)
        }
    }

    override fun onMeasure(w: Int, h: Int) {
        setMeasuredDimension(resolveSize(dpi(54f), w), resolveSize(dpi(32f), h))
    }

    override fun onSizeChanged(w: Int, h: Int, ow: Int, oh: Int) {
        rect.set(0f, 0f, w.toFloat(), h.toFloat())
    }

    override fun onDraw(canvas: Canvas) {
        val r = height / 2f
        val off = Ink.withAlpha(pal.textDim, if (pal.dark) 0.35f else 0.45f)
        paint.shader = null
        paint.color = Ink.mix(off, pal.accent, t.coerceIn(0f, 1f))
        canvas.drawRoundRect(rect, r, r, paint)

        paint.style = Paint.Style.STROKE
        paint.strokeWidth = max(1f, Density.d)
        paint.color = Ink.withAlpha(Color.WHITE, 0.24f + 0.16f * t)
        canvas.drawRoundRect(RectF(0.5f, 0.5f, width - 0.5f, height - 0.5f), r, r, paint)
        paint.style = Paint.Style.FILL

        val tr = r - dp(3.4f)
        val cx = r + (width - 2 * r) * t.coerceIn(0f, 1f)
        val cy = r
        Ink.glow(cx, cy + tr * 0.55f, tr * 1.7f, 0x4A060C22, paint)
        canvas.drawCircle(cx, cy + tr * 0.55f, tr * 1.7f, paint)

        val thumbRect = RectF(cx - tr, cy - tr, cx + tr, cy + tr)
        Ink.vertical(Color.WHITE, Ink.mix(Color.WHITE, pal.accent, 0.10f), thumbRect, paint)
        canvas.drawOval(thumbRect, paint)
        paint.shader = null
        paint.color = Ink.withAlpha(Color.WHITE, 0.9f)
        canvas.drawCircle(cx - tr * 0.25f, cy - tr * 0.35f, tr * 0.42f, paint)
    }
}

/**
 * Segmented control with a sliding glass thumb — the Mac's segmented picker,
 * used for Appearance and for the Send/Receive switch on the home screen.
 */
class Segmented(
    ctx: Context,
    private val items: List<String>,
    var pal: Pal = Theme.current(ctx),
    private val compact: Boolean = false,
) : FrameLayout(ctx) {

    var onSelect: ((Int) -> Unit)? = null
    var selected: Int = 0
        private set

    private val thumb = GlassCard(ctx, Tok.R_CONTROL, 2, lifted = true, pal = pal)
    private val labels = ArrayList<TextView>()
    private val track = Paint(Paint.ANTI_ALIAS_FLAG)
    private val rect = RectF()
    private var thumbX = 0f
    private var animator: ValueAnimator? = null

    init {
        setWillNotDraw(false)
        addView(thumb, LayoutParams(10, 10))
        val row = LinearLayout(ctx).apply { orientation = LinearLayout.HORIZONTAL }
        items.forEachIndexed { i, item ->
            val tv = TextView(ctx).apply {
                text = item
                gravity = Gravity.CENTER
                maxLines = 1
                isSingleLine = true
                style(if (compact) Type.CAPTION else Type.SUB, pal.textSecondary, Type.medium)
                setOnClickListener { select(i) }
            }
            labels.add(tv)
            row.addView(tv, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1f))
        }
        addView(row, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        refreshLabels()
    }

    fun setPalette(p: Pal) {
        pal = p
        invalidate()
    }

    fun select(index: Int, notify: Boolean = true) {
        if (index == selected) return
        selected = index
        refreshLabels()
        positionThumb(true)
        Motion.haptic(this, android.view.HapticFeedbackConstants.CLOCK_TICK)
        if (notify) onSelect?.invoke(index)
    }

    private fun refreshLabels() {
        labels.forEachIndexed { i, tv ->
            tv.setTextColor(if (i == selected) pal.textPrimary else pal.textDim)
            tv.typeface = if (i == selected) Type.medium else Type.regular
        }
    }

    override fun onMeasure(w: Int, h: Int) {
        val height = resolveSize(dpi(if (compact) 38f else 46f), h)
        val width = resolveSize(dpi(200f), w)
        childrenExactly(width, height)
        setMeasuredDimension(width, height)
    }

    override fun onSizeChanged(w: Int, h: Int, ow: Int, oh: Int) {
        rect.set(0f, 0f, w.toFloat(), h.toFloat())
        positionThumb(false)
    }

    private fun positionThumb(animate: Boolean) {
        if (width == 0) return
        val itemW = width.toFloat() / items.size
        val pad = dp(4f)
        val target = selected * itemW + pad
        val params = thumb.layoutParams as LayoutParams
        params.width = (itemW - pad * 2).toInt()
        params.height = height - dpi(8f)
        params.topMargin = dpi(4f)
        thumb.layoutParams = params
        animator?.cancel()
        if (!animate) {
            thumbX = target
            thumb.translationX = target
            return
        }
        animator = ValueAnimator.ofFloat(thumb.translationX, target).apply {
            duration = 330
            interpolator = Ease.out
            addUpdateListener { thumb.translationX = it.animatedValue as Float }
            start()
        }
    }

    override fun onDraw(canvas: Canvas) {
        val r = height / 2f
        track.shader = null
        track.color = pal.well
        canvas.drawRoundRect(rect, r, r, track)
        track.shader = LinearGradient(
            0f, 0f, 0f, height * 0.55f, 0x1A000000, 0x00000000, Shader.TileMode.CLAMP,
        )
        canvas.drawRoundRect(rect, r, r, track)
        track.shader = null
        track.style = Paint.Style.STROKE
        track.strokeWidth = max(1f, Density.d)
        track.color = pal.rimBottom
        canvas.drawRoundRect(RectF(0.5f, 0.5f, width - 0.5f, height - 0.5f), r, r, track)
        track.style = Paint.Style.FILL
    }
}

/**
 * The activity console: mono, timestamped, newest at the bottom, older lines
 * dimming back into the glass. The Mac prints this in its inspector; it is the
 * single most "engineered" looking thing in the window, so it stays.
 */
class ConsoleView(
    ctx: Context,
    var pal: Pal = Theme.current(ctx),
    private var heightDp: Float = 150f,
) : View(ctx) {

    private class Line(val time: String, val text: String, val color: Int)

    private val lines = ArrayList<Line>(84)
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val stamp = java.text.SimpleDateFormat("HH:mm:ss", java.util.Locale.US)
    private val sd get() = resources.displayMetrics.scaledDensity

    init {
        paint.typeface = Type.mono
        paint.textSize = Type.CAPTION * sd
    }

    fun log(text: String, color: Int = pal.textSecondary) {
        lines.add(Line(stamp.format(java.util.Date()), text, color))
        while (lines.size > 80) lines.removeAt(0)
        invalidate()
    }

    fun clear() {
        lines.clear()
        invalidate()
    }

    override fun onMeasure(w: Int, h: Int) {
        setMeasuredDimension(resolveSize(dpi(200f), w), resolveSize(dpi(heightDp), h))
    }

    override fun onDraw(canvas: Canvas) {
        if (lines.isEmpty()) return
        paint.typeface = Type.mono
        paint.textSize = Type.CAPTION * sd
        val lineH = paint.fontSpacing + dp(3.5f)
        val rows = max(1, (height / lineH).toInt())
        val visible = min(rows, lines.size)
        val start = lines.size - visible
        for (i in 0 until visible) {
            val line = lines[start + i]
            val y = height - (visible - 1 - i) * lineH - dp(2f)
            val fade = if (visible == 1) 1f else 0.34f + 0.66f * (i.toFloat() / (visible - 1))
            paint.color = Ink.withAlpha(pal.textDim, fade * 0.85f)
            canvas.drawText(line.time, 0f, y, paint)
            paint.color = Ink.withAlpha(line.color, fade)
            canvas.drawText(line.text, dpi(64f).toFloat(), y, paint)
        }
    }
}

// ── 6. Chrome ────────────────────────────────────────────────────────────

/**
 * The bottom dock — the Mac's row of round glass buttons, flattened into a
 * phone's tab bar. Selection slides a raised glass pill between items.
 */
class Dock(
    ctx: Context,
    private val icons: List<Ico>,
    private val labels: List<String>,
    var pal: Pal = Theme.current(ctx),
) : FrameLayout(ctx) {

    var onSelect: ((Int) -> Unit)? = null
    private val iconViews = ArrayList<IconView>()
    private val labelViews = ArrayList<TextView>()
    private val pill = GlassCard(ctx, 20f, 2, lifted = true, pal = pal)
    private val row = LinearLayout(ctx).apply { orientation = LinearLayout.HORIZONTAL }
    private var index = 0
    private var mover: ValueAnimator? = null

    init {
        setWillNotDraw(false)
        addView(pill)
        icons.forEachIndexed { i, ico ->
            val item = LinearLayout(ctx).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER
                isClickable = true
            }
            val iv = IconView(ctx, ico, 22f, pal.textDim, 1.8f)
            iconViews.add(iv)
            val tv = TextView(ctx).apply {
                text = labels[i]
                gravity = Gravity.CENTER
                maxLines = 1
                isSingleLine = true
                style(Type.MICRO, pal.textDim, Type.medium, 0.06f)
            }
            labelViews.add(tv)
            item.addView(iv, LinearLayout.LayoutParams(dpi(22f), dpi(22f)))
            item.addView(tv, LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT,
            ).apply { topMargin = dpi(3f) })
            item.setOnClickListener { select(i, true) }
            row.addView(item, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1f))
        }
        addView(row, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        paintIcons()
    }

    fun setPalette(p: Pal) {
        pal = p
        paintIcons()
        invalidate()
    }

    fun select(i: Int, notify: Boolean) {
        if (i == index && notify) return
        index = i
        paintIcons()
        position(true)
        Motion.haptic(this, android.view.HapticFeedbackConstants.CLOCK_TICK)
        if (notify) onSelect?.invoke(i)
    }

    private fun paintIcons() {
        iconViews.forEachIndexed { i, iv ->
            iv.color = if (i == index) pal.accent else pal.textDim
            iv.invalidate()
        }
        labelViews.forEachIndexed { i, tv ->
            tv.setTextColor(if (i == index) pal.accent else pal.textDim)
        }
    }

    override fun onMeasure(w: Int, h: Int) {
        val height = resolveSize(dpi(62f), h)
        val width = resolveSize(dpi(300f), w)
        // The pill is placed by hand below, so only the tab row needs measuring.
        row.measure(
            View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.EXACTLY),
        )
        pill.measure(
            View.MeasureSpec.makeMeasureSpec(width / icons.size, View.MeasureSpec.AT_MOST),
            View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.AT_MOST),
        )
        setMeasuredDimension(width, height)
    }

    override fun onSizeChanged(w: Int, h: Int, ow: Int, oh: Int) {
        position(false)
    }

    private fun position(animate: Boolean) {
        if (width == 0) return
        val itemW = width.toFloat() / icons.size
        val pad = dp(10f)
        val target = index * itemW + pad
        val params = pill.layoutParams as LayoutParams
        params.width = (itemW - pad * 2).toInt()
        params.height = height - dpi(10f)
        params.topMargin = dpi(5f)
        pill.layoutParams = params
        mover?.cancel()
        if (!animate) {
            pill.translationX = target
            return
        }
        mover = ValueAnimator.ofFloat(pill.translationX, target).apply {
            duration = 340
            interpolator = Ease.out
            addUpdateListener { pill.translationX = it.animatedValue as Float }
            start()
        }
    }

    override fun onDraw(canvas: Canvas) {
        // the dock's own glass is the caller's card; nothing to paint here
    }
}

/**
 * A bottom sheet on glass. Rises with a spring, dismisses on scrim tap, drag,
 * or the system back gesture. Content is whatever the caller builds.
 */
class Sheet(ctx: Context, var pal: Pal = Theme.current(ctx)) : FrameLayout(ctx) {

    var onDismissed: (() -> Unit)? = null
    private val scrim = View(ctx).apply { setBackgroundColor(pal.scrim) }
    private val holder = FrameLayout(ctx)
    private var dismissing = false

    init {
        addView(scrim, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        addView(holder, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT).apply {
            gravity = Gravity.BOTTOM
        })
        scrim.setOnClickListener { dismiss() }
    }

    fun content(view: View) {
        holder.removeAllViews()
        holder.addView(view, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply {
            gravity = Gravity.BOTTOM
        })
    }

    /** The handle at the top of the sheet drags it down to dismiss. */
    fun dragHandle(handle: View) {
        var startY = 0f
        var startT = 0f
        handle.setOnTouchListener { _, ev ->
            when (ev.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    startY = ev.rawY
                    startT = holder.translationY
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dy = max(0f, startT + (ev.rawY - startY))
                    holder.translationY = dy
                    scrim.alpha = (1f - (dy / dp(240f)).coerceIn(0f, 0.75f))
                    true
                }
                MotionEvent.ACTION_UP -> {
                    if (holder.translationY > dp(92f)) dismiss() else springBack()
                    true
                }
                else -> false
            }
        }
    }

    private fun springBack() {
        holder.animate().translationY(0f).setDuration(300).setInterpolator(Ease.settle).start()
        scrim.animate().alpha(1f).setDuration(300).start()
    }

    fun present() {
        dismissing = false
        translationY = 0f
        alpha = 1f
        holder.translationY = 0f
        post { Motion.sheetIn(holder, scrim) }
    }

    fun dismiss() {
        if (dismissing) return
        dismissing = true
        Motion.haptic(this)
        Motion.sheetOut(holder, scrim) {
            (parent as? ViewGroup)?.removeView(this)
            onDismissed?.invoke()
        }
    }
}


