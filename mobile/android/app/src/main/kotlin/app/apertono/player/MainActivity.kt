package app.apertono.player

import android.Manifest
import android.app.PendingIntent
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Uri
import android.os.Build
import android.os.StatFs
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import kotlin.concurrent.thread

// The player's background service and notification live on AudioServiceActivity,
// so this activity extends it instead of replacing it (FT-522, Р-A60).
class MainActivity : AudioServiceActivity() {
    companion object {
        private const val PERMISSION_REQUEST_MEDIA = 1001
    }

    private var openChannel: MethodChannel? = null
    private var pendingMediaResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // "Open with" (FT-767): Dart takes the launch file by itself, the following ones
        // come here, while the app is open.
        openChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "apertono/open").also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "initialAudio" -> {
                        result.success(openedAudio(intent))
                        intent = Intent(Intent.ACTION_MAIN)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "apertono/device")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "androidRelease" -> result.success(Build.VERSION.RELEASE)
                    "isMetered" -> result.success(isMetered())
                    "freeBytes" -> result.success(freeBytes())
                    "openUrl" -> {
                        openUrl(call.arguments as? String)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "apertono/update")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "install" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("invalid-argument", "Missing path argument", null)
                            return@setMethodCallHandler
                        }
                        installApk(path, result)
                    }
                    else -> result.notImplemented()
                }
            }

        // The screen does not go dark while the lyrics of the playing song are open (FT-843).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "apertono/screen")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "keepOn" -> {
                        val flag = android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
                        if (call.arguments == true) window.addFlags(flag) else window.clearFlags(flag)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        // Music from the phone (FT-783): reading MediaStore and access to audio files.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "apertono/media")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "access" -> result.success(checkMediaAccess())
                    "request" -> requestMediaAccess(result)
                    "songs" -> {
                        thread {
                            val songs = querySongs()
                            runOnUiThread {
                                result.success(songs)
                            }
                        }
                    }
                    "openSettings" -> {
                        openAppSettings()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun installApk(path: String, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            if (!packageManager.canRequestPackageInstalls()) {
                val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                    data = Uri.parse("package:$packageName")
                }
                startActivity(intent)
                result.error("needs-permission", "Permission to install unknown apps is required", null)
                return
            }
        }

        val file = File(path)
        if (!file.exists()) {
            result.error("file-not-found", "File not found: $path", null)
            return
        }

        val packageInstaller = packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        val sessionId = try {
            packageInstaller.createSession(params)
        } catch (e: Exception) {
            result.error("session-create-failed", e.message, null)
            return
        }

        var session: PackageInstaller.Session? = null
        try {
            session = packageInstaller.openSession(sessionId)
            file.inputStream().use { input ->
                session.openWrite("package", 0, file.length()).use { output ->
                    input.copyTo(output)
                    session.fsync(output)
                }
            }
            val intent = Intent(this, MainActivity::class.java)
            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
            val pendingIntent = PendingIntent.getActivity(this, 0, intent, flags)
            session.commit(pendingIntent.intentSender)
            result.success(null)
        } catch (e: Exception) {
            session?.abandon()
            result.error("install-failed", e.message, null)
        } finally {
            session?.close()
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val opened = openedAudio(intent) ?: return
        openChannel?.invokeMethod("openAudio", opened)
    }

    // Only content:// from the system and only audio: the address and file name for the screen.
    private fun openedAudio(intent: Intent?): Map<String, String>? {
        if (intent?.action != Intent.ACTION_VIEW) return null
        val uri = intent.data ?: return null
        if (uri.scheme != "content") return null
        val type = intent.type ?: contentResolver.getType(uri)
        if (type != null && !type.startsWith("audio/")) return null
        var name = ""
        try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                if (it.moveToFirst()) name = it.getString(0) ?: ""
            }
        } catch (_: Exception) {
        }
        return mapOf("uri" to uri.toString(), "name" to name.substringBeforeLast('.'))
    }

    // Browser or an app that handles the link (t.me, YouTube) — the system
    // picks. No handler, or none installed: the tap just does nothing (FT-579).
    private fun openUrl(url: String?) {
        if (url.isNullOrEmpty()) return
        // The address comes from a third-party feed: web links only.
        if (!url.startsWith("https://") && !url.startsWith("http://")) return
        try {
            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
        } catch (_: Exception) {
        }
    }

    // No ConnectivityManager → assume metered, so downloads stay off.
    private fun isMetered(): Boolean {
        val manager = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return true
        return manager.isActiveNetworkMetered
    }

    // Free space in the app folder: the listened-ahead reserve must not eat
    // the space the system itself needs (FT-529).
    private fun freeBytes(): Long = StatFs(filesDir.path).availableBytes

    private fun mediaPermission(): String =
        if (Build.VERSION.SDK_INT >= 33) {
            Manifest.permission.READ_MEDIA_AUDIO
        } else {
            Manifest.permission.READ_EXTERNAL_STORAGE
        }

    private fun checkMediaAccess(): String {
        val permission = mediaPermission()
        return if (ContextCompat.checkSelfPermission(this, permission) == PackageManager.PERMISSION_GRANTED) {
            "granted"
        } else {
            "denied"
        }
    }

    private fun requestMediaAccess(result: MethodChannel.Result) {
        val permission = mediaPermission()
        if (ContextCompat.checkSelfPermission(this, permission) == PackageManager.PERMISSION_GRANTED) {
            result.success("granted")
            return
        }
        pendingMediaResult?.let {
            try { it.success("denied") } catch (_: Exception) {}
        }
        pendingMediaResult = result
        ActivityCompat.requestPermissions(this, arrayOf(permission), PERMISSION_REQUEST_MEDIA)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == PERMISSION_REQUEST_MEDIA) {
            val result = pendingMediaResult ?: return
            pendingMediaResult = null
            val permission = mediaPermission()
            val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
            if (granted) {
                result.success("granted")
            } else {
                val showRationale = ActivityCompat.shouldShowRequestPermissionRationale(this, permission)
                if (!showRationale) {
                    result.success("denied_forever")
                } else {
                    result.success("denied")
                }
            }
        }
    }

    private fun openAppSettings() {
        try {
            val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.fromParts("package", packageName, null)
            }
            startActivity(intent)
        } catch (_: Exception) {
        }
    }

    private fun querySongs(): List<Map<String, Any?>> {
        val songs = mutableListOf<Map<String, Any?>>()
        val projection = arrayOf(
            MediaStore.Audio.Media._ID,
            MediaStore.Audio.Media.TITLE,
            MediaStore.Audio.Media.ARTIST,
            MediaStore.Audio.Media.ALBUM,
            MediaStore.Audio.Media.ALBUM_ID,
            MediaStore.Audio.Media.DURATION,
            MediaStore.Audio.Media.TRACK,
            MediaStore.Audio.Media.DATA
        )
        val selection = "${MediaStore.Audio.Media.IS_MUSIC} != 0"
        try {
            contentResolver.query(
                MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
                projection,
                selection,
                null,
                null
            )?.use { cursor ->
                val idCol = cursor.getColumnIndex(MediaStore.Audio.Media._ID)
                val titleCol = cursor.getColumnIndex(MediaStore.Audio.Media.TITLE)
                val artistCol = cursor.getColumnIndex(MediaStore.Audio.Media.ARTIST)
                val albumCol = cursor.getColumnIndex(MediaStore.Audio.Media.ALBUM)
                val albumIdCol = cursor.getColumnIndex(MediaStore.Audio.Media.ALBUM_ID)
                val durationCol = cursor.getColumnIndex(MediaStore.Audio.Media.DURATION)
                val trackCol = cursor.getColumnIndex(MediaStore.Audio.Media.TRACK)
                val pathCol = cursor.getColumnIndex(MediaStore.Audio.Media.DATA)

                while (cursor.moveToNext()) {
                    val id = if (idCol != -1) cursor.getLong(idCol) else continue
                    val uri = ContentUris.withAppendedId(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, id).toString()
                    val title = if (titleCol != -1) cursor.getString(titleCol) ?: "" else ""
                    val artist = if (artistCol != -1) cursor.getString(artistCol) ?: "" else ""
                    val album = if (albumCol != -1) cursor.getString(albumCol) ?: "" else ""
                    val albumIdRaw = if (albumIdCol != -1 && !cursor.isNull(albumIdCol)) cursor.getLong(albumIdCol) else 0L
                    val albumId = if (albumIdRaw > 0L) albumIdRaw.toString() else ""
                    val durationMs = if (durationCol != -1 && !cursor.isNull(durationCol)) cursor.getLong(durationCol) else 0L
                    val track = if (trackCol != -1 && !cursor.isNull(trackCol)) cursor.getInt(trackCol) else null
                    val path = if (pathCol != -1) cursor.getString(pathCol) ?: "" else ""

                    songs.add(
                        mapOf(
                            "uri" to uri,
                            "title" to title,
                            "artist" to artist,
                            "album" to album,
                            "albumId" to albumId,
                            "durationMs" to durationMs,
                            "track" to track,
                            "path" to path
                        )
                    )
                }
            }
        } catch (_: Exception) {
        }
        return songs
    }
}