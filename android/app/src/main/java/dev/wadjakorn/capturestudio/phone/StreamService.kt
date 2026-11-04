package dev.wadjakorn.capturestudio.phone

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import androidx.camera.core.CameraSelector
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicReference

/** Phone-side capture preferences; when set they override the Mac's START values. */
data class StreamSettings(val facing: String? = null, val width: Int? = null, val height: Int? = null)

/**
 * Foreground service (type camera|microphone) hosting the TLS server, the NSD
 * advertisement and the capture pipelines. Must be started from the visible
 * activity after CAMERA + RECORD_AUDIO (+ POST_NOTIFICATIONS on 33+) are granted.
 * It is its own [LifecycleOwner] so CameraX keeps running with the screen off.
 */
class StreamService : Service(), LifecycleOwner {
    private val registry = LifecycleRegistry(this)
    override val lifecycle: Lifecycle get() = registry

    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor { r -> Thread(r, "CSPhone-server").apply { isDaemon = true } }
    private val sessions = ConcurrentHashMap.newKeySet<Session>()
    private val occupant = AtomicReference<Session?>(null)

    private var started = false
    @Volatile private var server: TlsServer? = null
    private var advertiser: Advertiser? = null
    @Volatile private var video: VideoPipeline? = null
    private var audio: AudioPipeline? = null
    private var streamingSession: Session? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    @Volatile private var fingerprint: ByteArray? = null

    override fun onCreate() {
        super.onCreate()
        registry.currentState = Lifecycle.State.CREATED
        createChannel()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (started) return START_NOT_STICKY
        try {
            startForeground(
                NOTIFICATION_ID, notification(null),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
            )
        } catch (e: RuntimeException) {
            // SecurityException / ForegroundServiceStartNotAllowedException: permissions
            // missing or not started from the foreground.
            Log.e(TAG, "startForeground failed", e)
            stopSelf()
            return START_NOT_STICKY
        }
        started = true
        instance = this
        io.execute(::startServer)
        return START_NOT_STICKY
    }

    private fun startServer() {
        try {
            Identity.ensureKey()
            fingerprint = Identity.fingerprint()
            val s = TlsServer(Identity.sslContext())
            server = s
            s.start { socket ->
                val session = Session(socket, sessionContext)
                sessions += session
                session.start()
            }
            main.post {
                if (server !== s) return@post
                advertiser = Advertiser(this).also { it.register(s.port) }
            }
            Log.i(TAG, "TLS server listening on port ${s.port}")
        } catch (e: Exception) {
            Log.e(TAG, "Could not start the server", e)
            main.post { stopSelf() }
        }
    }

    override fun onDestroy() {
        instance = null
        advertiser?.unregister()
        advertiser = null
        server?.close()
        server = null
        sessions.forEach { it.close() }
        sessions.clear()
        stopPipelines()
        _pairingRequest.value = null
        pairingSession.set(null)
        _sessionState.value = SessionState.Idle
        registry.currentState = Lifecycle.State.DESTROYED
        io.shutdown()
        super.onDestroy()
    }

    // region SessionContext

    private val sessionContext = object : SessionContext {
        override val pairingStore: PairingStore get() = PairingStore.get(this@StreamService)

        override fun fingerprint(): ByteArray = fingerprint ?: Identity.fingerprint()

        override fun deviceName(): String = Build.MODEL

        override fun claimOccupancy(session: Session): Boolean = occupant.compareAndSet(null, session)

        override fun releaseOccupancy(session: Session) {
            if (occupant.compareAndSet(session, null)) {
                _sessionState.value = SessionState.Idle
                main.post { updateNotification(null) }
            }
        }

        override fun publishState(session: Session, state: SessionState) {
            if (occupant.get() !== session) return
            _sessionState.value = state
            val mac = (state as? SessionState.Streaming)?.macName
            main.post { updateNotification(mac) }
        }

        override fun beginPairing(session: Session, request: PairingRequest): Boolean {
            if (!pairingSession.compareAndSet(null, session)) return false
            _pairingRequest.value = request
            return true
        }

        override fun endPairing(session: Session) {
            if (pairingSession.compareAndSet(session, null)) _pairingRequest.value = null
        }

        override fun startStreaming(session: Session, config: StartConfig, sink: MediaSink) {
            main.post { beginStreaming(session, config, sink) }
        }

        override fun requestKeyframe() {
            video?.requestKeyframe()
        }

        override fun stopStreaming(session: Session) {
            main.post { if (streamingSession === session) stopPipelines() }
        }

        override fun sessionClosed(session: Session) {
            sessions -= session
        }
    }

    // endregion

    // region Streaming (main thread)

    private fun beginStreaming(session: Session, requested: StartConfig, sink: MediaSink) {
        if (occupant.get() !== session) return // closed before this ran
        stopPipelines()
        val prefs = settings.value
        val config = requested.copy(
            facing = prefs.facing ?: requested.facing,
            width = prefs.width ?: requested.width,
            height = prefs.height ?: requested.height,
        )
        Log.i(TAG, "Streaming with $config")
        streamingSession = session
        acquireLocks()
        registry.currentState = Lifecycle.State.STARTED
        if (config.video) {
            val lens = if (config.facing == "front") CameraSelector.LENS_FACING_FRONT else CameraSelector.LENS_FACING_BACK
            video = VideoPipeline(
                this, this, lens, config.width, config.height,
                config.fps.coerceIn(1, 60), config.bitrate.coerceIn(500_000, 50_000_000), sink,
            ).also { it.start() }
        }
        if (config.audio) {
            audio = AudioPipeline(this, sink).also { it.start() }
        }
    }

    private fun stopPipelines() {
        video?.stop()
        video = null
        audio?.stop()
        audio = null
        streamingSession = null
        releaseLocks()
        if (registry.currentState.isAtLeast(Lifecycle.State.STARTED)) {
            registry.currentState = Lifecycle.State.CREATED
        }
    }

    private fun acquireLocks() {
        if (wakeLock == null) {
            val pm = getSystemService(PowerManager::class.java)
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "CaptureStudioPhone:stream").apply {
                setReferenceCounted(false)
                acquire(WAKE_LOCK_MAX_MS)
            }
        }
        if (wifiLock == null) {
            val wm = applicationContext.getSystemService(WifiManager::class.java)
            wifiLock = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "CaptureStudioPhone:stream").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
    }

    private fun releaseLocks() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        wifiLock?.let { if (it.isHeld) it.release() }
        wifiLock = null
    }

    // endregion

    // region Notification

    private fun createChannel() {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Capture Studio Phone", NotificationManager.IMPORTANCE_LOW),
        )
    }

    private fun notification(streamingTo: String?): Notification {
        val stop = PendingIntent.getService(
            this, 0,
            Intent(this, StreamService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("Capture Studio Phone")
            .setContentText(if (streamingTo != null) "Streaming to $streamingTo" else "Advertising on Wi-Fi")
            .setSmallIcon(android.R.drawable.presence_video_online)
            .setOngoing(true)
            .addAction(Notification.Action.Builder(null, "Stop", stop).build())
            .build()
    }

    private fun updateNotification(streamingTo: String?) {
        if (!started) return
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification(streamingTo))
    }

    // endregion

    companion object {
        const val ACTION_STOP = "dev.wadjakorn.capturestudio.phone.STOP"
        private const val TAG = "CSPhone"
        private const val CHANNEL_ID = "capture-studio-phone"
        private const val NOTIFICATION_ID = 1
        private const val WAKE_LOCK_MAX_MS = 6L * 60 * 60 * 1000

        @Volatile private var instance: StreamService? = null
        private val pairingSession = AtomicReference<Session?>(null)

        private val _sessionState = MutableStateFlow<SessionState>(SessionState.Idle)
        val sessionState: StateFlow<SessionState> = _sessionState.asStateFlow()

        private val _pairingRequest = MutableStateFlow<PairingRequest?>(null)
        val pairingRequest: StateFlow<PairingRequest?> = _pairingRequest.asStateFlow()

        /** UI preferences, read at each START. */
        val settings = MutableStateFlow(StreamSettings())

        val isRunning: Boolean get() = instance != null

        fun allowPairing() {
            pairingSession.get()?.resolvePairing(true)
        }

        fun denyPairing() {
            pairingSession.get()?.resolvePairing(false)
        }

        fun start(context: Context) {
            context.startForegroundService(Intent(context, StreamService::class.java))
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, StreamService::class.java))
        }
    }
}
