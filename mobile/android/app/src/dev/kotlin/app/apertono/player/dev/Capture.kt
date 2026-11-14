package app.apertono.player.dev

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.projection.MediaProjection
import android.os.Handler
import android.os.Looper
import android.os.Process
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder

/// Recording of the app's own audio (FT-549): AudioPlaybackCapture for its own
/// UID and USAGE_MEDIA, PCM 16-bit, 48 kHz, stereo -> WAV in the app folder.
///
/// Lives only in the dev build. The capture records exactly what a person hears from the
/// app: a pause between tracks in the recording is a pause in the headphones.
object Capture {
    private const val SAMPLE_RATE = 48_000
    private const val CHANNELS = 2
    private const val BYTES_PER_FRAME = CHANNELS * 2
    private val mainHandler = Handler(Looper.getMainLooper())

    private var projection: MediaProjection? = null
    private var record: AudioRecord? = null
    private var onStopped: ((Boolean) -> Unit)? = null

    @Volatile
    private var stopRequested = false

    @Volatile
    private var recording = false

    val isRecording: Boolean
        get() = recording

    val hasProjection: Boolean
        get() = projection != null

    /// Consent granted: the foreground service already holds the projection, files can be written.
    fun takeProjection(mediaProjection: MediaProjection) {
        projection = mediaProjection
    }

    /// Start writing WAV to [path]. The gapless phase between files is the scenario's
    /// concern; the recording faithfully writes everything the app outputs.
    fun startRecording(path: String): Boolean {
        if (recording) return false
        val mediaProjection = projection ?: return false
        val capture = try {
            AudioPlaybackCaptureConfiguration.Builder(mediaProjection)
                .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                .addMatchingUid(Process.myUid())
                .build()
        } catch (error: Exception) {
            return false
        }
        val format = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(SAMPLE_RATE)
            .setChannelMask(AudioFormat.CHANNEL_IN_STEREO)
            .build()
        val audioRecord = try {
            AudioRecord.Builder()
                .setAudioFormat(format)
                .setAudioPlaybackCaptureConfig(capture)
                .build()
        } catch (error: Exception) {
            return false
        }
        if (audioRecord.state != AudioRecord.STATE_INITIALIZED) {
            audioRecord.release()
            return false
        }
        val file = try {
            RandomAccessFile(File(path), "rw").also {
                it.setLength(0)
                it.write(wavHeader(0))
            }
        } catch (error: Exception) {
            audioRecord.release()
            return false
        }
        record = audioRecord
        stopRequested = false
        recording = true
        audioRecord.startRecording()
        Thread({ readLoop(audioRecord, file) }, "gapless-capture").start()
        return true
    }

    /// Stop recording and finish the WAV. [onDone] arrives on the main thread.
    fun stopRecording(onDone: (Boolean) -> Unit) {
        if (!recording) {
            mainHandler.post { onDone(true) }
            return
        }
        onStopped = onDone
        stopRequested = true
        try {
            record?.stop()
        } catch (error: Exception) {
            // The recording thread will exit on stopRequested anyway.
        }
    }

    /// Release the projection: Android consent is granted for one session only.
    fun release() {
        stopRecording { }
        try {
            projection?.stop()
        } catch (error: Exception) {
            // Already stopped by the system, nothing to release.
        }
        projection = null
    }

    private fun readLoop(audioRecord: AudioRecord, file: RandomAccessFile) {
        val samples = ShortArray(2048 * CHANNELS)
        val bytes = ByteBuffer.allocate(samples.size * 2).order(ByteOrder.LITTLE_ENDIAN)
        var frames = 0L
        try {
            while (!stopRequested) {
                val read = audioRecord.read(samples, 0, samples.size)
                if (read <= 0) break
                bytes.clear()
                bytes.asShortBuffer().put(samples, 0, read)
                file.write(bytes.array(), 0, read * 2)
                frames += read.toLong()
            }
        } catch (error: Exception) {
            // The file is finalized with what has already been read.
        }
        try {
            file.seek(0)
            file.write(wavHeader(frames * BYTES_PER_FRAME))
            file.close()
        } catch (error: Exception) {
            // The check will flag a truncated WAV by itself, which is more honest than faking it.
        }
        try {
            audioRecord.release()
        } catch (error: Exception) {
            // Already released.
        }
        record = null
        recording = false
        val done = onStopped
        onStopped = null
        mainHandler.post { done?.invoke(true) }
    }

    /// WAV header: PCM, 16-bit, stereo, 48 kHz. The sizes are written at the
    /// end of the recording, so the file is readable even after the scenario is cut off.
    private fun wavHeader(dataSize: Long): ByteArray {
        val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        fun tag(text: String) {
            for (index in text.indices) {
                header.put(text[index].code.toByte())
            }
        }
        tag("RIFF")
        header.putInt((36L + dataSize).toInt())
        tag("WAVE")
        tag("fmt ")
        header.putInt(16)
        header.putShort(1) // PCM
        header.putShort(CHANNELS.toShort())
        header.putInt(SAMPLE_RATE)
        header.putInt(SAMPLE_RATE * BYTES_PER_FRAME)
        header.putShort(BYTES_PER_FRAME.toShort())
        header.putShort(16)
        tag("data")
        header.putInt(dataSize.toInt())
        return header.array()
    }
}
