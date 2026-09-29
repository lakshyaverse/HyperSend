package com.hypersend.app

import android.content.Context
import android.content.res.Configuration
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RadialGradient
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import android.view.HapticFeedbackConstants
import android.view.View
import android.view.animation.DecelerateInterpolator
import android.view.animation.OvershootInterpolator
import android.view.animation.PathInterpolator
import android.widget.TextView
import kotlin.math.min
import kotlin.math.roundToInt

// HyperSend for Android — the design system.
//
// This is the twin of mac/Sources/UI/Tokens.swift. The Mac window is the
// reference: a sky behind everything, glass that sits *on* the sky, a hairline
// rim that catches light at the top edge, ONE accent that belongs to the data,
// lanes in their own tints, and mono type for anything a machine produced.
//
// Where the Mac gets Apple's real Liquid Glass material, Android gets paint:
// SceneView builds the sky out of gradients plus grain (Widgets.kt), and every
// panel is drawn as body + sheen + specular rim + shadow. Same read, different
// machinery.
//
// Everything here is platform-only. No Material, no Compose, no icon font —
// the icons in Icons below are vector paths on a 24-unit grid, drawn by hand.

/** Device density, set once from the Activity before any view is built. */
object Density {
    @Volatile var d: Float = 2.6f

    fun init(ctx: Context) { d = ctx.resources.displayMetrics.density }
}

fun dp(v: Int): Int = (v * Density.d).roundToInt()
fun dp(v: Float): Float = v * Density.d
fun dpi(v: Float): Int = (v * Density.d).roundToInt()

// ── Palette ──────────────────────────────────────────────────────────────
//
// Light is the Mac's pastel sky; dark is its indigo night. The sky is
// deliberately a step deeper than the panels so the glass separates — panels
// that sit at the same value as the scene are the reason a glass UI can look
// like flat grey mush.

class Pal(
    val dark: Boolean,
    // the scene
    val skyTop: Int, val skyMid: Int, val skyBottom: Int,
    val bloomA: Int, val bloomB: Int, val bloomC: Int, val grainAlpha: Int,
    /** How far the blooms spread, as a fraction of the window. Dark wants
     *  them wide and faint; light wants the warm one local, or the whole sky
     *  turns to grey soup. */
    val bloomSpread: Float,
    // glass
    /**
     * How far the material pulls the backdrop toward neutral.
     *
     * The one number that decides whether a pane reads as glass or as a white
     * sticker, and the only one that can actually be measured. Sampling across
     * a panel's edge on the Mac — the one place the backdrop and the pane sit
     * side by side — the material takes its backdrop a *fifth* of the way to
     * neutral, in both light and dark:
     *
     *     light  sky #BED0DD -> pane #C7D5E0    (chroma 0.140 -> 0.112)
     *     dark   sky #262D4A -> pane #455072    (chroma 0.493 -> 0.395)
     *
     * Guessing this number is how you end up with chalky cards: too little and
     * the pane is just the sky, too much and every surface turns to grey mush.
     */
    val desat: Float,
    val panel: Int, val panelRaised: Int, val well: Int, val rail: Int,
    val rimTop: Int, val rimBottom: Int, val shadow: Int, val sheen: Int,
    // type
    val textPrimary: Int, val textSecondary: Int, val textDim: Int,
    // the one accent, and the lanes
    val accent: Int, val accentSoft: Int, val onAccent: Int,
    val wifi: Int, val usb: Int, val ok: Int, val warn: Int, val bad: Int,
    val track: Int, val scrim: Int,
    val lightBars: Boolean,
)

/**
 * Dark mode, sampled off the Mac window.
 *
 * The backdrop is not flat: it runs #2F3856 at the top edge down to #191E37 at
 * the bottom, with a soft indigo bloom up the left. Measured across a panel's
 * edge, the pane lifts its backdrop by 33 luma and pulls its chroma down by a
 * fifth — which is white, slightly cooled, at 16%.
 */
object ThemeDark {
    val pal = Pal(
        dark = true,
        skyTop = 0xFF303A58.toInt(),
        skyMid = 0xFF232B47.toInt(),
        skyBottom = 0xFF181D35.toInt(),
        bloomA = 0x3A4E68C8.toInt(),
        bloomB = 0x2E6A5AA8.toInt(),
        bloomC = 0x1CFFFFFF,
        grainAlpha = 10,
        bloomSpread = 1f,
        desat = 0.20f,
        // Cool white at 16% — the measured lift. The coolness is not decorative:
        // a plain white overlay leaves the pane short in blue against the Mac.
        panel = 0x29F2F6FF,
        panelRaised = 0x33F2F6FF,
        well = 0x1F000000,
        rail = 0x1FFFFFFF,
        // A whisper, for the flat overlays. The real material paints no rim at
        // all: sampling straight down through a Mac panel's top edge is a
        // smooth monotone ramp with no overshoot anywhere in it.
        rimTop = 0x2BFFFFFF,
        rimBottom = 0x0EFFFFFF,
        shadow = 0x66040A1E,
        sheen = 0x0CFFFFFF,
        textPrimary = 0xFFF2F4FA.toInt(),
        textSecondary = 0xFFAEB6CE.toInt(),
        textDim = 0xFF7C84A0.toInt(),
        accent = 0xFF0A84FF.toInt(),
        accentSoft = 0x330A84FF,
        onAccent = 0xFFFFFFFF.toInt(),
        wifi = 0xFF4C9BFF.toInt(),
        usb = 0xFF30D158.toInt(),
        ok = 0xFF30D158.toInt(),
        warn = 0xFFFFD15C.toInt(),
        bad = 0xFFFF6961.toInt(),
        track = 0x26FFFFFF,
        scrim = 0xA6000000.toInt(),
        lightBars = false,
    )
}

/**
 * Light mode, sampled off the Mac window on the same grid.
 *
 * The sky is a cyan (#B2D7ED) at the top that turns periwinkle (#98C3FF) at the
 * bottom — not the flat blue the old palette used. A panel over it reads
 * #CEDADC: *lighter* than the sky in red, *darker* in blue, and almost entirely
 * neutral. No amount of white tint can produce that; you have to desaturate
 * first and lighten second, which is what [Pal.desat] does.
 *
 * Across a panel's edge the pane takes #BED0DD to #C7D5E0: chroma 0.140 down to
 * 0.112, luma 204 up to 211. That is a fifth of the way to neutral, then 12.5%
 * white — and it is the whole reason these panels read as glass rather than as
 * white stickers. Accent is Apple #007AFF.
 */
object ThemeLight {
    val pal = Pal(
        dark = false,
        skyTop = 0xFFB7D8EE.toInt(),
        skyMid = 0xFFA9CEF6.toInt(),
        skyBottom = 0xFF99C0FF.toInt(),
        bloomA = 0x40FFE9D2.toInt(),
        bloomB = 0x2AFFF0E0.toInt(),
        bloomC = 0x26FFFFFF,
        grainAlpha = 11,
        bloomSpread = 0.62f,
        desat = 0.20f,
        panel = 0x20FFFFFF,
        panelRaised = 0x29FFFFFF,
        well = 0x14000000,
        rail = 0x38FFFFFF,
        // A 1 px hairline for definition, not an outline. The old rim was 95%
        // white and, with the sheen cone stacked on top of it, drew a blown-out
        // opaque halo around every card — the single most "not glass" thing in
        // the app, and the reason the edges read as painted on.
        rimTop = 0x3DFFFFFF,
        rimBottom = 0x14FFFFFF,
        shadow = 0x1F1A2A4D,
        sheen = 0x0CFFFFFF,
        textPrimary = 0xFF14161C.toInt(),
        textSecondary = 0xFF53596B.toInt(),
        textDim = 0xFF868C9E.toInt(),
        accent = 0xFF007AFF.toInt(),
        accentSoft = 0x24007AFF,
        onAccent = 0xFFFFFFFF.toInt(),
        wifi = 0xFF007AFF.toInt(),
        usb = 0xFF34C759.toInt(),
        ok = 0xFF34C759.toInt(),
        warn = 0xFFE8A33D.toInt(),
        bad = 0xFFE5484D.toInt(),
        track = 0x1F14161C,
        scrim = 0x5C0B1230,
        lightBars = true,
    )
}

object Theme {

    /** 0 = follow the system, 1 = force light, 2 = force dark. */
    @Volatile var override: Int = 0

    const val OVERRIDE_SYSTEM = 0
    const val OVERRIDE_LIGHT = 1
    const val OVERRIDE_DARK = 2

    fun load(ctx: Context) {
        override = ctx.getSharedPreferences("hypersend", Context.MODE_PRIVATE)
            .getInt("themeOverride", 0)
    }

    fun save(ctx: Context, value: Int) {
        override = value
        ctx.getSharedPreferences("hypersend", Context.MODE_PRIVATE)
            .edit().putInt("themeOverride", value).apply()
    }

    fun current(ctx: Context): Pal = when (override) {
        OVERRIDE_LIGHT -> ThemeLight.pal
        OVERRIDE_DARK -> ThemeDark.pal
        else -> {
            val night = ctx.resources.configuration.uiMode and
                Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
            if (night) ThemeDark.pal else ThemeLight.pal
        }
    }
}

// ── Tokens ───────────────────────────────────────────────────────────────

object Tok {
    /** Panels are big and soft; controls are tight; pills are stadium. */
    const val R_PANEL = 28f
    const val R_CARD = 20f
    const val R_CONTROL = 14f
    const val R_TILE = 12f
    const val R_PILL = 999f

    /** The 4-point rhythm the Mac app uses, in dp. */
    const val S1 = 4f
    const val S2 = 8f
    const val S3 = 12f
    const val S4 = 16f
    const val S5 = 20f
    const val S6 = 28f
    const val S7 = 40f

    /** Content gutter. */
    const val GUTTER = 18f
}

// ── Continuous corners ───────────────────────────────────────────────────

/**
 * Continuous corners — the curve Apple calls `.continuous`, and the single
 * biggest reason a rounded rectangle reads as Apple rather than as Android.
 *
 * A plain rounded rect is a quarter circle of radius R: the curve *begins* R
 * points in from the corner. Apple's continuous corner keeps a curve that
 * looks the same radius but starts turning much further out along each edge,
 * so the straight runs are shorter and the corner is a longer, flatter sweep.
 * That is why the Mac's panels look soft where a round-rect looks punched.
 *
 * One cubic per corner, tangent to both edges:
 *
 *   - the turn begins at `EXTENT * R` from the corner, EXTENT = 1.528 — the
 *     factor Apple's own continuous corners use;
 *   - its control points sit `FULLNESS` of that span, FULLNESS = 0.822, which
 *     puts the curve's 45° point exactly 0.2929 R from the corner. That is
 *     precisely where a circular corner of radius R would sit, so the corner
 *     keeps the *visual* radius it was asked for while gaining the longer,
 *     softer sweep. Solve `p/2 - 3a/8 = R(1 - 1/√2)` for a to get the 0.822.
 *
 * A capsule is the exception: when the radius reaches half the short side the
 * ends must be true semicircles, so it switches to the classic circle
 * approximation instead.
 */
object Corners {

    /** Where the turn begins, as a multiple of the radius. */
    private const val EXTENT = 1.528f

    /** Corner fullness for an ordinary card — see the object note. */
    private const val FULLNESS = 0.822f

    /** The circle approximation, for ends that have to be semicircles. */
    private const val ROUND = 0.5523f

    /** Rebuilds [out] as the continuous-corner outline of this box. */
    fun path(out: Path, l: Float, t: Float, r: Float, b: Float, radius: Float): Path {
        out.reset()
        val w = r - l
        val h = b - t
        if (w <= 0f || h <= 0f) return out

        val half = min(w, h) * 0.5f
        val rad = radius.coerceIn(0f, half)
        val span = min(rad * EXTENT, half)
        if (span <= 0.01f) {
            out.addRect(l, t, r, b, Path.Direction.CW)
            return out
        }
        // A radius that wants to reach past the short side is a capsule, not a
        // squircle: keep the fuller sweep only where there is room for it.
        val k = if (rad * EXTENT > half) ROUND else FULLNESS
        val a = span * k

        // Clockwise from the top edge.
        out.moveTo(l + span, t)
        out.lineTo(r - span, t)
        out.cubicTo(r - span + a, t, r, t + span - a, r, t + span)
        out.lineTo(r, b - span)
        out.cubicTo(r, b - span + a, r - span + a, b, r - span, b)
        out.lineTo(l + span, b)
        out.cubicTo(l + span - a, b, l, b - span + a, l, b - span)
        out.lineTo(l, t + span)
        out.cubicTo(l, t + span - a, l + span - a, t, l + span, t)
        out.close()
        return out
    }
}

/**
 * A cached silhouette.
 *
 * Every glass surface outlines itself several times per frame — the lens, the
 * sheen, the rim, the shadow — and a continuous corner is four cubics rather
 * than a cheap `drawRoundRect`. Rebuilding it per draw would allocate a path
 * per layer per frame, so this keeps one and only rebuilds when the size or
 * radius actually moves.
 */
class Shape {

    private val built = Path()
    private var keyW = -1
    private var keyH = -1
    private var keyR = -1f

    /** The outline of a view of this size, with its radius in dp. */
    fun of(w: Int, h: Int, radiusDp: Float): Path = build(w, h, dpi(radiusDp).toFloat())

    /** Same, for surfaces whose radius is already half their height — pills. */
    fun ofPx(w: Int, h: Int, radiusPx: Float): Path = build(w, h, radiusPx)

    private fun build(w: Int, h: Int, radiusPx: Float): Path {
        if (w == keyW && h == keyH && radiusPx == keyR) return built
        Corners.path(built, 0f, 0f, w.toFloat(), h.toFloat(), radiusPx)
        keyW = w
        keyH = h
        keyR = radiusPx
        return built
    }
}

/** Type scale, in sp. Mobile is one step up from the Mac's desktop sizes. */
object Type {
    const val DISPLAY = 40f
    const val TITLE = 26f
    const val HEADLINE = 20f
    const val CARD = 17f
    const val BODY = 15f
    const val SUB = 13.5f
    const val CAPTION = 12f
    const val MICRO = 10.5f

    val medium: Typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
    val regular: Typeface = Typeface.create("sans-serif", Typeface.NORMAL)
    val mono: Typeface = Typeface.create("monospace", Typeface.NORMAL)
    val monoMedium: Typeface = Typeface.create("monospace", Typeface.BOLD)
}

/** Style a TextView in one call, so no view invents its own type. */
fun TextView.style(
    size: Float,
    color: Int,
    face: Typeface = Type.regular,
    tracking: Float = 0f,
    lineSpacing: Float = 1.18f,
): TextView {
    setTextSize(android.util.TypedValue.COMPLEX_UNIT_SP, size)
    setTextColor(color)
    typeface = face
    letterSpacing = tracking
    setLineSpacing(0f, lineSpacing)
    return this
}

/** Section label: micro, tracked out, dim — "DEVICES", "LANES". */
fun TextView.capsStyle(color: Int): TextView {
    setTextSize(android.util.TypedValue.COMPLEX_UNIT_SP, Type.MICRO)
    setTextColor(color)
    typeface = Type.medium
    letterSpacing = 0.14f
    return this
}

// ── Motion ───────────────────────────────────────────────────────────────
//
// The twin of mac/Sources/UI/Animations.swift: one owner for every bit of
// movement in the app, so nothing wobbles at a different tempo than anything
// else. Enter = decelerate. Settle = a slight overshoot. Ambient = slow sine.

object Ease {
    /** The house curve, everywhere: cubic-bezier(0.32, 0.72, 0, 1). */
    val out = PathInterpolator(0.32f, 0.72f, 0f, 1f)
    val inOut = PathInterpolator(0.65f, 0f, 0.35f, 1f)
    val softOut = DecelerateInterpolator(1.6f)
    val settle = OvershootInterpolator(1.15f)
    val press = DecelerateInterpolator()
}

object Motion {

    const val FAST = 140
    const val MED = 280
    const val SLOW = 420

    fun haptic(v: View, kind: Int = HapticFeedbackConstants.KEYBOARD_TAP) {
        v.performHapticFeedback(kind)
    }

    /**
     * Squish on touch-down, spring past 1.0 on release. Every tappable thing.
     * The listener returns false so the view's own click handling still runs —
     * call this *before* setting the click listener, or after; either order is
     * fine because nothing here consumes the event.
     */
    fun pressable(view: View, scale: Float = 0.955f, haptic: Boolean = true) {
        view.setOnTouchListener { v, ev ->
            when (ev.actionMasked) {
                android.view.MotionEvent.ACTION_DOWN -> {
                    v.animate().scaleX(scale).scaleY(scale).setDuration(110L)
                        .setInterpolator(Ease.press).start()
                    if (haptic) {
                        v.performHapticFeedback(android.view.HapticFeedbackConstants.KEYBOARD_TAP)
                    }
                }
                android.view.MotionEvent.ACTION_UP,
                android.view.MotionEvent.ACTION_CANCEL -> {
                    v.animate().scaleX(1f).scaleY(1f).setDuration(MED.toLong())
                        .setInterpolator(Ease.settle).start()
                }
            }
            false
        }
    }

    fun settleBack(v: View) {
        v.animate().scaleX(1f).scaleY(1f).setDuration(260)
            .setInterpolator(Ease.settle).start()
    }

    /** Cards float up 46 ms apart — the Mac's entrance cascade. */
    fun cascade(views: List<View>, delay: Long = 70, step: Long = 46) {
        views.forEachIndexed { i, v ->
            v.alpha = 0f
            v.translationY = dp(22f)
            v.animate().alpha(1f).translationY(0f)
                .setStartDelay(delay + i * step)
                .setDuration(SLOW.toLong())
                .setInterpolator(Ease.out)
                .start()
        }
    }

    /** Enter from the bottom, exit to the top — a page push. */
    fun pageIn(v: View, fromRight: Boolean) {
        v.alpha = 0f
        v.translationX = dp(if (fromRight) 34f else -34f)
        v.animate().alpha(1f).translationX(0f).setDuration(MED.toLong())
            .setInterpolator(Ease.out).start()
    }

    fun pageOut(v: View, toRight: Boolean, onEnd: () -> Unit) {
        v.animate().alpha(0f).translationX(dp(if (toRight) 26f else -26f))
            .setDuration(190).setInterpolator(Ease.inOut)
            .withEndAction(onEnd).start()
    }

    /** The sheet's spring: rise, then settle with a touch of weight. */
    fun sheetIn(sheet: View, scrim: View) {
        sheet.translationY = dp(90f)
        sheet.alpha = 0.4f
        sheet.animate().translationY(0f).alpha(1f).setDuration(380)
            .setInterpolator(Ease.out).start()
        scrim.alpha = 0f
        scrim.animate().alpha(1f).setDuration(300).start()
    }

    fun sheetOut(sheet: View, scrim: View, onEnd: () -> Unit) {
        sheet.animate().translationY(dp(120f)).alpha(0f).setDuration(240)
            .setInterpolator(Ease.inOut).withEndAction(onEnd).start()
        scrim.animate().alpha(0f).setDuration(240).start()
    }

    /** One expanding ring from a view — the send pulse. */
    fun ringPulse(host: android.view.ViewGroup, cx: Float, cy: Float, diameter: Int, color: Int, stroke: Float = 2f) {
        val ring = android.view.View(host.context)
        val d = android.graphics.drawable.GradientDrawable().apply {
            shape = android.graphics.drawable.GradientDrawable.OVAL
            setStroke(dpi(stroke), color)
        }
        ring.background = d
        val left = (cx - diameter / 2f).toInt()
        val top = (cy - diameter / 2f).toInt()
        // The host may be a FrameLayout or a LinearLayout; each insists on its
        // own LayoutParams type, so build the one it wants.
        val lp: android.view.ViewGroup.LayoutParams = when (host) {
            is android.widget.FrameLayout -> android.widget.FrameLayout.LayoutParams(diameter, diameter).apply {
                leftMargin = left
                topMargin = top
            }
            else -> android.widget.LinearLayout.LayoutParams(diameter, diameter).apply {
                leftMargin = left
                topMargin = top
                gravity = android.view.Gravity.CENTER
            }
        }
        host.addView(ring, lp)
        ring.scaleX = 0.55f
        ring.scaleY = 0.55f
        ring.alpha = 0.95f
        ring.animate().scaleX(2.3f).scaleY(2.3f).alpha(0f).setDuration(720)
            .setInterpolator(Ease.out).withEndAction { host.removeView(ring) }.start()
    }

    /** Living dot: breathes while on, steady while off. */
    fun dotPulse(view: View, on: Boolean) {
        (view.tag as? android.animation.ValueAnimator)?.cancel()
        view.tag = null
        if (!on) {
            view.alpha = 1f
            return
        }
        val a = android.animation.ValueAnimator.ofFloat(1f, 0.35f, 1f).apply {
            duration = 1500
            repeatCount = android.animation.ValueAnimator.INFINITE
            addUpdateListener { view.alpha = it.animatedValue as Float }
            start()
        }
        view.tag = a
    }
}

/** Color helpers the painters share. */
object Ink {
    fun withAlpha(color: Int, alpha: Float): Int =
        Color.argb((alpha * 255f).roundToInt().coerceIn(0, 255), Color.red(color), Color.green(color), Color.blue(color))

    /**
     * Blends two colours, keeping the FIRST one's alpha. That detail is what
     * makes dark glass possible: the dark palette's panels are white at 8%
     * opacity, so a plain RGB blend would hand back solid white and every
     * panel would flash opaque.
     */
    fun mix(a: Int, b: Int, t: Float): Int = Color.argb(
        Color.alpha(a),
        (Color.red(a) + (Color.red(b) - Color.red(a)) * t).roundToInt().coerceIn(0, 255),
        (Color.green(a) + (Color.green(b) - Color.green(a)) * t).roundToInt().coerceIn(0, 255),
        (Color.blue(a) + (Color.blue(b) - Color.blue(a)) * t).roundToInt().coerceIn(0, 255),
    )

    fun vertical(top: Int, bottom: Int, rect: RectF, paint: Paint) {
        paint.shader = LinearGradient(
            0f, rect.top, 0f, rect.bottom, top, bottom, Shader.TileMode.CLAMP,
        )
    }

    /** The specular rim: bright at the top edge, gone by the hips. */
    fun rim(rect: RectF, top: Int, bottom: Int, paint: Paint) {
        paint.shader = LinearGradient(
            0f, rect.top, 0f, rect.top + rect.height() * 0.85f, top, bottom, Shader.TileMode.CLAMP,
        )
    }

    fun glow(cx: Float, cy: Float, r: Float, color: Int, paint: Paint) {
        paint.shader = RadialGradient(
            cx, cy, r, intArrayOf(color, withAlpha(color, 0.45f), withAlpha(color, 0f)),
            floatArrayOf(0f, 0.45f, 1f), Shader.TileMode.CLAMP,
        )
    }

    /**
     * A soft penumbra under a silhouette.
     *
     * Framework `elevation` throws the hard, near-black band Material wants;
     * glass floats on something much wider and weaker. This stacks concentric
     * copies of the outline whose alpha falls off quadratically, which
     * approximates a Gaussian closely enough to read as a real shadow.
     *
     * Takes the outline rather than a rect so the penumbra follows a continuous
     * corner instead of cutting across it — a square-ish shadow under a soft
     * corner is exactly the kind of mismatch that reads as "off" without
     * anyone being able to say why.
     *
     * Deliberately no BlurMaskFilter: on a hardware-accelerated canvas it is
     * silently ignored for shapes, so the "blur" would collapse into exactly
     * the hard bands this is meant to avoid.
     */
    fun shadow(
        canvas: Canvas,
        outline: Path,
        bounds: RectF,
        color: Int,
        spread: Float,
        dy: Float,
        paint: Paint,
    ) {
        val peak = Color.alpha(color) / 255f
        val w = bounds.width()
        val h = bounds.height()
        if (peak <= 0f || spread <= 0f || w <= 1f || h <= 1f) return
        val steps = 10
        val cx = bounds.centerX()
        val cy = bounds.centerY()
        val wasShader = paint.shader
        paint.shader = null
        for (i in steps downTo 1) {
            val t = i / steps.toFloat()
            val grow = spread * (t * t)
            paint.color = withAlpha(color, peak * (1f - t) * 0.30f)
            // Grow in place: scaling about the centre widens the penumbra
            // without moving the silhouette, so the shadow stays concentric.
            canvas.save()
            canvas.translate(cx, cy + dy)
            canvas.scale((w + grow * 2f) / w, (h + grow * 2f) / h)
            canvas.translate(-cx, -cy)
            canvas.drawPath(outline, paint)
            canvas.restore()
        }
        paint.shader = wasShader
    }
}

// ── Icons ────────────────────────────────────────────────────────────────
//
// The Mac uses SF Symbols. Android has no dependency-free equivalent, and an
// icon font or a PNG set would be dead weight in a zero-dependency app — so
// these are stroked vector paths on a 24-unit grid, drawn by hand to match the
// Mac's symbols: wifi, cable.connector, folder, arrow.down/up, gearshape,
// shield, bolt, laptopcomputer, iphone. Round caps, round joins, 1.7 units of
// stroke — the same optical weight as the system set.

enum class Ico {
    WIFI, USB, FOLDER, DOWNLOAD, UPLOAD, GEAR, PLUS, CHECK, CHEVRON, X,
    FILE, PHONE, LAPTOP, SHIELD, BOLT, SHARE, REFRESH, HOUSE, CLOCK, GAUGE,
    TRASH, IMAGE, MUSIC, VIDEO, ARCHIVE, GRID, WAVE, SUN, MOON, INFO,
    ARROW_UP, ARROW_DOWN, DOT, POWER, LINK, SEARCH,
}

object Icons {

    private val scratch = Path()

    private fun poly(vararg v: Float): Path {
        val p = Path()
        p.moveTo(v[0], v[1])
        var i = 2
        while (i < v.size) { p.lineTo(v[i], v[i + 1]); i += 2 }
        return p
    }

    private fun line(c: Canvas, p: Paint, x1: Float, y1: Float, x2: Float, y2: Float) {
        c.drawLine(x1, y1, x2, y2, p)
    }

    private fun strokes(c: Canvas, p: Paint, path: Path) {
        p.style = Paint.Style.STROKE
        c.drawPath(path, p)
    }

    private fun fills(c: Canvas, p: Paint, path: Path) {
        p.style = Paint.Style.FILL
        c.drawPath(path, p)
    }

    private fun circle(c: Canvas, p: Paint, cx: Float, cy: Float, r: Float) {
        p.style = Paint.Style.STROKE
        c.drawCircle(cx, cy, r, p)
    }

    private fun dot(c: Canvas, p: Paint, cx: Float, cy: Float, r: Float) {
        p.style = Paint.Style.FILL
        c.drawCircle(cx, cy, r, p)
    }

    private fun arc(c: Canvas, p: Paint, cx: Float, cy: Float, r: Float, start: Float, sweep: Float) {
        p.style = Paint.Style.STROKE
        c.drawArc(RectF(cx - r, cy - r, cx + r, cy + r), start, sweep, false, p)
    }

    private fun rr(c: Canvas, p: Paint, l: Float, t: Float, r: Float, b: Float, rad: Float, filled: Boolean = false) {
        p.style = if (filled) Paint.Style.FILL else Paint.Style.STROKE
        c.drawRoundRect(RectF(l, t, r, b), rad, rad, p)
    }

    fun draw(c: Canvas, p: Paint, name: Ico) {
        when (name) {
            Ico.WIFI -> {
                arc(c, p, 12f, 18.4f, 10.4f, 218f, 104f)
                arc(c, p, 12f, 18.4f, 6.9f, 218f, 104f)
                arc(c, p, 12f, 18.4f, 3.4f, 218f, 104f)
                dot(c, p, 12f, 19.2f, 1.05f)
            }
            Ico.USB -> {
                line(c, p, 12f, 4.6f, 12f, 19.2f)
                fills(c, p, poly(9.2f, 8.6f, 12f, 4.2f, 14.8f, 8.6f))
                dot(c, p, 12f, 20.6f, 1.9f)
                strokes(c, p, poly(12f, 12.6f, 7.6f, 10.2f))
                p.style = Paint.Style.FILL
                c.drawRoundRect(RectF(5.6f, 8.4f, 7.9f, 10.7f), 0.5f, 0.5f, p)
                strokes(c, p, poly(12f, 15.6f, 16.2f, 13.4f))
                circle(c, p, 17f, 12.4f, 1.5f)
            }
            Ico.FOLDER -> {
                rr(c, p, 3.2f, 5.6f, 11.4f, 11f, 2.2f)
                rr(c, p, 3.2f, 7.8f, 20.8f, 19.6f, 3.4f)
            }
            Ico.DOWNLOAD -> {
                line(c, p, 12f, 3.4f, 12f, 14.4f)
                strokes(c, p, poly(7.8f, 10.2f, 12f, 14.4f, 16.2f, 10.2f))
                strokes(c, p, Path().apply {
                    moveTo(4.4f, 15.2f); lineTo(4.4f, 17.2f)
                    quadTo(4.4f, 19.8f, 7f, 19.8f); lineTo(17f, 19.8f)
                    quadTo(19.6f, 19.8f, 19.6f, 17.2f); lineTo(19.6f, 15.2f)
                })
            }
            Ico.UPLOAD -> {
                line(c, p, 12f, 20.4f, 12f, 9.4f)
                strokes(c, p, poly(7.8f, 13.6f, 12f, 9.4f, 16.2f, 13.6f))
                strokes(c, p, Path().apply {
                    moveTo(4.4f, 8.6f); lineTo(4.4f, 6.6f)
                    quadTo(4.4f, 4f, 7f, 4f); lineTo(17f, 4f)
                    quadTo(19.6f, 4f, 19.6f, 6.6f); lineTo(19.6f, 8.6f)
                })
            }
            Ico.GEAR -> {
                circle(c, p, 12f, 12f, 9.6f)
                circle(c, p, 12f, 12f, 3.5f)
                for (i in 0 until 8) {
                    val a = Math.toRadians((i * 45).toDouble())
                    val cos = Math.cos(a).toFloat()
                    val sin = Math.sin(a).toFloat()
                    line(c, p, 12f + cos * 7.3f, 12f + sin * 7.3f, 12f + cos * 9.6f, 12f + sin * 9.6f)
                }
            }
            Ico.PLUS -> {
                line(c, p, 12f, 5.2f, 12f, 18.8f)
                line(c, p, 5.2f, 12f, 18.8f, 12f)
            }
            Ico.CHECK -> strokes(c, p, poly(4.8f, 12.6f, 9.8f, 17.6f, 19.2f, 6.4f))
            Ico.CHEVRON -> strokes(c, p, poly(9.6f, 5.4f, 16.2f, 12f, 9.6f, 18.6f))
            Ico.X -> {
                line(c, p, 6.2f, 6.2f, 17.8f, 17.8f)
                line(c, p, 17.8f, 6.2f, 6.2f, 17.8f)
            }
            Ico.FILE -> {
                strokes(c, p, Path().apply {
                    moveTo(6.6f, 3.4f); lineTo(13.4f, 3.4f); lineTo(17.6f, 7.6f)
                    lineTo(17.6f, 18.6f); quadTo(17.6f, 20.6f, 15.6f, 20.6f)
                    lineTo(8.6f, 20.6f); quadTo(6.6f, 20.6f, 6.6f, 18.6f); close()
                })
                strokes(c, p, poly(13.4f, 3.6f, 13.4f, 7.8f, 17.4f, 7.8f))
                line(c, p, 9.4f, 12.6f, 14.8f, 12.6f)
                line(c, p, 9.4f, 16f, 13.4f, 16f)
            }
            Ico.PHONE -> {
                rr(c, p, 7f, 2.6f, 17f, 21.4f, 2.8f)
                line(c, p, 10.6f, 18.6f, 13.4f, 18.6f)
            }
            Ico.LAPTOP -> {
                rr(c, p, 4.8f, 4.8f, 19.2f, 15.4f, 1.8f)
                line(c, p, 2.4f, 17.8f, 21.6f, 17.8f)
                line(c, p, 10.2f, 20.2f, 13.8f, 20.2f)
            }
            Ico.SHIELD -> {
                strokes(c, p, Path().apply {
                    moveTo(12f, 3.2f); lineTo(20f, 6f); lineTo(20f, 11.4f)
                    cubicTo(20f, 16.2f, 16.4f, 19f, 12f, 21f)
                    cubicTo(7.6f, 19f, 4f, 16.2f, 4f, 11.4f); lineTo(4f, 6f); close()
                })
                strokes(c, p, poly(8.6f, 11.6f, 11.2f, 14.2f, 15.6f, 9.4f))
            }
            Ico.BOLT -> fills(c, p, poly(13.4f, 2.4f, 5.2f, 13.4f, 10.6f, 13.4f, 9.4f, 21.6f, 18.8f, 10.4f, 13.4f, 10.4f))
            Ico.SHARE -> {
                strokes(c, p, Path().apply {
                    moveTo(6.2f, 11.4f); lineTo(6.2f, 18.4f)
                    quadTo(6.2f, 20.4f, 8.2f, 20.4f); lineTo(15.8f, 20.4f)
                    quadTo(17.8f, 20.4f, 17.8f, 18.4f); lineTo(17.8f, 11.4f)
                })
                line(c, p, 12f, 15.4f, 12f, 3.6f)
                strokes(c, p, poly(8.2f, 7.4f, 12f, 3.6f, 15.8f, 7.4f))
            }
            Ico.REFRESH -> {
                arc(c, p, 12f, 12f, 7.8f, -58f, 292f)
                strokes(c, p, poly(15.4f, 2.4f, 16.4f, 6.6f, 12.2f, 7f))
            }
            Ico.HOUSE -> {
                strokes(c, p, poly(3.6f, 10.8f, 12f, 3.8f, 20.4f, 10.8f, 20.4f, 19.6f, 3.6f, 19.6f, 3.6f, 10.8f))
            }
            Ico.CLOCK -> {
                circle(c, p, 12f, 12f, 8.4f)
                strokes(c, p, poly(12f, 7.2f, 12f, 12.4f, 16.2f, 14.6f))
            }
            Ico.GAUGE -> {
                arc(c, p, 12f, 15.4f, 8.6f, 186f, 168f)
                strokes(c, p, poly(12f, 15.4f, 16.6f, 10.4f))
                dot(c, p, 12f, 15.4f, 1.4f)
            }
            Ico.TRASH -> {
                line(c, p, 4.4f, 7f, 19.6f, 7f)
                strokes(c, p, Path().apply {
                    moveTo(6.6f, 7f); lineTo(7.6f, 19.4f)
                    quadTo(7.7f, 20.6f, 9f, 20.6f); lineTo(15f, 20.6f)
                    quadTo(16.3f, 20.6f, 16.4f, 19.4f); lineTo(17.4f, 7f)
                })
                strokes(c, p, poly(9.6f, 4.2f, 14.4f, 4.2f))
            }
            Ico.IMAGE -> {
                rr(c, p, 3.4f, 4.6f, 20.6f, 19.4f, 2.8f)
                circle(c, p, 9f, 9.8f, 1.6f)
                strokes(c, p, poly(5.4f, 17.6f, 10.2f, 12.6f, 13.4f, 15.8f, 16f, 13.4f, 19f, 17.6f))
            }
            Ico.MUSIC -> {
                dot(c, p, 7.4f, 18f, 2.6f)
                line(c, p, 9.9f, 18f, 9.9f, 5.6f)
                strokes(c, p, poly(9.9f, 5.6f, 18.6f, 3.6f, 18.6f, 9.4f, 9.9f, 11.4f))
            }
            Ico.VIDEO -> {
                rr(c, p, 3.4f, 6.2f, 15.4f, 17.8f, 2.8f)
                fills(c, p, poly(16.8f, 10.2f, 20.8f, 7.4f, 20.8f, 16.6f, 16.8f, 13.8f))
            }
            Ico.ARCHIVE -> {
                rr(c, p, 4.8f, 3.6f, 19.2f, 20.4f, 3f)
                line(c, p, 4.8f, 8.6f, 19.2f, 8.6f)
                line(c, p, 11.2f, 11.6f, 12.8f, 11.6f)
                line(c, p, 11.2f, 15.2f, 12.8f, 15.2f)
            }
            Ico.GRID -> {
                rr(c, p, 3.8f, 3.8f, 10.6f, 10.6f, 2.6f)
                rr(c, p, 13.4f, 3.8f, 20.2f, 10.6f, 2.6f)
                rr(c, p, 3.8f, 13.4f, 10.6f, 20.2f, 2.6f)
                rr(c, p, 13.4f, 13.4f, 20.2f, 20.2f, 2.6f)
            }
            Ico.WAVE -> strokes(c, p, Path().apply {
                moveTo(2.6f, 13.4f)
                cubicTo(5.2f, 6.6f, 7.6f, 20.2f, 10.4f, 13.4f)
                cubicTo(13.2f, 6.6f, 15.6f, 20.2f, 18.4f, 13.4f)
                cubicTo(19.6f, 10.6f, 20.6f, 10.2f, 21.4f, 10.8f)
            })
            Ico.SUN -> {
                circle(c, p, 12f, 12f, 4.2f)
                for (i in 0 until 8) {
                    val a = Math.toRadians((i * 45).toDouble())
                    val cos = Math.cos(a).toFloat()
                    val sin = Math.sin(a).toFloat()
                    line(c, p, 12f + cos * 7f, 12f + sin * 7f, 12f + cos * 9.6f, 12f + sin * 9.6f)
                }
            }
            Ico.MOON -> {
                scratch.reset()
                scratch.addOval(RectF(2.6f, 2.6f, 21.4f, 21.4f), Path.Direction.CW)
                val cut = Path().apply { addOval(RectF(9.4f, -2.4f, 25.6f, 13.8f), Path.Direction.CW) }
                scratch.op(cut, Path.Op.DIFFERENCE)
                fills(c, p, scratch)
            }
            Ico.INFO -> {
                circle(c, p, 12f, 12f, 8.4f)
                dot(c, p, 12f, 7.8f, 1.15f)
                line(c, p, 12f, 11f, 12f, 16.6f)
            }
            Ico.ARROW_UP -> {
                line(c, p, 12f, 19.4f, 12f, 4.6f)
                strokes(c, p, poly(6.4f, 10.2f, 12f, 4.6f, 17.6f, 10.2f))
            }
            Ico.ARROW_DOWN -> {
                line(c, p, 12f, 4.6f, 12f, 19.4f)
                strokes(c, p, poly(6.4f, 13.8f, 12f, 19.4f, 17.6f, 13.8f))
            }
            Ico.DOT -> dot(c, p, 12f, 12f, 4.6f)
            Ico.POWER -> {
                arc(c, p, 12f, 13f, 7.8f, -62f, 304f)
                line(c, p, 12f, 3.2f, 12f, 11.4f)
            }
            Ico.LINK -> {
                strokes(c, p, poly(9.6f, 14.4f, 14.4f, 9.6f))
                strokes(c, p, Path().apply {
                    moveTo(7.2f, 16.8f); lineTo(5.6f, 18.4f)
                    quadTo(3f, 15.8f, 5.6f, 13.2f); lineTo(9.4f, 9.4f)
                })
                strokes(c, p, Path().apply {
                    moveTo(16.8f, 7.2f); lineTo(18.4f, 5.6f)
                    quadTo(21f, 8.2f, 18.4f, 10.8f); lineTo(14.6f, 14.6f)
                })
            }
            Ico.SEARCH -> {
                circle(c, p, 10.6f, 10.6f, 6.8f)
                line(c, p, 15.6f, 15.6f, 20.4f, 20.4f)
            }
        }
    }
}

/** A single stroked icon on the 24-unit grid, tintable at any size. */
class IconView(
    ctx: android.content.Context,
    var name: Ico,
    private var sizeDp: Float,
    var color: Int,
    private var strokeUnits: Float = 1.75f,
) : View(ctx) {

    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
        style = Paint.Style.STROKE
    }

    fun set(name: Ico, color: Int) {
        this.name = name
        this.color = color
        invalidate()
    }

    fun size(dpSize: Float) {
        sizeDp = dpSize
        requestLayout()
        invalidate()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val px = dpi(sizeDp)
        setMeasuredDimension(
            resolveSize(px, widthMeasureSpec),
            resolveSize(px, heightMeasureSpec),
        )
    }

    override fun onDraw(canvas: Canvas) {
        val side = minOf(width, height).toFloat()
        if (side <= 0f) return
        paint.color = color
        paint.strokeWidth = strokeUnits
        canvas.save()
        canvas.translate((width - side) / 2f, (height - side) / 2f)
        canvas.scale(side / 24f, side / 24f)
        Icons.draw(canvas, paint, name)
        canvas.restore()
    }
}

// @@WIDGETS@@
