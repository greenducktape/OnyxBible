package com.example.onyxsdk_pen

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.annotation.NonNull
import com.onyx.android.sdk.rx.RxManager

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import org.lsposed.hiddenapibypass.HiddenApiBypass

/** OnyxsdkPenPlugin */
class OnyxsdkPenPlugin: FlutterPlugin, MethodCallHandler {
  /// The MethodChannel that will the communication between Flutter and native Android
  ///
  /// This local reference serves to register the plugin with the Flutter Engine and unregister it
  /// when the Flutter Engine is detached from the Activity
    private lateinit var channel : MethodChannel
    private var appContext: Context? = null

    // Rendering a page runs off the platform thread. A method-channel handler
    // is called ON the Android main thread, and this one allocates a
    // page-sized bitmap, draws every stroke on it and PNG-encodes the result —
    // hundreds of milliseconds during which nothing on screen responds. Doing
    // that on the main thread is what makes buttons miss and pages refuse to
    // turn. Single-threaded: renders queue behind each other instead of
    // fighting for memory.
    private val renderExecutor: ExecutorService =
        Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

  override fun onAttachedToEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    channel = MethodChannel(binding.binaryMessenger, "onyxsdk_pen")
    channel.setMethodCallHandler(this)
    appContext = binding.applicationContext

    // Needed for new Onyx devices
    RxManager.Builder.initAppContext(binding.applicationContext)
    checkHiddenApiBypass()

    binding
      .platformViewRegistry
      .registerViewFactory(
         "onyxsdk_pen_area",
         OnyxsdkPenAreaFactory(binding.binaryMessenger)
      )
  }

  override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
    if (call.method == "isOnyxDevice") {
      result.success(android.os.Build.BRAND.lowercase() == "onyx")
    } else if (call.method == "displayDpi") {
      // The panel's real physical density, so a nib size can be stated in
      // millimetres. Flutter only exposes the 160dpi-relative pixel ratio,
      // which on an e-ink panel is nowhere near the true dot pitch.
      val metrics = appContext?.resources?.displayMetrics
      val dpi = metrics?.let { (it.xdpi + it.ydpi) / 2f } ?: 0f
      result.success(if (dpi > 1f) dpi.toDouble() else null)
    } else if (call.method == "renderStrokes") {
      // Hands a page of finished strokes to the SDK's own pen renderers and
      // returns the result as a PNG. Null means "draw it yourself" — a
      // non-Onyx device, an allocation failure, or an SDK that declined.
      val args = call.arguments<Map<String, Any?>>()
      @Suppress("UNCHECKED_CAST")
      val strokes = args?.get("strokes") as? List<Map<String, Any?>> ?: emptyList()
      val context = appContext
      val width = (args?.get("width") as? Number)?.toInt() ?: 0
      val height = (args?.get("height") as? Number)?.toInt() ?: 0
      renderExecutor.execute {
        val png = try {
          OnyxStrokeRenderer.renderToPng(context, width, height, strokes)
        } catch (e: Throwable) {
          null
        }
        // A Result must be answered on the main thread.
        mainHandler.post { result.success(png) }
      }
    } else {
      result.notImplemented()
    }
  }

  override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
    appContext = null
    renderExecutor.shutdown()
  }

  private fun checkHiddenApiBypass() {
    if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
      HiddenApiBypass.addHiddenApiExemptions("")
    }
  }
}
