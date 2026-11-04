package dev.wadjakorn.capturestudio.phone

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.AudioTimestamp
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaRecorder
import android.os.SystemClock
import android.util.Log
import androidx.core.content.ContextCompat

/**
 * `AudioRecord` (48 kHz mono PCM16) → AAC-LC encoder. PTS are BOOTTIME, derived
 * from `AudioRecord.getTimestamp(TIMEBASE_BOOTTIME)` plus the frames read since —
 * never from when `read()` happened to return.
 */
class AudioPipeline(private val context: Context, private val sink: MediaSink) {
    @Volatile private var running = false
    private var thread: Thread? = null

    fun start() {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            Log.e(TAG, "RECORD_AUDIO not granted; audio disabled")
            return
        }
        running = true
        thread = Thread(::run, "CSPhone-audio").apply { start() }
    }

    fun stop() {
        running = false
        thread?.join(1000)
        thread = null
    }

    private fun run() {
        var record: AudioRecord? = null
        var codec: MediaCodec? = null
        try {
            val minBuf = AudioRecord.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
            val rec = try {
                AudioRecord(
                    MediaRecorder.AudioSource.VOICE_RECOGNITION, SAMPLE_RATE,
                    AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
                    maxOf(minBuf, CHUNK_BYTES) * 4,
                )
            } catch (e: SecurityException) {
                Log.e(TAG, "AudioRecord denied", e)
                return
            }
            record = rec
            if (rec.state != AudioRecord.STATE_INITIALIZED) {
                Log.e(TAG, "AudioRecord failed to initialize")
                return
            }
            val enc = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
            codec = enc
            val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, SAMPLE_RATE, 1).apply {
                setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                setInteger(MediaFormat.KEY_BIT_RATE, 128_000)
                setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16_384)
            }
            enc.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            enc.start()
            rec.startRecording()

            val pcm = ByteArray(CHUNK_BYTES)
            val ts = AudioTimestamp()
            var haveTs = false
            var lastTsRefreshMs = 0L
            var framesRead = 0L
            var lastPtsUs = Long.MIN_VALUE
            val info = MediaCodec.BufferInfo()

            while (running) {
                val n = readFully(rec, pcm)
                if (n <= 0) {
                    if (n < 0) Log.e(TAG, "AudioRecord.read error $n")
                    if (n < 0) break else continue
                }
                val chunkStartFrame = framesRead
                framesRead += n / BYTES_PER_FRAME

                val now = SystemClock.elapsedRealtime()
                if (!haveTs || now - lastTsRefreshMs >= TS_REFRESH_MS) {
                    if (rec.getTimestamp(ts, AudioTimestamp.TIMEBASE_BOOTTIME) == AudioRecord.SUCCESS) {
                        haveTs = true
                        lastTsRefreshMs = now
                    }
                }
                if (haveTs) {
                    var ptsUs = (ts.nanoTime + (chunkStartFrame - ts.framePosition) * 1_000_000_000L / SAMPLE_RATE) / 1000
                    if (ptsUs <= lastPtsUs) ptsUs = lastPtsUs + 1 // timestamp refresh jitter: keep strictly increasing
                    lastPtsUs = ptsUs
                    queueInput(enc, pcm, n, ptsUs)
                }
                drainOutput(enc, info)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Audio pipeline failed", e)
        } finally {
            record?.let { r ->
                runCatching { r.stop() }
                r.release()
            }
            codec?.let { c ->
                runCatching { c.stop() }
                c.release()
            }
        }
    }

    private fun readFully(rec: AudioRecord, buf: ByteArray): Int {
        var off = 0
        while (off < buf.size && running) {
            val r = rec.read(buf, off, buf.size - off)
            if (r < 0) return r
            off += r
        }
        return off
    }

    private fun queueInput(enc: MediaCodec, pcm: ByteArray, len: Int, ptsUs: Long) {
        val index = enc.dequeueInputBuffer(INPUT_TIMEOUT_US)
        if (index < 0) {
            Log.w(TAG, "AAC encoder input unavailable; chunk dropped")
            return
        }
        val input = enc.getInputBuffer(index) ?: return
        input.clear()
        input.put(pcm, 0, len)
        enc.queueInputBuffer(index, 0, len, ptsUs, 0)
    }

    private fun drainOutput(enc: MediaCodec, info: MediaCodec.BufferInfo) {
        while (true) {
            val index = enc.dequeueOutputBuffer(info, 0)
            if (index < 0) return // TRY_AGAIN_LATER / FORMAT_CHANGED
            try {
                val buf = enc.getOutputBuffer(index)
                if (buf != null && info.size > 0) {
                    buf.position(info.offset)
                    buf.limit(info.offset + info.size)
                    val bytes = ByteArray(info.size).also { buf.get(it) }
                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                        sink.audioConfig(bytes)
                    } else if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM == 0) {
                        sink.audioFrame(AudioFrame(info.presentationTimeUs * 1000, bytes))
                    }
                }
            } finally {
                enc.releaseOutputBuffer(index, false)
            }
        }
    }

    private companion object {
        const val TAG = "CSPhone"
        const val SAMPLE_RATE = 48_000
        const val BYTES_PER_FRAME = 2
        const val CHUNK_FRAMES = 1024
        const val CHUNK_BYTES = CHUNK_FRAMES * BYTES_PER_FRAME
        const val TS_REFRESH_MS = 1000L
        const val INPUT_TIMEOUT_US = 10_000L
    }
}
