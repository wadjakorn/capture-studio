package dev.wadjakorn.capturestudio.phone

import android.content.Context
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.util.Range
import android.util.Size
import android.view.Surface
import androidx.camera.core.CameraSelector
import androidx.camera.core.Preview
import androidx.camera.core.SurfaceRequest
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import java.util.concurrent.Executors

/**
 * CameraX `Preview` → hardware H.264 encoder input surface. The codec is created
 * inside the SurfaceProvider callback at the size CameraX actually chose. Output
 * is Annex-B, converted to AVCC with SPS/PPS sent only via VIDEO_CONFIG.
 *
 * [start] and [stop] must be called on the main thread.
 */
class VideoPipeline(
    private val context: Context,
    private val lifecycleOwner: LifecycleOwner,
    private val facing: Int, // CameraSelector.LENS_FACING_*
    private val width: Int,
    private val height: Int,
    private val fps: Int,
    private val bitrate: Int,
    private val sink: MediaSink,
) {
    private val mainExecutor = ContextCompat.getMainExecutor(context)
    private var provider: ProcessCameraProvider? = null
    private var preview: Preview? = null
    private var stopped = false
    @Volatile private var codec: MediaCodec? = null
    @Volatile private var rotationDeg = 0
    @Volatile private var configSent = false
    @Volatile private var lastPtsNs = Long.MIN_VALUE

    fun start() {
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            if (stopped) return@addListener
            try {
                bind(future.get())
            } catch (e: Exception) {
                Log.e(TAG, "Camera bind failed", e)
            }
        }, mainExecutor)
    }

    private fun bind(cameraProvider: ProcessCameraProvider) {
        provider = cameraProvider
        val selector = CameraSelector.Builder().requireLensFacing(facing).build()
        val resolution = ResolutionSelector.Builder()
            .setResolutionStrategy(
                ResolutionStrategy(Size(width, height), ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER),
            )
            .build()
        val p = Preview.Builder()
            .setResolutionSelector(resolution)
            .setTargetFrameRate(Range(fps, fps))
            .build()
        p.setSurfaceProvider(surfaceExecutor) { request -> onSurfaceRequest(request) }
        preview = p
        val camera = cameraProvider.bindToLifecycle(lifecycleOwner, selector, p)
        PhoneClock.configure(camera.cameraInfo)
    }

    private fun onSurfaceRequest(request: SurfaceRequest) {
        val size = request.resolution
        Log.i(TAG, "Surface request ${size.width}x${size.height}")
        val thread = HandlerThread("CSPhone-venc").apply { start() }
        val handler = Handler(thread.looper)
        val enc = try {
            createEncoder(size, handler, withProfile = true)
        } catch (e: Exception) {
            Log.w(TAG, "Encoder configure with Baseline/4.1 failed; retrying without profile/level", e)
            try {
                createEncoder(size, handler, withProfile = false)
            } catch (e2: Exception) {
                Log.e(TAG, "Encoder configure failed", e2)
                thread.quitSafely()
                request.willNotProvideSurface()
                return
            }
        }
        val surface: Surface = enc.createInputSurface()
        enc.start()
        codec = enc
        request.setTransformationInfoListener(surfaceExecutor) { info -> rotationDeg = info.rotationDegrees }
        request.provideSurface(surface, surfaceExecutor) { result ->
            // Release order: CameraX is done with the surface (this result callback)
            // before the codec that owns it is released. Release on the codec's
            // handler thread so it is serialized with the output callbacks.
            Log.i(TAG, "Surface released by camera (result ${result.resultCode})")
            handler.post {
                if (codec === enc) codec = null
                runCatching { enc.stop() }
                runCatching { enc.release() }
                surface.release()
                thread.quitSafely()
            }
        }
    }

    private fun createEncoder(size: Size, handler: Handler, withProfile: Boolean): MediaCodec {
        val enc = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        try {
            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, size.width, size.height).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
                setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
                setInteger(MediaFormat.KEY_FRAME_RATE, fps)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
                setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
                setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)
                if (withProfile) {
                    setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline)
                    setInteger(MediaFormat.KEY_LEVEL, MediaCodecInfo.CodecProfileLevel.AVCLevel41)
                }
            }
            enc.setCallback(callback, handler) // before configure: async mode
            enc.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            return enc
        } catch (e: Exception) {
            enc.release()
            throw e
        }
    }

    private val callback = object : MediaCodec.Callback() {
        override fun onInputBufferAvailable(codec: MediaCodec, index: Int) = Unit // surface input

        override fun onOutputBufferAvailable(codec: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
            try {
                val buffer = codec.getOutputBuffer(index)
                if (buffer != null && info.size > 0) {
                    buffer.position(info.offset)
                    buffer.limit(info.offset + info.size)
                    val bytes = ByteArray(info.size).also { buffer.get(it) }
                    handleOutput(bytes, info)
                }
            } catch (e: Exception) {
                Log.e(TAG, "Video output handling failed", e)
            } finally {
                runCatching { codec.releaseOutputBuffer(index, false) }
            }
        }

        override fun onError(codec: MediaCodec, e: MediaCodec.CodecException) {
            Log.e(TAG, "Video encoder error", e)
        }

        override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
            Log.i(TAG, "Video encoder output format: $format")
        }
    }

    private fun handleOutput(bytes: ByteArray, info: MediaCodec.BufferInfo) {
        if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
            if (configSent) return
            val (sps, pps) = AnnexB.parameterSets(bytes)
            configSent = true
            sink.videoConfig(listOf(sps, pps))
            return
        }
        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
        val ptsNs = PhoneClock.toBoottime(info.presentationTimeUs * 1000)
        if (ptsNs <= lastPtsNs) {
            Log.w(TAG, "Non-increasing video PTS $ptsNs <= $lastPtsNs; frame dropped")
            return
        }
        lastPtsNs = ptsNs
        val nalus = AnnexB.toAvcc(bytes)
        if (nalus.isEmpty()) return
        sink.videoFrame(
            VideoFrame(
                ptsNs = ptsNs,
                keyframe = info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0,
                mirrored = facing == CameraSelector.LENS_FACING_FRONT,
                rotationDeg = rotationDeg,
                nalus = nalus,
            ),
        )
    }

    /** Thread-safe; asks the encoder for an IDR as soon as possible. */
    fun requestKeyframe() {
        val c = codec ?: return
        try {
            c.setParameters(Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0) })
        } catch (e: IllegalStateException) {
            Log.w(TAG, "Keyframe request failed: ${e.message}")
        }
    }

    /** Unbinds the camera; the provideSurface result callback then releases the codec. */
    fun stop() {
        if (stopped) return
        stopped = true
        preview?.let { provider?.unbind(it) }
        preview = null
    }

    private companion object {
        const val TAG = "CSPhone"

        /** Shared across pipelines: surface/result callbacks may still arrive after [stop]. */
        val surfaceExecutor = Executors.newSingleThreadExecutor { r ->
            Thread(r, "CSPhone-vsurface").apply { isDaemon = true }
        }
    }
}
