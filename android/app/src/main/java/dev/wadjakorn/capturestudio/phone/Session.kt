package dev.wadjakorn.capturestudio.phone

import android.os.SystemClock
import android.util.Log
import java.io.IOException
import java.io.OutputStream
import java.net.SocketTimeoutException
import java.security.SecureRandom
import java.util.ArrayDeque
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.locks.ReentrantLock
import javax.net.ssl.SSLSocket
import kotlin.concurrent.withLock

/** What the UI shows about the (single) occupying Mac. */
sealed class SessionState {
    data object Idle : SessionState()
    data class Connected(val macName: String) : SessionState()
    data class Streaming(val macName: String) : SessionState()
}

/** A pairing waiting for the user's Allow / Deny on the phone. */
data class PairingRequest(val macName: String, val code: String, val sessionId: Long)

/** Encoded media handed from the pipelines to a session. Implementations never block. */
interface MediaSink {
    fun videoConfig(parameterSets: List<ByteArray>)
    fun videoFrame(frame: VideoFrame)
    fun audioConfig(asc: ByteArray)
    fun audioFrame(frame: AudioFrame)
}

/** Everything a [Session] needs from its host; keeps camera/audio code out of the session. */
interface SessionContext {
    val pairingStore: PairingStore
    fun fingerprint(): ByteArray
    fun deviceName(): String

    /** Makes [session] the single occupant; false if another session already occupies the phone. */
    fun claimOccupancy(session: Session): Boolean
    fun releaseOccupancy(session: Session)
    /** Updates the UI state, only if [session] is the occupant. */
    fun publishState(session: Session, state: SessionState)

    /** Publishes [request] to the UI; false if another pairing is already awaiting a decision. */
    fun beginPairing(session: Session, request: PairingRequest): Boolean
    fun endPairing(session: Session)

    fun startStreaming(session: Session, config: StartConfig, sink: MediaSink)
    fun requestKeyframe()
    fun stopStreaming(session: Session)
    fun sessionClosed(session: Session)
}

/**
 * One connected Mac. A reader thread parses framed messages and drives the state
 * machine; a writer thread drains a bounded send queue, so neither codec callbacks
 * nor the UI thread ever touch the socket.
 *
 * Security rules: an unauthenticated socket is closed after 10 s; a socket whose
 * PAIR_REVEAL verified gets a 120 s pairing deadline instead (the user must tap
 * Allow), after which it is denied. Only an authenticated session occupies the phone.
 */
class Session(private val socket: SSLSocket, private val ctx: SessionContext) : MediaSink {
    val id: Long = nextId.incrementAndGet()

    private enum class Phase { AwaitingHello, Authenticating, AwaitingDecision, Authenticated, Streaming, Closed }

    private val lock = Any()
    @Volatile private var phase = Phase.AwaitingHello
    private var macName = "Mac"
    private var commitment: ByteArray? = null
    private var phoneNonce: ByteArray? = null
    private var deadline: ScheduledFuture<*>? = null
    @Volatile private var videoConfigSent = false
    @Volatile private var maxQueuedVideo = 60
    private val socketClosed = AtomicBoolean(false)

    // Send queue (guarded by queueLock).
    private val queueLock = ReentrantLock()
    private val queueReady = queueLock.newCondition()
    private val queue = ArrayDeque<Outgoing>()
    private var queuedVideo = 0
    private var queuedAudio = 0
    private var draining = false // Close sentinel queued: accept nothing more
    @Volatile private var lastSyncRequestMs = 0L
    @Volatile private var lastWriteMs = 0L

    private sealed class Outgoing {
        class Control(val message: Message) : Outgoing()
        class Pong(val macSendHostNs: Long, val phoneRecvNs: Long) : Outgoing()
        class Video(val message: Message, val keyframe: Boolean) : Outgoing()
        class Audio(val message: Message) : Outgoing()
        data object Close : Outgoing()
    }

    fun start() {
        synchronized(lock) {
            deadline = scheduler.schedule({ shutdown(graceful = false, "unauthenticated timeout") },
                UNAUTH_TIMEOUT_S, TimeUnit.SECONDS)
        }
        Thread(::readLoop, "CSPhone-session-$id-rx").apply { isDaemon = true; start() }
        Thread(::writeLoop, "CSPhone-session-$id-tx").apply { isDaemon = true; start() }
    }

    /** Closes the connection immediately (service shutdown). */
    fun close() = shutdown(graceful = false, "closed by phone")

    // region Reader

    private fun readLoop() {
        var reason = "connection closed"
        try {
            // Backstop for the scheduled deadline while unauthenticated (also bounds the
            // TLS handshake, which runs on the first read). Cleared once authenticated
            // or awaiting the user's pairing decision.
            socket.soTimeout = (UNAUTH_TIMEOUT_S * 1000).toInt()
            val input = socket.inputStream
            val buf = ByteArray(64 * 1024)
            val frames = FrameBuffer()
            while (phase != Phase.Closed) {
                val n = input.read(buf)
                val recvNs = SystemClock.elapsedRealtimeNanos()
                if (n < 0) break
                frames.append(buf, n)
                for (m in frames.drain()) {
                    handle(m, recvNs)
                    if (phase == Phase.Closed) return
                }
            }
        } catch (e: SocketTimeoutException) {
            reason = "read timeout while unauthenticated"
        } catch (e: ProtocolException) {
            reason = "protocol error: ${e.message}"
        } catch (e: IOException) {
            reason = "I/O: ${e.message}"
        } catch (e: RuntimeException) {
            Log.e(TAG, "session $id: unexpected error", e)
            reason = "internal error"
        } finally {
            // A graceful close already in progress lets the writer flush and close.
            if (phase != Phase.Closed) shutdown(graceful = false, reason)
        }
    }

    private fun handle(m: Message, recvNs: Long) {
        when (m.type) {
            MessageType.HELLO -> onHello(m.payload)
            MessageType.AUTH -> onAuth(m.payload)
            MessageType.PAIR_COMMIT -> onPairCommit(m.payload)
            MessageType.PAIR_REVEAL -> onPairReveal(m.payload)
            MessageType.CLOCK_PING -> onClockPing(m.payload, recvNs)
            MessageType.START -> onStart(m.payload)
            MessageType.KEYFRAME_REQ -> if (phase == Phase.Streaming) ctx.requestKeyframe()
            MessageType.STOP -> shutdown(graceful = true, "STOP from Mac")
            MessageType.ERROR -> {
                val e = ErrorPayload.decode(m.payload)
                shutdown(graceful = false, "Mac reported error ${e?.code}: ${e?.message}")
            }
            else -> violation("unexpected ${m.type}")
        }
    }

    private fun onHello(payload: ByteArray): Unit = synchronized(lock) {
        if (phase != Phase.AwaitingHello) return violation("HELLO in $phase")
        val hello = Hello.decode(payload) ?: return violation("malformed HELLO")
        if (hello.pv != PROTOCOL_VERSION) {
            sendError(ErrorPayload.VERSION, "Protocol version ${hello.pv} is not supported (phone speaks $PROTOCOL_VERSION).")
            return
        }
        macName = hello.deviceName.take(MAX_NAME).ifBlank { "Mac" }
        val name = ctx.deviceName()
        send(Message(MessageType.HELLO, Hello(PROTOCOL_VERSION, name, name, listOf("video", "audio")).encode()))
        phase = Phase.Authenticating
    }

    private fun onAuth(payload: ByteArray): Unit = synchronized(lock) {
        if (phase != Phase.Authenticating || commitment != null) return violation("AUTH in $phase")
        val match = if (payload.size == TOKEN_LEN) ctx.pairingStore.matches(payload) else null
        if (match == null) {
            Log.w(TAG, "session $id: AUTH failed for '$macName'")
            send(Message(MessageType.AUTH_FAIL, ByteArray(0)))
            shutdown(graceful = true, "auth failed")
            return
        }
        if (becomeAuthenticated()) {
            socket.soTimeout = 0
            send(Message(MessageType.AUTH_OK, ByteArray(0)))
            Log.i(TAG, "session $id: authenticated '$macName'")
        }
    }

    private fun onPairCommit(payload: ByteArray): Unit = synchronized(lock) {
        if (phase != Phase.Authenticating || commitment != null) return violation("PAIR_COMMIT in $phase")
        if (payload.size != NONCE_LEN) return violation("malformed PAIR_COMMIT")
        commitment = payload
        val nonce = randomBytes(NONCE_LEN)
        phoneNonce = nonce
        send(Message(MessageType.PAIR_NONCE, nonce))
    }

    private fun onPairReveal(payload: ByteArray): Unit = synchronized(lock) {
        val commit = commitment
        val nonce = phoneNonce
        if (phase != Phase.Authenticating || commit == null || nonce == null) return violation("PAIR_REVEAL in $phase")
        if (payload.size != NONCE_LEN || !PairingCode.verifyCommitment(commit, payload)) {
            Log.w(TAG, "session $id: pairing commitment mismatch")
            send(Message(MessageType.PAIR_DENIED, ByteArray(0)))
            shutdown(graceful = true, "commitment mismatch")
            return
        }
        val code = PairingCode.deriveCode(ctx.fingerprint(), payload, nonce)
        if (!ctx.beginPairing(this, PairingRequest(macName, code, id))) {
            Log.w(TAG, "session $id: another pairing is awaiting a decision")
            send(Message(MessageType.PAIR_DENIED, ByteArray(0)))
            shutdown(graceful = true, "pairing already in progress")
            return
        }
        // Pairing exemption: replace the 10 s unauthenticated deadline with the
        // 120 s decision deadline; the Mac legitimately sends nothing meanwhile.
        deadline?.cancel(false)
        deadline = scheduler.schedule({ resolvePairing(false) }, PAIRING_TIMEOUT_S, TimeUnit.SECONDS)
        phase = Phase.AwaitingDecision
        socket.soTimeout = 0
    }

    /** The user's Allow / Deny (any thread; never touches the socket directly). */
    fun resolvePairing(allowed: Boolean): Unit = synchronized(lock) {
        if (phase != Phase.AwaitingDecision) return
        deadline?.cancel(false)
        deadline = null
        ctx.endPairing(this)
        if (!allowed) {
            Log.i(TAG, "session $id: pairing denied or timed out")
            send(Message(MessageType.PAIR_DENIED, ByteArray(0)))
            shutdown(graceful = true, "pairing denied")
            return
        }
        if (!becomeAuthenticated()) return
        val token = randomBytes(TOKEN_LEN)
        ctx.pairingStore.add(macName, PairingStore.hex(PairingStore.sha256(token)))
        send(Message(MessageType.PAIR_OK, token))
        Log.i(TAG, "session $id: paired with '$macName'")
    }

    /** Caller holds [lock]. On busy, sends ERROR busy and closes; returns false. */
    private fun becomeAuthenticated(): Boolean {
        if (!ctx.claimOccupancy(this)) {
            sendError(ErrorPayload.BUSY, "Phone is in use by another computer")
            return false
        }
        // Authenticated but idle (the Mac sends START right after clock sync): release
        // the occupancy if START never comes, so a vanished Mac cannot hold the phone.
        deadline?.cancel(false)
        deadline = scheduler.schedule({ shutdown(graceful = false, "no START") }, AUTH_IDLE_S, TimeUnit.SECONDS)
        phase = Phase.Authenticated
        ctx.publishState(this, SessionState.Connected(macName))
        return true
    }

    private fun onClockPing(payload: ByteArray, recvNs: Long) {
        if (phase != Phase.Authenticated && phase != Phase.Streaming) return violation("CLOCK_PING in $phase")
        val ping = ClockPing.decode(payload) ?: return violation("malformed CLOCK_PING")
        enqueue(Outgoing.Pong(ping.macSendHostNs, recvNs))
    }

    private fun onStart(payload: ByteArray): Unit = synchronized(lock) {
        when (phase) {
            Phase.Authenticated -> Unit
            Phase.Streaming -> { Log.w(TAG, "session $id: START while streaming; ignored"); return }
            else -> return violation("START in $phase")
        }
        val config = StartConfig.decode(payload)
        if (config == null) {
            sendError(ErrorPayload.INTERNAL, "Malformed START")
            return
        }
        deadline?.cancel(false)
        deadline = null
        lastWriteMs = SystemClock.elapsedRealtime()
        videoConfigSent = false
        maxQueuedVideo = (config.fps.coerceIn(1, 120) * QUEUE_SECONDS)
        phase = Phase.Streaming
        Log.i(TAG, "session $id: START $config")
        ctx.startStreaming(this, config, this)
        ctx.publishState(this, SessionState.Streaming(macName))
    }

    private fun violation(what: String) {
        Log.w(TAG, "session $id: protocol violation: $what")
        shutdown(graceful = false, what)
    }

    /** ERROR then close (graceful, so the ERROR is flushed first). */
    private fun sendError(code: String, message: String) {
        send(Message(MessageType.ERROR, ErrorPayload(code, message).encode()))
        shutdown(graceful = true, "error $code")
    }

    // endregion

    // region MediaSink (codec threads; never block)

    override fun videoConfig(parameterSets: List<ByteArray>) {
        if (phase != Phase.Streaming) return
        if (videoConfigSent) {
            Log.w(TAG, "session $id: duplicate VIDEO_CONFIG dropped (one per START)")
            return
        }
        videoConfigSent = true
        enqueue(Outgoing.Control(Message(MessageType.VIDEO_CONFIG, VideoConfig(parameterSets).encode())))
    }

    override fun videoFrame(frame: VideoFrame) {
        if (phase != Phase.Streaming || !videoConfigSent) return
        enqueue(Outgoing.Video(Message(MessageType.VIDEO_FRAME, frame.encode()), frame.keyframe))
    }

    override fun audioConfig(asc: ByteArray) {
        if (phase != Phase.Streaming) return
        enqueue(Outgoing.Control(Message(MessageType.AUDIO_CONFIG, asc)))
    }

    override fun audioFrame(frame: AudioFrame) {
        if (phase != Phase.Streaming) return
        enqueue(Outgoing.Audio(Message(MessageType.AUDIO_FRAME, frame.encode())))
    }

    // endregion

    // region Send queue / writer

    private fun send(message: Message) = enqueue(Outgoing.Control(message))

    private fun enqueue(item: Outgoing) {
        var needSync = false
        queueLock.withLock {
            if (draining) return
            when (item) {
                is Outgoing.Pong -> queue.addFirst(item) // timing-sensitive; independent of media order
                else -> queue.addLast(item)
            }
            when (item) {
                is Outgoing.Video -> {
                    queuedVideo++
                    if (queuedVideo > maxQueuedVideo && dropOldest { it is Outgoing.Video && !it.keyframe }) {
                        queuedVideo--
                        needSync = true
                    }
                }
                is Outgoing.Audio -> {
                    queuedAudio++
                    if (queuedAudio > MAX_QUEUED_AUDIO && dropOldest { it is Outgoing.Audio }) queuedAudio--
                }
                else -> Unit
            }
            queueReady.signal()
        }
        if (needSync) {
            val now = SystemClock.elapsedRealtime()
            if (now - lastWriteMs > STALL_MS) {
                // Nothing written for a long time while frames pile up: the Mac is gone
                // (no FIN). Free the phone instead of waiting for TCP keepalive.
                shutdown(graceful = false, "peer stalled")
                return
            }
            if (now - lastSyncRequestMs > SYNC_REQUEST_INTERVAL_MS) {
                lastSyncRequestMs = now
                Log.w(TAG, "session $id: send queue over budget; dropping video and requesting a sync frame")
                ctx.requestKeyframe()
            }
        }
    }

    /** Caller holds queueLock. */
    private inline fun dropOldest(predicate: (Outgoing) -> Boolean): Boolean {
        val it = queue.iterator()
        while (it.hasNext()) {
            if (predicate(it.next())) {
                it.remove()
                return true
            }
        }
        return false
    }

    private fun writeLoop() {
        var out: OutputStream? = null
        try {
            while (true) {
                val item = queueLock.withLock {
                    while (queue.isEmpty()) queueReady.await()
                    val next = queue.pollFirst()!!
                    when (next) {
                        is Outgoing.Video -> queuedVideo--
                        is Outgoing.Audio -> queuedAudio--
                        else -> Unit
                    }
                    next
                }
                val message = when (item) {
                    is Outgoing.Close -> break
                    is Outgoing.Control -> item.message
                    is Outgoing.Video -> item.message
                    is Outgoing.Audio -> item.message
                    is Outgoing.Pong -> {
                        // phoneSendNs is captured as late as possible, right before the write.
                        val pong = ClockPong(item.macSendHostNs, item.phoneRecvNs, SystemClock.elapsedRealtimeNanos())
                        Message(MessageType.CLOCK_PONG, pong.encode())
                    }
                }
                val stream = out ?: socket.outputStream.also { out = it }
                stream.write(MessageCodec.encode(message))
                stream.flush()
                lastWriteMs = SystemClock.elapsedRealtime()
            }
        } catch (e: IOException) {
            if (phase != Phase.Closed) Log.w(TAG, "session $id: write failed: ${e.message}")
            shutdown(graceful = false, "write failed")
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
        } finally {
            closeSocket()
        }
    }

    // endregion

    // region Teardown

    /**
     * Idempotent. Releases the session's claims (pairing prompt, streaming,
     * occupancy) immediately. Graceful: queued control messages (e.g. ERROR,
     * PAIR_DENIED) are flushed before the socket closes, bounded by a grace timer.
     */
    private fun shutdown(graceful: Boolean, reason: String) {
        val previous: Phase
        synchronized(lock) {
            previous = phase
            phase = Phase.Closed
            deadline?.cancel(false)
            deadline = null
        }
        if (previous != Phase.Closed) {
            Log.i(TAG, "session $id: closing ($reason)")
            if (previous == Phase.AwaitingDecision) ctx.endPairing(this)
            if (previous == Phase.Streaming) ctx.stopStreaming(this)
            ctx.releaseOccupancy(this)
            ctx.sessionClosed(this)
        }
        queueLock.withLock {
            if (!draining) {
                draining = true
                // Media still queued is useless once closing; keep control messages.
                queue.removeAll { it is Outgoing.Video || it is Outgoing.Audio }
                queuedVideo = 0
                queuedAudio = 0
                if (graceful) queue.addLast(Outgoing.Close) else {
                    queue.clear()
                    queue.addLast(Outgoing.Close)
                }
                queueReady.signal()
            }
        }
        // Never close on the caller's thread: it may be the UI or a codec callback,
        // and an SSL close can block (close_notify) on a stalled peer.
        if (graceful) {
            scheduler.schedule({ closeSocketAsync() }, GRACE_S, TimeUnit.SECONDS)
        } else {
            closeSocketAsync()
        }
    }

    private fun closeSocketAsync() = closer.execute(::closeSocket)

    private fun closeSocket() {
        if (!socketClosed.compareAndSet(false, true)) return
        try {
            socket.close()
        } catch (e: IOException) {
            Log.w(TAG, "session $id: close: ${e.message}")
        }
    }

    // endregion

    companion object {
        const val PROTOCOL_VERSION = 1
        private const val TAG = "CSPhone"
        private const val UNAUTH_TIMEOUT_S = 10L
        private const val PAIRING_TIMEOUT_S = 120L
        private const val GRACE_S = 3L
        private const val AUTH_IDLE_S = 60L
        private const val STALL_MS = 10_000L
        private const val NONCE_LEN = 32
        private const val TOKEN_LEN = 32
        private const val MAX_NAME = 128
        private const val QUEUE_SECONDS = 2
        private const val MAX_QUEUED_AUDIO = 48_000 / 1024 * QUEUE_SECONDS
        private const val SYNC_REQUEST_INTERVAL_MS = 500L

        private val nextId = AtomicLong(0)
        private val random = SecureRandom()

        private val scheduler = ScheduledThreadPoolExecutor(1) { r ->
            Thread(r, "CSPhone-session-timer").apply { isDaemon = true }
        }.apply { removeOnCancelPolicy = true }

        private val closer = Executors.newCachedThreadPool { r ->
            Thread(r, "CSPhone-session-close").apply { isDaemon = true }
        }

        private fun randomBytes(n: Int): ByteArray = ByteArray(n).also { random.nextBytes(it) }
    }
}
