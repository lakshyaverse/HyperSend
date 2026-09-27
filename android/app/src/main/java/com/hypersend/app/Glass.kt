package com.hypersend.app

import android.graphics.Bitmap
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.RadialGradient
import android.graphics.RectF
import android.graphics.RuntimeShader
import android.graphics.Shader
import android.os.Build
import android.util.Log
import android.view.View
import kotlin.math.max

/**
 * Real glass, not painted grey.
 *
 * Apple's Liquid Glass does four things a flat translucent rectangle cannot:
 *
 *   1. **blurs** what is behind it, so the backdrop reads as *behind* rather
 *      than as a tint on the surface,
 *   2. **desaturates** it — which is why a blue sky goes neutral grey behind a
 *      panel instead of staying blue,
 *   3. **bends** it, hardest within a few points of the rim where a thick slab
 *      curves away, so the backdrop is visibly squeezed into the edge,
 *   4. catches a **specular rim** from the upper-left.
 *
 * Android can do all of it. API 33's AGSL (`RuntimeShader`) samples a shader
 * input at arbitrary coordinates, so this object:
 *
 *   - keeps a small **snapshot of the scene** (the same gradients SceneView
 *     paints, at 1/4 scale — a smooth sky needs no more resolution),
 *   - runs a lens over it per surface: a little magnification through the
 *     middle, a displacement that grows toward the rim, a per-channel offset so
 *     the edge splits colour like real dispersion, a shallow gaussian frost for
 *     the interior, and a lit rim,
 *   - hands the result to the caller, which then draws its own rim/sheen on top.
 *
 * Everything below API 33 (or if the shader fails to build) falls straight back
 * to the painted glass — `fill()` returns false and the caller paints its own
 * body. Same pattern as Tokens.swift's pre-26 branch.
 */
object Glass {

    /**
     * The lens.
     *
     * `p` arrives in **view** px, relative to the surface's top-left. `scale`
     * converts a view px to a scene-bitmap px, and `origin` is the surface's
     * top-left already expressed in scene px — so the sample point is
     * `origin + local * scale`. Getting that composition wrong is the classic
     * way to end up sampling one corner of the scene for every surface, which
     * reads as a flat grey wash.
     */
    /**
     * Identifier hygiene matters here: AGSL shares GLSL's builtin namespace, so
     * a uniform called `refract` fails to compile ("symbol 'refract' was already
     * defined") and `local` is a storage qualifier. When that happens RuntimeShader
     * throws at construction — which, swallowed by [lens], silently disables all
     * refraction for the whole app. Hence the -Amt/-Px suffixes.
     */
    private const val AGSL = """
        uniform shader content;
        uniform float2 originPx;  // surface top-left, in scene bitmap px
        uniform float2 scalePx;   // view px -> scene bitmap px
        uniform float2 sizePx;    // surface size, in view px
        uniform float  lensAmt;   // 0 = flat, 1 = full lens
        uniform float  frostAmt;  // 0 = glassy, 1 = heavily frosted
        uniform float  desatAmt;  // how far the sample is pulled to neutral
        uniform float  tintAmt;   // how much of the body colour is mixed in
        uniform float3 bodyCol;   // that body colour

        half4 main(float2 p) {
            float2 c = sizePx * 0.5;
            float2 d = p - c;
            float2 nd = d / max(c, float2(1.0));
            float r = length(nd);                       // 0 centre, 1 rim
            float2 dir = r > 0.001 ? normalize(d) : float2(0.0, -1.0);

            // A thick slab magnifies a touch through the middle...
            float mag = 0.035 * lensAmt;
            // ...and bends hardest where it curves away at the rim, so the
            // backdrop is crushed into the last few points of edge.
            float edge = smoothstep(0.34, 1.0, r);
            float bend = edge * edge * lensAmt;

            float2 samplePt = c + d * (1.0 - mag);
            float2 uv = originPx + samplePt * scalePx;

            // Push outward. `sizePx` is view px and `uv` is scene px, so the
            // push has to cross the same conversion — skip scalePx and a big
            // card displaces its rim by hundreds of points instead of tens.
            float push = bend * min(sizePx.x, sizePx.y) * scalePx.x * 0.040;
            uv -= dir * push;

            // Dispersion: the channels refract by different amounts, which is
            // what puts a faint warm/cool fringe on the rim of real glass.
            float disp = bend * 5.0 * scalePx.x;
            float3 col;
            col.r = float(content.eval(uv + dir * disp).r);
            col.g = float(content.eval(uv).g);
            col.b = float(content.eval(uv - dir * disp).b);

            // Frost: a two-ring gaussian. The *middle* of a pane is frosted,
            // but the rim stays crisp — that contrast is what makes the bending
            // visible at all, and it is how a real thicker edge behaves.
            float blurRad = (5.0 + 26.0 * frostAmt) * scalePx.x;
            float2 o1 = float2(blurRad * 0.62, 0.0);
            float2 o2 = float2(0.0, blurRad * 0.62);
            float2 o3 = float2(blurRad * 0.44, blurRad * 0.44);
            float3 soft = float3(content.eval(uv).rgb) * 0.24;
            soft += float3(content.eval(uv + o1).rgb) * 0.095;
            soft += float3(content.eval(uv - o1).rgb) * 0.095;
            soft += float3(content.eval(uv + o2).rgb) * 0.095;
            soft += float3(content.eval(uv - o2).rgb) * 0.095;
            soft += float3(content.eval(uv + o3).rgb) * 0.095;
            soft += float3(content.eval(uv - o3).rgb) * 0.095;
            soft += float3(content.eval(uv + float2(o3.x, -o3.y)).rgb) * 0.095;
            soft += float3(content.eval(uv + float2(-o3.x, o3.y)).rgb) * 0.095;

            float rimSharp = smoothstep(0.45, 0.92, r);
            float blurMix = mix(0.94, 0.12, rimSharp) * (0.55 + 0.45 * frostAmt);
            col = mix(col, soft, clamp(blurMix, 0.0, 1.0));

            // Desaturate toward luminance, then let the body tint it. This is
            // the step that turns a blue sky into the neutral grey the Mac
            // window shows behind its panels.
            float lum = dot(col, float3(0.2126, 0.7152, 0.0722));
            col = mix(col, float3(lum), clamp(desatAmt, 0.0, 1.0));
            col = mix(col, bodyCol, clamp(tintAmt, 0.0, 0.94));

            // Rim light from the upper-left, with a faint cool exit low down.
            float2 L = normalize(float2(-0.5, -0.86));
            float facing = dot(dir, L) * 0.5 + 0.5;
            float band = smoothstep(0.84, 0.985, r) * (1.0 - smoothstep(0.985, 1.02, r));
            col += band * (0.20 + 0.80 * facing) * 0.42 * lensAmt;
            col += band * (1.0 - facing) * 0.07;

            // A broad diagonal crown across the top, like a sheet catching a
            // window: strongest top-left, gone by the waist.
            float across = clamp((p.y + d.x * 0.40) / max(sizePx.y, 1.0), 0.0, 1.0);
            float crown = 1.0 - smoothstep(0.0, 0.85, across);
            col += crown * crown * 0.085 * (0.35 + 0.65 * lensAmt);

            return half4(half3(max(col, float3(0.0))), 1.0);
        }
    """

    private var scene: Bitmap? = null
    private var sceneShader: BitmapShader? = null
    private var sceneW = 0
    private var sceneH = 0
    private var windowW = 0f
    private var windowH = 0f
    private var snapshotPal: Pal? = null

    private var lens: RuntimeShader? = null
    private var lensTried = false
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val loc = IntArray(2)

    /** The lens needs Android 13 for AGSL and a snapshot to sample. */
    val canRefract: Boolean get() = Build.VERSION.SDK_INT >= 33 && scene != null

    /**
     * Re-render the scene at 1/4 scale. Called by SceneView whenever its size
     * or palette changes — never per frame.
     */
    fun snapshot(viewW: Int, viewH: Int, pal: Pal) {
        if (viewW <= 0 || viewH <= 0) return
        val w = max(64, viewW / 4)
        val h = max(64, viewH / 4)
        if (scene != null && sceneW == w && sceneH == h && snapshotPal === pal) return
        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        val p = Paint(Paint.ANTI_ALIAS_FLAG)
        val wf = w.toFloat()
        val hf = h.toFloat()

        p.shader = LinearGradient(
            0f, 0f, wf * 0.18f, hf,
            intArrayOf(pal.skyTop, pal.skyMid, pal.skyBottom),
            floatArrayOf(0f, 0.52f, 1f), Shader.TileMode.CLAMP,
        )
        canvas.drawRect(0f, 0f, wf, hf, p)

        // The same bloom layout SceneView paints, or the glass would refract
        // something that is not actually behind it.
        blooms(wf, hf, pal).forEach { bloom ->
            p.shader = RadialGradient(
                bloom.cx, bloom.cy, bloom.radius,
                intArrayOf(bloom.color, Ink.withAlpha(bloom.color, 0f)), null, Shader.TileMode.CLAMP,
            )
            canvas.drawCircle(bloom.cx, bloom.cy, bloom.radius, p)
        }

        scene = bmp
        sceneShader = BitmapShader(bmp, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP)
        sceneW = w
        sceneH = h
        windowW = viewW.toFloat()
        windowH = viewH.toFloat()
        snapshotPal = pal
    }

    private fun lens(): RuntimeShader? {
        if (Build.VERSION.SDK_INT < 33) return null
        if (lensTried) return lens
        lensTried = true
        lens = try {
            RuntimeShader(AGSL).also { Log.i("HyperSend", "glass lens compiled") }
        } catch (failure: Throwable) {
            // AGSL is compiled on the device: if it rejects the program, the
            // painted fallback keeps the app looking right.
            Log.w("HyperSend", "glass shader unavailable: ${failure.message}")
            null
        }
        return lens
    }

    /**
     * Draws a refracted glass body inside [rect]. Returns false when the device
     * (or the shader) cannot do it, and the caller should paint its own body.
     *
     * @param refract 1 = full lens. 0 still blurs and desaturates, which is what
     *                a big quiet panel wants — it reads as glass without warping.
     */
    fun fill(
        view: View,
        canvas: Canvas,
        rect: RectF,
        radiusPx: Float,
        pal: Pal,
        bodyColor: Int,
        bodyAlpha: Float,
        refract: Float = 1f,
        frost: Float = 0.6f,
        desat: Float = pal.desat,
    ): Boolean {
        val bmp = scene ?: return false
        val shader = sceneShader ?: return false
        val program = lens() ?: return false
        if (rect.width() <= 1f || rect.height() <= 1f) return false

        val scaleX = sceneW / windowW
        val scaleY = sceneH / windowH
        view.getLocationInWindow(loc)

        return try {
            program.setInputShader("content", shader)
            // Origin is in SCENE px; the shader applies `scale` to the local
            // offset only. Multiplying it here as well would sample one corner
            // of the scene for every surface — a flat grey wash.
            program.setFloatUniform(
                "originPx",
                (loc[0] + rect.left) * scaleX,
                (loc[1] + rect.top) * scaleY,
            )
            program.setFloatUniform("scalePx", scaleX, scaleY)
            program.setFloatUniform("sizePx", rect.width(), rect.height())
            program.setFloatUniform("lensAmt", refract.coerceIn(0f, 1.5f))
            program.setFloatUniform("frostAmt", frost.coerceIn(0f, 1f))
            program.setFloatUniform("desatAmt", desat.coerceIn(0f, 1f))
            program.setFloatUniform("tintAmt", bodyAlpha.coerceIn(0f, 0.92f))
            program.setFloatUniform(
                "bodyCol",
                android.graphics.Color.red(bodyColor) / 255f,
                android.graphics.Color.green(bodyColor) / 255f,
                android.graphics.Color.blue(bodyColor) / 255f,
            )
            paint.shader = program
            canvas.drawRoundRect(rect, radiusPx, radiusPx, paint)
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
