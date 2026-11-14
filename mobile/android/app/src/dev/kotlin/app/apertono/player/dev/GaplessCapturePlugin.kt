package app.apertono.player.dev

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionManager
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/// Channel "start recording to a file" / "stop" (FT-549). Lives only in the
/// dev test build: prod has no capture code at all.
///
/// How it works with the scenario:
///   start(path) -> false   — Android showed the consent window; a script on the Mac
///                            taps it (GAP_ASK=consent), and the recording starts;
///   start(path) -> true    — the recording is already being written to path;
///   isRecording            — the scenario waits for true after consent;
///   stop()                 — the recording is closed, the WAV is finalized;
///   close()                — the projection is released, the foreground service is removed.
class GaplessCapturePlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    ActivityAware,
    PluginRegistry.ActivityResultListener {

    companion object {
        const val CHANNEL = "apertono/gapless"
        private const val REQUEST_CONSENT = 54901
    }

    private var channel: MethodChannel? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var appContext: Context? = null
    private var pendingPath: String? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        appContext = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() = detach()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() = detach()

    private fun detach() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> start(call, result)
            "stop" -> Capture.stopRecording { ok -> result.success(ok) }
            "isRecording" -> result.success(Capture.isRecording)
            "close" -> {
                val context = appContext
                if (context != null) CaptureService.release(context)
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun start(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        val context = appContext
        if (path.isNullOrBlank() || context == null) {
            result.error("bad-args", "нужен путь файла записи", null)
            return
        }
        if (
            Build.VERSION.SDK_INT >= 23 &&
            context.checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            result.error("no-permission", "нет разрешения RECORD_AUDIO", null)
            return
        }
        if (Capture.hasProjection) {
            result.success(Capture.startRecording(path))
            return
        }
        // Android's consent to record the app's audio is a system window. A script on the
        // Mac taps it (GAP_ASK=consent), not the scenario.
        val activity = activityBinding?.activity
        if (activity == null) {
            result.error("no-activity", "нет активности для окна согласия", null)
            return
        }
        pendingPath = path
        val manager =
            context.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        activity.startActivityForResult(manager.createScreenCaptureIntent(), REQUEST_CONSENT)
        result.success(false)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CONSENT) return false
        val context = appContext
        val path = pendingPath
        pendingPath = null
        if (resultCode != Activity.RESULT_OK || data == null || context == null) {
            // The user refused: the scenario will see that the recording did not start.
            return true
        }
        CaptureService.begin(context, resultCode, data, path)
        return true
    }
}
