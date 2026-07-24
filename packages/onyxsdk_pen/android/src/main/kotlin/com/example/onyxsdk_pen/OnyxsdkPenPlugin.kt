package com.example.onyxsdk_pen

import android.content.Context
import androidx.annotation.NonNull
import com.onyx.android.sdk.rx.RxManager

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import org.lsposed.hiddenapibypass.HiddenApiBypass

/** OnyxsdkPenPlugin */
class OnyxsdkPenPlugin: FlutterPlugin, MethodCallHandler {
  /// The MethodChannel that will the communication between Flutter and native Android
  ///
  /// This local reference serves to register the plugin with the Flutter Engine and unregister it
  /// when the Flutter Engine is detached from the Activity
    private lateinit var channel : MethodChannel
    private var appContext: Context? = null

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
    } else {
      result.notImplemented()
    }
  }

  override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
    appContext = null
  }

  private fun checkHiddenApiBypass() {
    if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
      HiddenApiBypass.addHiddenApiExemptions("")
    }
  }
}
