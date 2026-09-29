package com.hypersend.app

import android.graphics.Bitmap
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RadialGradient
import android.graphics.RectF
import android.graphics.RuntimeShader
import android.graphics.Shader
import android.os.Build
import android.util.Log
import android.view.View
import java.io.File
import kotlin.math.max
import kotlin.math.min

/**
 * Liquid Glass, rebuilt from the specification rather than from a guess.
 *
 * Apple's own description (WWDC25 "Meet Liquid Glass") is that the material is
 * defined by **lensing**: "where previous materials scattered light, this new
 * set of materials dynamically bends, shapes, and concentrates light in real
 * time". A blur with a tint on top is not this material, and a painted white
 * rim is not this material either.
 *
 * Everything below is derived from two sources:
 *
 *   1. **Apple's session + the published teardowns of the effect.** The shape is
 *      a distance field; the field's gradient is the surface normal; a bevel
 *      profile gives the glass its thickness; refraction pulls the sample
 *      *inward* along that normal in the outer ring only, so the backdrop behind
 *      the rim is magnified outward and appears to wrap the edge; a broad soft
 *      band near the rim folds the sample back on itself (the upside-down echo
 *      iOS shows on a glass pill); dispersion is almost invisible; and the
 *      refraction has to taper to *zero* at the outermost edge or it magnifies
 *      sub-pixel noise into radial hairlines.
 *
 *   2. **The Mac window itself, measured.** Sampling across a panel's edge in
 *      both light and dark screenshots — the one place where the backdrop and
 *      the pane can be compared at the same spot — the material does exactly
 *      two things to what it transmits:
 *
 *          light  sky #BED0DD -> pane #C7D5E0     (chroma -20%, luma +6)
 *          dark   sky #262D4A -> pane #455072     (chroma -20%, luma +33)
 *
 *      i.e. pull the backdrop about a fifth of the way toward neutral, then
 *      lift it with a little white (12% in light, 16% in dark). Nothing else.
 *      There is no bright rim and no sheen cone in the real thing: sampling
 *      straight down through a panel's top edge gives a smooth monotone ramp
 *      with no overshoot. Every painted highlight this app used to draw was
 *      therefore *added noise on top of* the material — which is precisely why
 *      the cards read as white-outlined slabs instead of as glass.
 *
 * The snapshot is the scene at 1/2 scale: the lens needs real detail to bend.
 * (An earlier 1/4 scale threw away the structure the refraction is supposed to
 * magnify, so the pane had nothing to show.)
 *
 * Below API 33 (no AGSL) `fill()` returns false and callers paint their own
 * body — the same pre-macOS-26 fallback the Mac app carries.
 *
 * One deliberate simplification: the distance field is an exact rounded box
 * while the silhouette is a *continuous* corner. By construction the two agree
 * at the 45° point of every corner and differ by well under a pixel two thirds
 * of the way along it, which is far below the width of any ramp here.
 */
object Glass {

    /**
     * Identifier hygiene is load-bearing: AGSL shares GLSL's builtin namespace,
     * so a uniform named `refract` fails to compile outright and `local` is a
     * storage qualifier. When that happens `RuntimeShader` throws at
     * construction — and, swallowed below, it would silently disable the whole
     * material for the entire app. Hence the suffixes.
     */
    private const val AGSL = """
        uniform shader content;   // the scene, at half scale
        uniform float2 originPx;  // this surface's top-left, in scene-bitmap px
        uniform float2 scalePx;   // view px -> scene-bitmap px
        uniform float2 sizePx;    // surface size, in view px
        uniform float  cornerPx;  // corner radius, in view px
        uniform float  lensPx;    // peak edge displacement, in view px
        uniform float  bandPx;    // width of the rim bead, in view px
        uniform float  bevelPx;   // how far the slab's wide bend reaches in, in view px
        uniform float  specPx;    // how far the specular line reaches in, in view px
        uniform float  specAmt;
        uniform float  dbgAmt;    // 1 = paint the distance field instead of glass
        uniform float  blurPx;    // frost radius, in view px
        uniform float  clarityAmt;// 1 = full lens, 0 = flat pane
        uniform float  dispPx;    // chromatic split, in view px
        uniform float  satAmt;    // vibrancy
        uniform float  desatAmt;  // how far the pane pulls its backdrop to neutral
        uniform float  tintAmt;
        uniform float  rimAmt;
        uniform float3 tintCol;

        const float3 LUMA = float3(0.2126, 0.7152, 0.0722);

        // Exact signed distance to a rounded box: negative inside, in px.
        float sdRoundBox(float2 d, float2 b, float r) {
            float2 q = abs(d) - b + float2(r);
            return min(max(q.x, q.y), 0.0) + length(max(q, float2(0.0))) - r;
        }

        // The distance field's gradient, analytically. Where the field collapses
        // onto the shape's medial axis every direction is equally "outward", so
        // this picks the nearest edge instead of returning a NaN that would
        // propagate through the refraction multiply.
        float2 boxNormal(float2 d, float2 b, float r) {
            float2 edge = max(b - float2(r), float2(0.0));
            float2 arc = d - sign(d) * edge;
            float len = length(arc);
            arc = len > 1e-4 ? arc / len : float2(0.0, -1.0);
            if (abs(d.x) <= edge.x) return float2(0.0, d.y < 0.0 ? -1.0 : 1.0);
            if (abs(d.y) <= edge.y) return float2(d.x < 0.0 ? -1.0 : 1.0, 0.0);
            return arc;
        }

        half4 main(float2 p) {
            // NOT `half`: that is a type name in SkSL, exactly like `refract` is
            // a builtin. Either one fails to compile, and a failed compile is
            // swallowed into the flat fallback, so the whole material silently
            // disappears. Every identifier below is chosen to avoid the
            // builtin namespace on purpose.
            float2 halfExt = max(sizePx * 0.5, float2(1.0));
            float2 d = p - halfExt;
            float rad = min(cornerPx, min(halfExt.x, halfExt.y));
            float2 n = boxNormal(d, halfExt, rad);   // outward, unit

            float inside = -sdRoundBox(d, halfExt, rad);   // px inside the silhouette

            // A probe, not a feature. When nothing on screen matches what the
            // arithmetic says should be there, the honest move is to read the
            // arithmetic back out of the shader: red encodes `inside` (0 at the
            // rim, 255 at 100 px in), green and blue carry the raw backdrop at
            // the *undisplaced* sample point. That answers both questions a
            // screenshot cannot — where the shader believes the edge is, and
            // what it believes it is looking at — without guessing again.
            if (dbgAmt > 0.5) {
                // A *constant* coordinate on purpose. Green and blue must come
                // back the same for every pixel of every surface — that is the
                // backdrop at (20, 350), which the bitmap dump shows as a fixed
                // value. If they vary instead, the shader is not reading the
                // child shader at the coordinate it was handed, and every
                // conclusion drawn from a probe would have been worthless.
                float3 raw = float3(content.eval(float2(20.0, 350.0)).rgb);
                return half4(half3(clamp(inside / 100.0, 0.0, 1.0), raw.g, raw.b), 1.0);
            }

            // ── the meniscus ─────────────────────────────────────────────
            // Glass is not a slab with a soft edge; it is a bead. The surface
            // turns over sharply in a narrow band at the rim and is flat
            // behind it, and *that band* is where all the bending happens.
            // Spreading the bend across the whole pane is what a wash looks
            // like — and a wash is what a fake liquid glass looks like.
            //
            // This is the correction that matters. The previous profile rose
            // from zero displacement *at* the rim and peaked a guard-width
            // inside, on the theory that magnifying the outermost pixels would
            // crack into radial hairlines. It was safe and it was invisible:
            // the edge did nothing, which is exactly what "the glass is not
            // even on the edge" describes.
            float band = max(bandPx, lensPx * 2.06);
            float tEd = clamp(inside / band, 0.0, 1.0);
            float drop = (1.0 - tEd) * (1.0 - tEd);

            // Safe *and* strong, because band >= 2.06 * lensPx keeps the
            // derivative of (inside - displacement) positive: the sample map
            // never folds, so the rim can magnify the backdrop ~14x instead of
            // cracking into hairlines. That inequality is the whole trick.
            float bend = drop * clarityAmt;

            // The slab's own, much weaker, much wider magnification: felt
            // across the body rather than at the edge.
            float wide = 1.0 - smoothstep(band, max(bevelPx, band * 1.4), inside);
            float slab = wide * wide * 0.22 * clarityAmt;

            // A narrow shape has no room for a bead: where the rims from both
            // sides would meet, ease off, so a pill reads as glass bent along
            // one axis rather than as a seam down its middle.
            float reach = max(min(halfExt.x, halfExt.y), 1.0);
            float medial = smoothstep(reach * 0.55, reach * 1.02, inside);
            float ease = 1.0 - 0.5 * medial * medial;

            // ── refraction ───────────────────────────────────────────────
            float2 uv = originPx + p * scalePx;
            float2 pulled = uv - n * (lensPx * (bend + slab) * ease) * scalePx;

            // A light frost. Heavy blur destroys the very detail the lens exists
            // to bend — the material stays legible instead of turning to fog.
            float2 soften = max(blurPx * (0.85 + 0.35 * drop), 0.0) * scalePx;
            float3 col = float3(content.eval(pulled).rgb) * 0.36;
            col += float3(content.eval(pulled - float2(soften.x, 0.0)).rgb) * 0.16;
            col += float3(content.eval(pulled + float2(soften.x, 0.0)).rgb) * 0.16;
            col += float3(content.eval(pulled - float2(0.0, soften.y)).rgb) * 0.16;
            col += float3(content.eval(pulled + float2(0.0, soften.y)).rgb) * 0.16;

            // Dispersion, kept all but invisible. Real UI glass shows at most a
            // hint of a fringe; anything more reads as an artefact. Tied to the
            // bead so the flat body stays perfectly neutral.
            float2 split = n * (dispPx * drop) * scalePx;
            col.r = mix(col.r, float(content.eval(pulled + split).r), 0.5);
            col.b = mix(col.b, float(content.eval(pulled - split).b), 0.5);

            // ── the material, as measured off the Mac ────────────────────
            // Two operations, in this order, and nothing else. The desaturation
            // is the pane's optical neutralisation; the tint at the end is the
            // lift. Together they turn the Mac's measured pairs:
            //
            //     light  sky #BED0DD -> pane #C7D5E0   (chroma -20%, luma +6)
            //     dark   sky #262D4A -> pane #455072   (chroma -20%, luma +33)
            //
            // The lift is not a flat white wash — it is the palette's tint
            // alpha, which is why a light pane barely looks tinted at all while
            // a dark one visibly lightens its backdrop.
            float lum = dot(col, LUMA);
            col = clamp(float3(lum) + (col - float3(lum)) * satAmt, float3(0.0), float3(1.0));
            col = mix(col, float3(lum), desatAmt);
            col = mix(col, tintCol, tintAmt);

            // ── the specular ─────────────────────────────────────────────
            // The one thing that makes glass read as glass rather than as a
            // tinted hole: the rim catches the light along the arc that faces
            // it, and only along a line a couple of pixels wide. Note the
            // `facing` term — an outline of uniform brightness is a stroke, and
            // a stroke is what "painted on" means. Light falls from the upper
            // left, as it does everywhere else in this app.
            float2 lightDir = normalize(float2(-0.62, -0.78));
            float facing = clamp(dot(n, lightDir), 0.0, 1.0);
            float line = 1.0 - smoothstep(0.0, max(specPx, 0.6), inside);
            col += pow(facing, 4.0) * line * specAmt;

            // A hair of definition all the way round, so a pane still reads as
            // a thing where the backdrop happens to match its value.
            col += (1.0 - smoothstep(0.0, 1.2, inside)) * rimAmt;

            return half4(half3(clamp(col, float3(0.0), float3(1.0))), 1.0);
        }
    """

    private var scene: Bitmap? = null
    private var sceneShader: BitmapShader? = null
    private var sceneW = 0
    private var sceneH = 0
    private var windowW = 0f
    private var windowH = 0f
    private var snapshotPal: Pal? = null
    private var snapshotDrift = Float.NaN

    /** Where the debug-probe flag lives, handed over by the scene view. */
    var debugFile: File? = null

    /**
     * One shader and one paint per surface.
     *
     * Sharing a single instance across every pane looked thrifty and was a bug:
     * `fill()` writes a surface's uniforms and then draws, so a shared object
     * means each draw can be rasterised with another surface's `originPx` —
     * which shows up as a pane sampling its backdrop from the wrong place, and
     * a distance field measured from the wrong box.
     */
    private class Surface(val shader: RuntimeShader, val paint: Paint)

    private val surfaces = java.util.WeakHashMap<View, Surface>()

    /**
     * How many more lens calls to describe in logcat. A terminal cannot eyeball
     * a screenshot, so when a surface misbehaves the geometry has to be read
     * out loud: if the shader's idea of where the rim is disagrees with where
     * the rim is drawn, nothing about the material can be trusted.
     */
    private var probes = 8

    /**
     * Whether to paint the distance field. Toggled by creating a file inside
     * the app's own storage from adb, so a probe costs a tap rather than a
     * rebuild — the alternative is rebuilding to test each hypothesis, which is
     * how you end up shipping whichever guess you got tired of.
     */
    private var dbgAmt = 0f
    private var dbgAt = 0L

    fun debugAmount(): Float {
        val now = System.currentTimeMillis()
        if (now - dbgAt < 600) return dbgAmt
        dbgAt = now
        val file = debugFile
        if (file == null) {
            dbgAmt = 0f
            return dbgAmt
        }
        dbgAmt = try {
            if (file.exists()) 1f else 0f
        } catch (failure: Throwable) {
            0f
        }
        return dbgAmt
    }

    private val loc = IntArray(2)

    /** The lens needs Android 13 for AGSL, and a snapshot to sample. */
    val canRefract: Boolean get() = Build.VERSION.SDK_INT >= 33 && scene != null

    /**
     * Re-render the scene at half scale. Called by SceneView whenever its size
     * or palette changes — never per frame.
     *
     * Half, not a quarter: the refraction's whole job is to magnify the ring of
     * backdrop just inside the rim, so the detail there *is* the effect.
     */
    fun snapshot(viewW: Int, viewH: Int, pal: Pal, drift: Float = 0f) {
        if (viewW <= 0 || viewH <= 0) return
        val w = max(64, viewW / 2)
        val h = max(64, viewH / 2)
        // Rebuilding at half scale is real work, so a drift too small to
        // matter does not trigger one. 0.02 of the drift range moves a bloom by
        // well under a pixel; anything under that is churn, and churn here also
        // throws away a bitmap the shader may already be sampling.
        if (scene != null && sceneW == w && sceneH == h && snapshotPal === pal &&
            kotlin.math.abs(snapshotDrift - drift) < 0.02f
        ) {
            return
        }
        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        val wf = w.toFloat()
        val hf = h.toFloat()

        // The *whole* scene, grain and vignette included, from the one function
        // the window also paints from. Its grain runs at half scale, because so
        // does this bitmap.
        sceneLayers(wf, hf, pal, drift, 0.5f).forEach { layer ->
            paint.shader = layer.shader
            paint.alpha = layer.alpha
            canvas.drawRect(0f, 0f, wf, hf, paint)
        }
        paint.alpha = 255
        paint.shader = null

        if (debugAmount() > 0.5) {
            for (row in intArrayOf(100, 350, 600)) {
                if (row >= h) continue
                val line = StringBuilder()
                var x = 16
                while (x < min(w, 216)) {
                    line.append(Integer.toHexString(bmp.getPixel(x, row) and 0xFFFFFF)).append(' ')
                    x += 12
                }
                Log.i("HyperSend", "snapshot y=$row: $line")
            }
        }

        scene = bmp
        sceneShader = BitmapShader(bmp, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP)
        sceneW = w
        sceneH = h
        windowW = viewW.toFloat()
        windowH = viewH.toFloat()
        snapshotPal = pal
        snapshotDrift = drift
    }

    private fun surfaceFor(view: View): Surface? {
        if (Build.VERSION.SDK_INT < 33) return null
        surfaces[view]?.let { return it }
        return try {
            val made = Surface(RuntimeShader(AGSL), Paint(Paint.ANTI_ALIAS_FLAG))
            surfaces[view] = made
            Log.i("HyperSend", "glass lens compiled")
            made
        } catch (failure: Throwable) {
            Log.w("HyperSend", "glass shader unavailable: ${failure.message}")
            null
        }
    }

    /**
     * Draws the material inside [shape]. Returns false when the device (or the
     * shader) cannot do it, and the caller should paint its own body.
     *
     * @param tint        the pane's tint. Its alpha is the amount; anything
     *                    above ~0.2 starts to fight the material.
     * @param thickness   0 = a flat pane (frost and tint only), 1 = the default
     *                    slab, up to 2 for a deep lens. Apple thickens the
     *                    material as it grows: bigger glass bends more.
     * @param clarity     1 = full refraction, 0 = flat pane.
     * @param spec        scales the rim specular. Small surfaces — a pill, a
     *                    chip — turn over faster at the rim than a big panel
     *                    does and so catch more light; a panel should stay
     *                    close to 0, because measuring the Mac's own panels
     *                    shows no highlight on them at all.
     */
    fun fill(
        view: View,
        canvas: Canvas,
        shape: Path,
        rect: RectF,
        pal: Pal,
        tint: Int,
        radiusPx: Float,
        thickness: Float = 1f,
        clarity: Float = 1f,
        desat: Float = pal.desat,
        spec: Float = 0f,
    ): Boolean {
        val shader = sceneShader ?: return false
        if (scene == null) return false
        val surface = surfaceFor(view) ?: return false
        val program = surface.shader
        val paint = surface.paint
        if (rect.width() <= 1f || rect.height() <= 1f) return false

        val scaleX = sceneW / windowW
        val scaleY = sceneH / windowH
        view.getLocationInWindow(loc)

        // The lens is sized in *view* pixels so a bevel stays the same physical
        // thickness on every surface, but a bigger slab is a thicker slab, which
        // is the one size-dependent term Apple calls out.
        val shortSide = min(rect.width(), rect.height())
        val shortDp = shortSide / Density.d
        val safeThickness = thickness.coerceIn(0f, 2f)
        // Peak edge displacement, in view px. This is the number that decides
        // whether a surface reads as glass or as paint: it is how far the
        // backdrop is dragged at the rim, and therefore how hard the pane
        // looks like it is bending what is behind it.
        val lensPx = min(
            (shortDp * 0.22f * safeThickness).coerceIn(2.5f, 11f) * Density.d,
            shortSide * 0.30f,
        )
        // The bead's width. The shader floors it at 2.06 * lensPx — the
        // condition for the sample map not to fold — so this is a request, not
        // a promise; it lets a big slab have a proportionally wider bead.
        val bandPx = (shortDp * 0.20f * safeThickness).coerceIn(8f, 34f) * Density.d
        // How far the slab's own gentle magnification reaches in from the rim.
        val bevelPx = (shortDp * 0.34f).coerceIn(24f, 90f) * Density.d

        return try {
            program.setInputShader("content", shader)
            program.setFloatUniform(
                "originPx",
                (loc[0] + rect.left) * scaleX,
                (loc[1] + rect.top) * scaleY,
            )
            program.setFloatUniform("scalePx", scaleX, scaleY)
            program.setFloatUniform("sizePx", rect.width(), rect.height())
            program.setFloatUniform("cornerPx", radiusPx)
            program.setFloatUniform("lensPx", lensPx)
            program.setFloatUniform("bandPx", bandPx)
            program.setFloatUniform("bevelPx", bevelPx)
            program.setFloatUniform("specPx", dpi(2.2f).toFloat())
            program.setFloatUniform("specAmt", (if (pal.dark) 0.13f else 0.16f) * spec.coerceIn(0f, 2f))
            program.setFloatUniform("dbgAmt", debugAmount())
            program.setFloatUniform("blurPx", dpi(3.0f + 3.0f * safeThickness).toFloat())
            program.setFloatUniform("clarityAmt", clarity.coerceIn(0f, 1f))
            program.setFloatUniform("dispPx", 0.5f * safeThickness)
            program.setFloatUniform("satAmt", 1.0f)
            program.setFloatUniform("desatAmt", desat.coerceIn(0f, 1f))
            program.setFloatUniform("tintAmt", (Color.alpha(tint) / 255f).coerceIn(0f, 0.55f))
            // Small. The rim is definition, not decoration, and every level it
            // gains turns the material back toward the painted outline that made
            // this look plastic in the first place.
            program.setFloatUniform("rimAmt", if (pal.dark) 0.018f else 0.022f)
            program.setFloatUniform(
                "tintCol",
                Color.red(tint) / 255f,
                Color.green(tint) / 255f,
                Color.blue(tint) / 255f,
            )
            if (probes > 0) {
                probes--
                Log.i(
                    "HyperSend",
                    "lens ${rect.width().toInt()}x${rect.height().toInt()}" +
                        " loc=${loc[0]},${loc[1]} radius=$radiusPx" +
                        " lensPx=$lensPx bandPx=$bandPx bevelPx=$bevelPx" +
                        " scale=$scaleX scene=${sceneW}x${sceneH} win=${windowW}x${windowH}",
                )
            }
            paint.shader = program
            canvas.drawPath(shape, paint)
            paint.shader = null
            true
        } catch (failure: Throwable) {
            paint.shader = null
            false
        }
    }

    /** Drop the snapshot — used when the scene is torn down. */
    fun release() {
        scene = null
        sceneShader = null
        snapshotPal = null
    }
}

/**
 * The scene's blooms, in one place.
 *
 * SceneView paints them and Glass refracts them, so a copy of this layout in
 * two files is a bug waiting to happen: the glass would bend something that is
 * not actually behind it. Both call this.
 */
internal class Bloom(val cx: Float, val cy: Float, val radius: Float, val color: Int)

internal fun blooms(w: Float, h: Float, pal: Pal, drift: Float = 0f): List<Bloom> {
    val span = max(w, h) * pal.bloomSpread
    val a = drift
    return listOf(
        Bloom(w * (0.16f + 0.05f * a), h * (0.04f + 0.03f * a), span * 1.05f, pal.bloomA),
        Bloom(w * (0.92f - 0.06f * a), h * (0.26f + 0.05f * a), span * 0.85f, pal.bloomB),
        Bloom(w * (0.34f + 0.05f * a), h * (-0.02f + 0.04f * a), span * 1.00f, pal.bloomC),
    )
}
