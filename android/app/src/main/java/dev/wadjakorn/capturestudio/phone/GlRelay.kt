package dev.wadjakorn.capturestudio.phone

import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Relays camera frames to a MediaCodec input surface through OpenGL ES.
 *
 * The camera renders into a [SurfaceTexture] (external OES texture) owned by this
 * relay; every frame is drawn as a full-screen quad onto an EGL window surface
 * wrapping the encoder's input [Surface], stamped with the camera buffer timestamp.
 * Some camera HAL / encoder pairs (e.g. Samsung + Qualcomm on Android 16) cannot
 * share buffers directly — the encoder then emits valid H.264 full of noise.
 *
 * No rotation or mirroring is applied here; the SurfaceTexture transform matrix
 * only maps buffer coordinates. All GL/EGL work happens on a private GL thread.
 */
class EncoderGlRelay(
    private val encoderSurface: Surface,
    private val width: Int,
    private val height: Int,
    /** Size CameraX renders into the SurfaceTexture (pre-transform). */
    private val cameraWidth: Int = width,
    private val cameraHeight: Int = height,
    /** Flip the output horizontally (front cameras arrive mirrored from the HAL). */
    private val mirrorX: Boolean = false,
    /** GL/EGL failure while running (GL thread). Not called after [release]. */
    private val onError: (String) -> Unit,
) {
    private val thread = HandlerThread("CSPhone-gl")
    private lateinit var handler: Handler

    private var display: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var context: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE
    private var program = 0
    private var texId = 0
    private var aPosition = -1
    private var aTexCoord = -1
    private var uSTMatrix = -1
    private var surfaceTexture: SurfaceTexture? = null
    private var camSurface: Surface? = null
    private val stMatrix = FloatArray(16)
    @Volatile private var released = false // release() requested (or setup failed)
    @Volatile private var failed = false // a frame failed; stop drawing, still needs release()

    private val vertices: FloatBuffer = if (mirrorX) floatBuffer(1f, -1f, -1f, -1f, 1f, 1f, -1f, 1f)
                                        else floatBuffer(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f)
    private val texCoords: FloatBuffer = floatBuffer(0f, 0f, 1f, 0f, 0f, 1f, 1f, 1f)

    /**
     * Starts the GL thread and sets up EGL, the shader and the camera-facing
     * SurfaceTexture. Blocks the caller until setup finished; throws on failure
     * (resources are already cleaned up then).
     */
    fun start() {
        thread.start()
        handler = Handler(thread.looper)
        val latch = CountDownLatch(1)
        var error: Throwable? = null
        handler.post {
            try {
                setUp()
            } catch (t: Throwable) {
                error = t
                tearDownGl()
            } finally {
                latch.countDown()
            }
        }
        if (!latch.await(SETUP_TIMEOUT_S, TimeUnit.SECONDS)) {
            released = true
            handler.post { tearDownGl() }
            thread.quitSafely()
            throw IllegalStateException("GL relay setup timed out")
        }
        error?.let {
            released = true
            thread.quitSafely()
            throw it
        }
    }

    /** The surface the camera should render into. Valid after [start]. */
    fun cameraSurface(): Surface = checkNotNull(camSurface) { "GL relay not started" }

    /**
     * Stops relaying and releases the camera-facing Surface/SurfaceTexture and all
     * EGL objects on the GL thread, then calls [onReleased] (from the GL thread)
     * and quits it. Does not release [encoderSurface]; the caller owns it and must
     * release it only after [onReleased]. Non-blocking; idempotent.
     */
    fun release(onReleased: () -> Unit) {
        if (released) {
            onReleased()
            return
        }
        released = true
        handler.post {
            tearDownGl()
            try {
                onReleased()
            } finally {
                thread.quitSafely()
            }
        }
    }

    private fun setUp() {
        display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        if (display == EGL14.EGL_NO_DISPLAY) throw IllegalStateException("eglGetDisplay failed")
        val version = IntArray(2)
        if (!EGL14.eglInitialize(display, version, 0, version, 1)) {
            display = EGL14.EGL_NO_DISPLAY
            throw IllegalStateException("eglInitialize failed: ${eglError()}")
        }
        val configAttribs = intArrayOf(
            EGL14.EGL_RED_SIZE, 8,
            EGL14.EGL_GREEN_SIZE, 8,
            EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT,
            EGL_RECORDABLE_ANDROID, 1,
            EGL14.EGL_NONE,
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val numConfigs = IntArray(1)
        if (!EGL14.eglChooseConfig(display, configAttribs, 0, configs, 0, 1, numConfigs, 0) ||
            numConfigs[0] < 1 || configs[0] == null
        ) {
            throw IllegalStateException("No recordable EGL config: ${eglError()}")
        }
        val config = configs[0]!!
        context = EGL14.eglCreateContext(
            display, config, EGL14.EGL_NO_CONTEXT,
            intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0,
        )
        if (context == EGL14.EGL_NO_CONTEXT) throw IllegalStateException("eglCreateContext failed: ${eglError()}")
        eglSurface = EGL14.eglCreateWindowSurface(display, config, encoderSurface, intArrayOf(EGL14.EGL_NONE), 0)
        if (eglSurface == EGL14.EGL_NO_SURFACE) throw IllegalStateException("eglCreateWindowSurface failed: ${eglError()}")
        if (!EGL14.eglMakeCurrent(display, eglSurface, eglSurface, context)) {
            throw IllegalStateException("eglMakeCurrent failed: ${eglError()}")
        }

        program = buildProgram()
        aPosition = GLES20.glGetAttribLocation(program, "aPosition")
        aTexCoord = GLES20.glGetAttribLocation(program, "aTexCoord")
        uSTMatrix = GLES20.glGetUniformLocation(program, "uSTMatrix")

        val tex = IntArray(1)
        GLES20.glGenTextures(1, tex, 0)
        texId = tex[0]
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, texId)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        checkGl("texture setup")

        val st = SurfaceTexture(texId)
        st.setDefaultBufferSize(cameraWidth, cameraHeight)
        st.setOnFrameAvailableListener({ drawFrame() }, handler)
        surfaceTexture = st
        camSurface = Surface(st)
        Log.i(TAG, "GL relay ready ${width}x$height (EGL ${version[0]}.${version[1]})")
    }

    /** GL thread. */
    private fun drawFrame() {
        if (released || failed) return
        val st = surfaceTexture ?: return
        try {
            st.updateTexImage()
            st.getTransformMatrix(stMatrix)
            GLES20.glViewport(0, 0, width, height)
            GLES20.glUseProgram(program)
            GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, texId)
            GLES20.glUniformMatrix4fv(uSTMatrix, 1, false, stMatrix, 0)
            GLES20.glEnableVertexAttribArray(aPosition)
            GLES20.glVertexAttribPointer(aPosition, 2, GLES20.GL_FLOAT, false, 0, vertices)
            GLES20.glEnableVertexAttribArray(aTexCoord)
            GLES20.glVertexAttribPointer(aTexCoord, 2, GLES20.GL_FLOAT, false, 0, texCoords)
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
            checkGl("draw")
            EGLExt.eglPresentationTimeANDROID(display, eglSurface, st.timestamp)
            if (!EGL14.eglSwapBuffers(display, eglSurface)) {
                throw IllegalStateException("eglSwapBuffers failed: ${eglError()}")
            }
        } catch (e: Exception) {
            if (released) return
            Log.e(TAG, "GL relay frame failed", e)
            failed = true
            onError("Video relay failed: ${e.message}")
        }
    }

    /** GL thread. Safe on partially set-up state; leaves nothing current. */
    private fun tearDownGl() {
        surfaceTexture?.setOnFrameAvailableListener(null)
        camSurface?.release()
        camSurface = null
        surfaceTexture?.release()
        surfaceTexture = null
        if (display != EGL14.EGL_NO_DISPLAY) {
            if (context != EGL14.EGL_NO_CONTEXT && eglSurface != EGL14.EGL_NO_SURFACE &&
                EGL14.eglMakeCurrent(display, eglSurface, eglSurface, context)
            ) {
                if (program != 0) GLES20.glDeleteProgram(program)
                if (texId != 0) GLES20.glDeleteTextures(1, intArrayOf(texId), 0)
            }
            program = 0
            texId = 0
            EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
            if (eglSurface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, eglSurface)
            if (context != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(display, context)
            EGL14.eglReleaseThread()
            EGL14.eglTerminate(display)
        }
        eglSurface = EGL14.EGL_NO_SURFACE
        context = EGL14.EGL_NO_CONTEXT
        display = EGL14.EGL_NO_DISPLAY
    }

    private fun buildProgram(): Int {
        val vs = compileShader(GLES20.GL_VERTEX_SHADER, VERTEX_SHADER)
        val fs = compileShader(GLES20.GL_FRAGMENT_SHADER, FRAGMENT_SHADER)
        val p = GLES20.glCreateProgram()
        GLES20.glAttachShader(p, vs)
        GLES20.glAttachShader(p, fs)
        GLES20.glLinkProgram(p)
        GLES20.glDeleteShader(vs)
        GLES20.glDeleteShader(fs)
        val status = IntArray(1)
        GLES20.glGetProgramiv(p, GLES20.GL_LINK_STATUS, status, 0)
        if (status[0] != GLES20.GL_TRUE) {
            val log = GLES20.glGetProgramInfoLog(p)
            GLES20.glDeleteProgram(p)
            throw IllegalStateException("GL program link failed: $log")
        }
        return p
    }

    private fun compileShader(type: Int, source: String): Int {
        val s = GLES20.glCreateShader(type)
        GLES20.glShaderSource(s, source)
        GLES20.glCompileShader(s)
        val status = IntArray(1)
        GLES20.glGetShaderiv(s, GLES20.GL_COMPILE_STATUS, status, 0)
        if (status[0] != GLES20.GL_TRUE) {
            val log = GLES20.glGetShaderInfoLog(s)
            GLES20.glDeleteShader(s)
            throw IllegalStateException("GL shader compile failed: $log")
        }
        return s
    }

    private fun checkGl(op: String) {
        val err = GLES20.glGetError()
        if (err != GLES20.GL_NO_ERROR) throw IllegalStateException("$op: GL error 0x${Integer.toHexString(err)}")
    }

    private fun eglError(): String = "0x${Integer.toHexString(EGL14.eglGetError())}"

    private companion object {
        const val TAG = "CSPhone"
        const val EGL_RECORDABLE_ANDROID = 0x3142
        const val SETUP_TIMEOUT_S = 5L

        const val VERTEX_SHADER = """
            uniform mat4 uSTMatrix;
            attribute vec4 aPosition;
            attribute vec4 aTexCoord;
            varying vec2 vTexCoord;
            void main() {
                gl_Position = aPosition;
                vTexCoord = (uSTMatrix * aTexCoord).xy;
            }
        """

        const val FRAGMENT_SHADER = """#extension GL_OES_EGL_image_external : require
            precision mediump float;
            varying vec2 vTexCoord;
            uniform samplerExternalOES sTexture;
            void main() {
                gl_FragColor = texture2D(sTexture, vTexCoord);
            }
        """

        fun floatBuffer(vararg values: Float): FloatBuffer =
            ByteBuffer.allocateDirect(values.size * 4).order(ByteOrder.nativeOrder()).asFloatBuffer().apply {
                put(values)
                position(0)
            }
    }
}
