package app.apertono.player.dev

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.IBinder

/// Foreground service of type mediaProjection (FT-549): without it Android 14 does not allow
/// recording the app's audio. Holds the consent and the recording while the scenario writes
/// files; lives only in the dev build.
class CaptureService : Service() {

    companion object {
        private const val CHANNEL_ID = "flowtune.gapless.capture"
        private const val NOTIFICATION_ID = 54901
        const val ACTION_BEGIN = "app.apertono.player.dev.BEGIN"
        const val ACTION_RELEASE = "app.apertono.player.dev.RELEASE"
        const val EXTRA_RESULT_CODE = "resultCode"
        const val EXTRA_RESULT_DATA = "resultData"
        const val EXTRA_PATH = "path"

        /// Consent granted: bring up the foreground service and start writing [path].
        fun begin(context: Context, resultCode: Int, data: Intent, path: String?) {
            val intent = Intent(context, CaptureService::class.java).apply {
                action = ACTION_BEGIN
                putExtra(EXTRA_RESULT_CODE, resultCode)
                putExtra(EXTRA_RESULT_DATA, data)
                if (path != null) putExtra(EXTRA_PATH, path)
            }
            context.startForegroundService(intent)
        }

        /// The scenario is done: release the projection and remove the foreground service.
        fun release(context: Context) {
            val intent = Intent(context, CaptureService::class.java).apply {
                action = ACTION_RELEASE
            }
            context.startService(intent)
        }
    }

    private val projectionCallback = object : MediaProjection.Callback() {
        override fun onStop() {
            // The system revoked the consent (notification shade, "stop" in the notification): the recording
            // ends gracefully, and the file is finalized with what it managed to get.
            Capture.release()
            stopForegroundCompat()
            stopSelf()
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_BEGIN -> {
                startForegroundCompat()
                val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, Activity.RESULT_CANCELED)
                @Suppress("DEPRECATION")
                val data = intent.getParcelableExtra<Intent>(EXTRA_RESULT_DATA)
                if (data != null) {
                    val manager =
                        getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
                    val projection = try {
                        manager.getMediaProjection(resultCode, data)
                    } catch (error: Exception) {
                        null
                    }
                    if (projection != null) {
                        projection.registerCallback(projectionCallback, null)
                        Capture.takeProjection(projection)
                        val path = intent.getStringExtra(EXTRA_PATH)
                        if (path != null) Capture.startRecording(path)
                    }
                }
            }
            ACTION_RELEASE -> {
                Capture.release()
                stopForegroundCompat()
                stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        Capture.release()
        super.onDestroy()
    }

    private fun startForegroundCompat() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Запись звука (тест)",
                    NotificationManager.IMPORTANCE_LOW,
                ),
            )
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val notification = builder
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentTitle("Запись звука приложения")
            .setContentText("Идёт тестовая запись (FT-549)")
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(Service.STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }
}
