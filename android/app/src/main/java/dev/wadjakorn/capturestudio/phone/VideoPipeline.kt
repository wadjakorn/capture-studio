package dev.wadjakorn.capturestudio.phone

import android.content.Context
import android.content.res.Resources
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
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import androidx.camera.core.CameraInfo
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
 * CameraX `Preview` → [EncoderGlRelay] (OpenGL ES) → hardware H.264 encoder input
 * surface. The codec is created inside the SurfaceProvider callback at the size
 * CameraX actually chose. Output is Annex-B, converted to AVCC with SPS/PPS sent
 * only via VIDEO_CONFIG.
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
    /** Fatal camera/encoder failure (any thread). Not called after [stop]. */
    private val onFailure: (String) -> Unit,
) {
    private val mainExecutor = ContextCompat.getMainExecutor(context)
    private var provider: ProcessCameraProvider? = null
    private var preview: Preview? = null
    @Volatile private var stopped = false
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
                fail("Camera could not start: ${e.message}")
            }
        }, mainExecutor)
    }

    private fun bind(cameraProvider: ProcessCameraProvider) {
        provider = cameraProvider
        val selector = cameraSelector()
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
        Log.i(TAG, "Camera bound: id=${cameraId(camera.cameraInfo)} facing=$facing")
        PhoneClock.configure(camera.cameraInfo)
    }

    /**
     * BACK: CameraX default. FRONT: on devices with several front cameras (foldables:
     * cover-screen selfie camera + inner camera) the first one may deliver no frames
     * in the other posture, so prefer the highest camera id when unfolded (large
     * smallest-width), the lowest otherwise.
     */
    private fun cameraSelector(): CameraSelector {
        val builder = CameraSelector.Builder().requireLensFacing(facing)
        if (facing == CameraSelector.LENS_FACING_FRONT) {
            builder.addCameraFilter { infos ->
                if (infos.size <= 1) return@addCameraFilter infos
                val unfolded = Resources.getSystem().configuration.smallestScreenWidthDp >= 600
                val sorted = infos.sortedWith(compareBy<CameraInfo>({ cameraId(it).toIntOrNull() ?: Int.MAX_VALUE }, { cameraId(it) }))
                val ordered = if (unfolded) sorted.reversed() else sorted
                Log.i(TAG, "Front cameras ${infos.map { cameraId(it) }}, unfolded=$unfolded -> ${cameraId(ordered.first())}")
                ordered
            }
        }
        return builder.build()
    }

    @androidx.annotation.OptIn(markerClass = [ExperimentalCamera2Interop::class])
    private fun cameraId(info: CameraInfo): String =
        runCatching { Camera2CameraInfo.from(info).cameraId }.getOrDefault("?")

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
                fail("Video encoder could not be configured: ${e2.message}")
                return
            }
        }
        val encoderSurface: Surface = try {
            enc.createInputSurface().also { enc.start() }
        } catch (e: Exception) {
            Log.e(TAG, "Encoder start failed", e)
            enc.release()
            thread.quitSafely()
            request.willNotProvideSurface()
            fail("Video encoder could not start: ${e.message}")
            return
        }
        // Releases the codec (on its own handler thread, serialized with output
        // callbacks), then the encoder input surface it owns. Only after the relay
        // stopped drawing into that surface.
        val releaseEncoder = {
            handler.post {
                if (codec === enc) codec = null
                runCatching { enc.stop() }
                runCatching { enc.release() }
                encoderSurface.release()
                thread.quitSafely()
            }
            Unit
        }
        val relay = EncoderGlRelay(encoderSurface, size.width, size.height) { message -> fail(message) }
        try {
            relay.start()
        } catch (e: Exception) {
            Log.e(TAG, "GL relay setup failed", e)
            releaseEncoder()
            request.willNotProvideSurface()
            fail("Video relay could not start: ${e.message}")
            return
        }
        codec = enc
        request.setTransformationInfoListener(surfaceExecutor) { info -> rotationDeg = info.rotationDegrees }
        request.provideSurface(relay.cameraSurface(), surfaceExecutor) { result ->
            // Release order: CameraX is done with the camera surface (this result
            // callback) → relay drops the SurfaceTexture and EGL objects on the GL
            // thread → codec stop/release → encoder input surface → threads quit.
            Log.i(TAG, "Surface released by camera (result ${result.resultCode})")
            relay.release(releaseEncoder)
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
            Log.e(TAG, "Video encoder error (transient=${e.isTransient}, recoverable=${e.isRecoverable})", e)
            if (!e.isTransient) fail("Video encoder error: ${e.diagnosticInfo}")
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

    private fun fail(message: String) {
        if (!stopped) onFailure(message)
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
