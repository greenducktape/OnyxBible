package com.example.onyxsdk_pen

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import com.onyx.android.sdk.data.note.TouchPoint
import com.onyx.android.sdk.pen.NeoBrushPen
import com.onyx.android.sdk.pen.NeoCharcoalPen
import com.onyx.android.sdk.pen.NeoFountainPen
import com.onyx.android.sdk.pen.NeoMarkerPen
import com.onyx.android.sdk.pen.PenUtils
import com.onyx.android.sdk.pen.TouchHelper
import java.io.ByteArrayOutputStream

/**
 * Renders finished strokes with the SDK's OWN pen renderers — the same
 * NeoBrushPen / NeoCharcoalPen / NeoFountainPen / NeoMarkerPen that draw the raw
 * ink you watch appear under the nib.
 *
 * The point of going through native code for something an app could draw itself
 * is that it cannot draw it itself, not really: those renderers use pressure,
 * point size and tilt in proportions nobody outside Onyx knows, and an imitation
 * always lands close-but-different. Close-but-different is exactly what is
 * visible when a stroke is redrawn — the mark changes under the writer's eyes.
 * Calling the same code makes the two identical by construction.
 *
 * Everything else stays with the app: it owns the strokes, storage, erasing and
 * undo, and asks for a page as a bitmap when it needs to paint one.
 */
internal object OnyxStrokeRenderer {

    /**
     * Draws [strokes] into a transparent bitmap [width] x [height] physical
     * pixels and returns it PNG-encoded, or null if there is nothing to draw or
     * the SDK is unavailable (a non-Onyx device — the caller then falls back to
     * its own rendering).
     *
     * Each stroke is a map of:
     *  - `style`  Int, an OnyxStrokeStyle ordinal (the Dart-side enum), mapped
     *             to the SDK's constants exactly as the live overlay maps them
     *             so a stroke is committed by the renderer that drew it
     *  - `color`  Int, ARGB
     *  - `width`  Double, nib width in the same physical pixels
     *  - `points` List<Number>, flattened 5 per point: x, y, pressure, size,
     *             timestamp. Flattened rather than a list of maps because a page
     *             of handwriting runs to tens of thousands of points and the
     *             channel codec charges per object.
     */
    fun renderToPng(
        context: Context?,
        width: Int,
        height: Int,
        strokes: List<Map<String, Any?>>,
    ): ByteArray? {
        if (width <= 0 || height <= 0 || strokes.isEmpty()) return null
        // A page-sized ARGB bitmap is a few tens of megabytes on a large panel;
        // failing to allocate is worth surviving, not crashing over.
        val bitmap = try {
            Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        } catch (e: OutOfMemoryError) {
            return null
        }

        try {
            val canvas = Canvas(bitmap)
            val paint = Paint().apply { isAntiAlias = true }
            var drewAnything = false

            for (stroke in strokes) {
                val points = toTouchPoints(stroke["points"])
                if (points.isEmpty()) continue
                val style = (stroke["style"] as? Number)?.toInt() ?: 1
                val strokeWidth = (stroke["width"] as? Number)?.toFloat() ?: 3f
                paint.color = (stroke["color"] as? Number)?.toInt() ?: 0xFF000000.toInt()
                paint.strokeWidth = strokeWidth
                if (drawStroke(context, canvas, paint, style, points, strokeWidth)) {
                    drewAnything = true
                }
            }
            if (!drewAnything) return null

            val out = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
            return out.toByteArray()
        } catch (e: Throwable) {
            // Any SDK surprise means the app should keep using its own painter
            // rather than show a page with no notes on it.
            return null
        } finally {
            bitmap.recycle()
        }
    }

    private fun toTouchPoints(raw: Any?): List<TouchPoint> {
        val flat = raw as? List<*> ?: return emptyList()
        val points = ArrayList<TouchPoint>(flat.size / STRIDE)
        var i = 0
        while (i + STRIDE <= flat.size) {
            val x = (flat[i] as? Number)?.toFloat() ?: 0f
            val y = (flat[i + 1] as? Number)?.toFloat() ?: 0f
            // The app normalises pressure to 0..1; the SDK's renderers weigh
            // it against the digitiser's own range. A point with no usable
            // pressure arrives negative and is taken as a full press.
            val reported = (flat[i + 2] as? Number)?.toFloat() ?: 1f
            val pressure = (if (reported < 0f) 1f else reported) * MAX_PRESSURE
            val size = (flat[i + 3] as? Number)?.toFloat() ?: 0f
            val timestamp = (flat[i + 4] as? Number)?.toLong() ?: 0L
            points.add(TouchPoint(x, y, pressure, size, timestamp))
            i += STRIDE
        }
        return points
    }

    /**
     * Returns false when this style has no SDK renderer to hand it to.
     *
     * [style] is the Dart OnyxStrokeStyle ordinal, mapped here the same way
     * OnyxsdkPenArea.strokeStyleToOnyx maps it for the live overlay — the whole
     * point is that a stroke is committed by the renderer that drew it.
     */
    private fun drawStroke(
        context: Context?,
        canvas: Canvas,
        paint: Paint,
        style: Int,
        points: List<TouchPoint>,
        strokeWidth: Float,
    ): Boolean {
        val onyxStyle = when (style) {
            0 -> TouchHelper.STROKE_STYLE_FOUNTAIN
            1 -> TouchHelper.STROKE_STYLE_PENCIL
            2 -> TouchHelper.STROKE_STYLE_NEO_BRUSH
            3 -> TouchHelper.STROKE_STYLE_CHARCOAL
            4 -> TouchHelper.STROKE_STYLE_MARKER
            else -> TouchHelper.STROKE_STYLE_PENCIL
        }
        return when (onyxStyle) {
            TouchHelper.STROKE_STYLE_FOUNTAIN -> {
                // (canvas, paint, points, displayScale, strokeWidth,
                //  maxTouchPressure, erase)
                NeoFountainPen.drawStroke(
                    canvas, paint, points, DISPLAY_SCALE, strokeWidth,
                    MAX_PRESSURE, false,
                )
                true
            }
            TouchHelper.STROKE_STYLE_NEO_BRUSH -> {
                // (canvas, paint, points, strokeWidth, maxTouchPressure, erase)
                NeoBrushPen.drawStroke(
                    canvas, paint, points, strokeWidth, MAX_PRESSURE, false,
                )
                true
            }
            TouchHelper.STROKE_STYLE_MARKER -> {
                NeoMarkerPen.drawStroke(canvas, paint, points, strokeWidth, false)
                true
            }
            TouchHelper.STROKE_STYLE_CHARCOAL,
            TouchHelper.STROKE_STYLE_CHARCOAL_V2 -> {
                if (context == null) return false
                // (context, canvas, paint, points, color, strokeWidth,
                //  createArgs, screenMatrix, erase). An identity matrix rather
                // than null: the points already arrive in panel pixels, and a
                // null matrix is not worth finding out about at runtime.
                NeoCharcoalPen.drawNormalStroke(
                    context, canvas, paint, points, paint.color, strokeWidth,
                    null, Matrix(), false,
                )
                true
            }
            else -> {
                // The plain pen/pencil style has no Neo* class of its own.
                PenUtils.drawStrokeByPointSize(canvas, paint, points, false)
                true
            }
        }
    }

    /** x, y, pressure, size, timestamp. */
    private const val STRIDE = 5

    // The renderers weigh pressure against the digitiser's range, which the
    // SDK exposes no getter for. 4096 is what Onyx's panels report; being off
    // would shift the weighting rather than break the stroke.
    private const val MAX_PRESSURE = 4096.0f

    // NeoFountainPen's displayScale. The points already arrive in panel pixels,
    // so nothing further should be scaled.
    private const val DISPLAY_SCALE = 1.0f
}
