package com.example.onyxsdk_pen

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.view.SurfaceView
import android.view.View
import com.onyx.android.sdk.data.note.TouchPoint
import com.onyx.android.sdk.pen.RawInputCallback
import com.onyx.android.sdk.pen.TouchHelper
import com.onyx.android.sdk.pen.data.TouchPointList
import com.onyx.android.sdk.api.device.epd.EpdController
import com.onyx.android.sdk.api.device.epd.UpdateMode
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import java.util.Timer
import java.util.TimerTask
import androidx.annotation.NonNull

internal class OnyxsdkPenArea(context: Context, messenger: BinaryMessenger, id: Int, creationParams: Map<String?, Any?>?) : PlatformView, MethodCallHandler {

    // This must stay in sync with the OnyxStrokeStyle enum in Dart
    enum class StrokeStyle(val Id: Int) {
        FountainPen(0),
        Pen(1),
        Brush(2),
        Pencil(3),
        Marker(4),
        Disabled(5)
    }

    private val channel: MethodChannel = MethodChannel(messenger, "onyxsdk_pen_area")

    companion object {
        private val pointsToRedraw = 20
    }

    private var strokeWidth = 0.0f
    private var strokeColor = Color.BLACK
    private var strokeStyle = StrokeStyle.FountainPen
    // The first update must always be applied, even if it happens to match the
    // defaults above — the TouchHelper has not been told anything yet.
    private var strokeConfigured = false

    private fun updateStroke(paramsRef: Map<String, Any>?) {
        /*
         Flutter ints are variable width
         Personally, I think it is utterly dumb. I hope there is a way to fix
         int size in flutter (why would you need 64 bits to store srgb??),
         but unless or until there isn't, this stupidity should be performed
         */
        val pureColor = (paramsRef?.get("strokeColor") as? Long)?.toInt()
                              ?: paramsRef?.get("strokeColor") as? Int
                              ?: Color.BLACK
        /*
         ONYXSDK Pen saturates the colors. Whatever it deems as "light" (luma < 128?)
         gets automagically turned to white. Transparency is also accounted apparently.
         Unless this is some case-by-case situation, if resulting color, assuming
         being drawn on absolutely white background, with a fully opaque brush
         is lighter than a certain unknown arbitrary threshold, it turns white,
         otherwise, is saturated to max.
         These thoughts are, however, purely observational. Nothing in documentation
         says this and no binary artifacts have been decompiled to come to these
         conclusions. Thus, feel free to correct my incompetence if I turn out wrong
         */
        var dest = FloatArray(3)
        Color.RGBToHSV(
            Color.red(pureColor),
            Color.green(pureColor),
            Color.blue(pureColor),
            dest
        )
        /*
         Saturation
         I suppose clamping is a sound idea, but the extremes to which the lib
         takes them are unacceptable. Make it white if visually indistinguishable
         from white and colorful otherwise.
        */
        if (dest[1] < 0.05) {
            /*
             Achromatic ink — black, the greys, white. An e-ink panel renders
             these natively, so the shade is passed through EXACTLY as asked.
             The value clamp below would otherwise round every grey to black or
             to invisible white, which is not a clamp, it's a deletion.
            */
            dest[1] = 0.0f
        } else {
            dest[1] = 1.0f
            /*
             Value
             I want color to show
             So clamp to black if it's visually indistinguishable from black
             and to colorful otherwise. E.g. brown will look red instead of black
            */
            dest[2] = if (dest[2] < 0.2) 0.0f else 1.0f
        }
        val newColor = Color.HSVToColor(dest)
        val newWidth = (paramsRef?.get("strokeWidth") as? Double ?: 3.0).toFloat()
        val newStyle = when (paramsRef?.get("strokeStyle") as? Int ?: 0) {
            0 -> StrokeStyle.FountainPen
            1 -> StrokeStyle.Pen
            2 -> StrokeStyle.Brush
            3 -> StrokeStyle.Pencil
            4 -> StrokeStyle.Marker
            5 -> StrokeStyle.Disabled
            else -> StrokeStyle.Pen
        }
        (paramsRef?.get("refreshDelayMs") as? Number)?.let { refreshDelayMs = it.toLong() }

        // The app calls this on EVERY rebuild, not only when the pen changes.
        // The GC invalidate at the end of this method flashes the whole panel
        // and takes any finished raw ink with it, so firing it because a
        // toolbar icon moved is how a page ends up flashing at nothing.
        val changed = !strokeConfigured ||
            newColor != strokeColor ||
            newWidth != strokeWidth ||
            newStyle != strokeStyle
        strokeColor = newColor
        strokeWidth = newWidth
        strokeStyle = newStyle
        strokeConfigured = true
        if (!changed) return

        if (strokeStyle != StrokeStyle.Disabled) {
            touchHelper.setStrokeStyle(strokeStyleToOnyx(strokeStyle))
            touchHelper.setStrokeWidth(strokeWidth)
            touchHelper.setStrokeColor(strokeColor)
        }

        // I've done at least 10 test builds with different variations of banging
        // rocks together to make this abhorrent eldritch horror to actually start
        // behaving and it still sometimes draws if style is disabled and stuff is done
        // fast enough. Let this be a note for future endeavoring perfectionists.
        // This specific combination seems to work best and still sometimes fails.
        // My wild guess is ONYX Note app is dismantling the whole overlay if eraser
        // is selected or using some hidden APIs. Or I was banging the wrong types of rocks...
        // TLDR I gave up here. Works good enough, certainly better than just drawing lines.
        // BTW, doing forceRefresh() and/or setDraw(...) here breaks the overlay altogether ;(

        touchHelper.setRawDrawingEnabled(strokeStyle != StrokeStyle.Disabled)
        EpdController.invalidate(view, UpdateMode.GC)
    }


    private val touchHelper: TouchHelper by lazy { TouchHelper.create(view, callback) }

    private val view: SurfaceView = SurfaceView(context)
    override fun getView(): View {
        return view
    }

    private val paint: Paint = Paint()
    private var pointsSinceLastRedraw = 0

    private val currentStroke: ArrayList<TouchPoint> = ArrayList()

    private var refreshTimerTask: TimerTask? = null
    // Zero or less means: never take a finished stroke away on a timer. See
    // scheduleRefresh(). Settable, so the app can change its mind at runtime.
    private var refreshDelayMs: Long =
        (creationParams?.get("refreshDelayMs") as? Number)?.toLong() ?: 1000

    private val callback: RawInputCallback = object: RawInputCallback() {
        fun reset() {
            currentStroke.clear()
            pointsSinceLastRedraw = 0
            drawPreview()
            refreshTimerTask?.cancel()
        }
        fun update(touchPoint: TouchPoint) {
            pointsSinceLastRedraw++
            if (pointsSinceLastRedraw < pointsToRedraw) return
            pointsSinceLastRedraw = 0

            currentStroke.add(touchPoint)

            drawPreview()
        }

        fun scheduleRefresh() {
            refreshTimerTask?.cancel()
            // The raw ink the SDK just drew IS the mark the writer watched
            // appear. Wiping the panel a second later so the same stroke can be
            // re-rendered from the app is what reads as "it changed by itself",
            // and no amount of matching the rendering hides the swap. A
            // non-positive delay turns the timer off and leaves the stroke where
            // the pen put it; the app refreshes on its own terms instead.
            if (refreshDelayMs <= 0) return
            refreshTimerTask = object : TimerTask() {
                override fun run() {
                    forceRefresh()
                }
            }
            Timer().schedule(refreshTimerTask, refreshDelayMs)
        }


        override fun onBeginRawDrawing(b: Boolean, touchPoint: TouchPoint) {
            // begin of stylus data
            reset()
        }

        override fun onEndRawDrawing(b: Boolean, touchPoint: TouchPoint) {
            // end of stylus data
            reset()
            scheduleRefresh()
        }

        override fun onRawDrawingTouchPointMoveReceived(touchPoint: TouchPoint) {
            // stylus data during stylus moving
            update(touchPoint)
        }

        override fun onRawDrawingTouchPointListReceived(touchPointList: TouchPointList) {
        }

        override fun onBeginRawErasing(b: Boolean, touchPoint: TouchPoint) {
            reset()
        }

        override fun onEndRawErasing(b: Boolean, touchPoint: TouchPoint) {
            reset()
            scheduleRefresh()
        }

        override fun onRawErasingTouchPointMoveReceived(touchPoint: TouchPoint) {
            update(touchPoint)
        }

        override fun onRawErasingTouchPointListReceived(touchPointList: TouchPointList) {
        }
    }

    private fun strokeStyleToOnyx(style: StrokeStyle): Int {
        return when (style) {
            StrokeStyle.FountainPen -> TouchHelper.STROKE_STYLE_FOUNTAIN
            StrokeStyle.Pen -> TouchHelper.STROKE_STYLE_PENCIL
            StrokeStyle.Brush -> TouchHelper.STROKE_STYLE_NEO_BRUSH
            StrokeStyle.Pencil -> TouchHelper.STROKE_STYLE_CHARCOAL
            StrokeStyle.Marker -> TouchHelper.STROKE_STYLE_MARKER
            StrokeStyle.Disabled -> TouchHelper.STROKE_STYLE_PENCIL
        }
    }

    fun setDraw(enabled: Boolean) {
        if (enabled) {
            touchHelper.openRawDrawing()
            touchHelper.setRawDrawingEnabled(true)
            touchHelper.setRawDrawingRenderEnabled(true)
        } else {
            touchHelper.closeRawDrawing()
        }
    }

    fun drawPreview() {
        currentStroke.clear()
    }

    fun forceRefresh() {
        touchHelper.setRawDrawingEnabled(false)
        EpdController.invalidate(view, UpdateMode.GC)
        touchHelper.setRawDrawingEnabled(true)
    }

    init {
        channel.setMethodCallHandler(this)
        view.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ ->
            // Use the view's GLOBAL (on-screen) rect, not its local one. The
            // raw-drawing overlay is a window-level surface, so a local rect of
            // (0,0,w,h) is read as the top-left of the screen — which is why ink
            // landed on the toolbar above the pen area and was cut off before
            // the page bottom. The global rect confines drawing to the page.
            val limit = Rect()
            val exclude = emptyList<Rect>()
            view.getGlobalVisibleRect(limit)
            touchHelper.setLimitRect(limit, exclude)

            touchHelper.setRawDrawingEnabled(false)
            touchHelper.setRawDrawingEnabled(true)
        }

        paint.setStrokeWidth(strokeWidth)
        paint.setColor(strokeColor)

        touchHelper.openRawDrawing()
        touchHelper.setRawDrawingEnabled(true)
        touchHelper.setRawDrawingRenderEnabled(false)

        drawPreview()
    }

    override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
        if (call.method == "updateStroke") {
            val params = call.arguments<Map<String, Any>?>()
            updateStroke(params)
            result.success(null)
        } else if (call.method == "setDraw") {
            setDraw(call.arguments<Boolean>()!!)
            result.success(null)
        } else if (call.method == "forceRefresh") {
            // Explicit: the app asks for a clean panel when IT decides one is
            // due (page turn, ghosting), rather than on a timer after writing.
            forceRefresh()
            result.success(null)
        } else {
            result.notImplemented()
        }
    }

    override fun dispose() {
        touchHelper.closeRawDrawing()
    }
}
