package app.apertono.player.dev

import android.app.Activity
import android.app.Application
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import com.ryanheise.audioservice.AudioServicePlugin
import io.flutter.embedding.engine.FlutterEngineCache

/// Application of the dev test build (FT-549): hooks the audio capture channel onto the
/// Flutter engine. This class does not exist in prod and staging: their Application stays
/// plain, and the capture code does not get into those builds.
///
/// The channel is registered in the engine that appears inside the activity's onCreate,
/// so registration is deferred to the main looper: by then the engine is already
/// in the audio_service cache (AudioServiceActivity.provideFlutterEngine), and the
/// plugin registry hands the plugin the current activity by itself.
class CaptureApplication : Application() {
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onCreate() {
        super.onCreate()
        registerActivityLifecycleCallbacks(
            object : ActivityLifecycleCallbacks {
                override fun onActivityCreated(activity: Activity, state: Bundle?) {
                    mainHandler.post { attach(attempt = 0) }
                }

                override fun onActivityStarted(activity: Activity) {}

                override fun onActivityResumed(activity: Activity) {}

                override fun onActivityPaused(activity: Activity) {}

                override fun onActivityStopped(activity: Activity) {}

                override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}

                override fun onActivityDestroyed(activity: Activity) {}
            },
        )
    }

    private fun attach(attempt: Int) {
        val engine = FlutterEngineCache.getInstance().get(AudioServicePlugin.getFlutterEngineId())
        if (engine == null) {
            // The engine is not created yet (the activity is not a Flutter one), wait a little.
            if (attempt < 50) {
                mainHandler.postDelayed({ attach(attempt + 1) }, 200)
            }
            return
        }
        if (!engine.plugins.has(GaplessCapturePlugin::class.java)) {
            engine.plugins.add(GaplessCapturePlugin())
        }
    }
}
