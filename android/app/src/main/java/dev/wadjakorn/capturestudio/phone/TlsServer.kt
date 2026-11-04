package dev.wadjakorn.capturestudio.phone

import android.util.Log
import java.io.IOException
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.SSLSocket

/**
 * TLS 1.2/1.3 listener on an ephemeral port. Server-authenticated only: the Mac is
 * authenticated inside the protocol (token or pairing), not by a client certificate.
 */
class TlsServer(sslContext: SSLContext) {
    private val server = sslContext.serverSocketFactory.createServerSocket(0) as SSLServerSocket
    @Volatile private var closed = false
    private var thread: Thread? = null

    init {
        server.enabledProtocols = server.supportedProtocols
            .filter { it == "TLSv1.2" || it == "TLSv1.3" }
            .toTypedArray()
        server.needClientAuth = false
        server.wantClientAuth = false
    }

    val port: Int get() = server.localPort

    /** Starts the accept loop; each accepted socket is handed to [onSocket] on the accept thread. */
    fun start(onSocket: (SSLSocket) -> Unit) {
        check(thread == null) { "already started" }
        thread = Thread({
            while (!closed) {
                val socket = try {
                    server.accept() as SSLSocket
                } catch (e: IOException) {
                    if (!closed) Log.w(TAG, "accept failed", e)
                    if (server.isClosed) break
                    continue
                }
                try {
                    socket.keepAlive = true
                    socket.tcpNoDelay = true
                    onSocket(socket)
                } catch (e: Exception) {
                    Log.w(TAG, "could not hand off socket", e)
                    runCatching { socket.close() }
                }
            }
        }, "CSPhone-accept").apply {
            isDaemon = true
            start()
        }
    }

    fun close() {
        closed = true
        runCatching { server.close() }
    }

    private companion object {
        const val TAG = "CSPhone"
    }
}
