package dev.wadjakorn.capturestudio.phone

import java.io.IOException
import java.nio.ByteBuffer

/** Malformed stream (unknown type or oversize length). The connection must be dropped. */
class ProtocolException(message: String) : IOException(message)

/** Framing: `u8 type`, `u32 length` (big-endian), payload. Matches the Mac's `PhoneFraming`. */
object MessageCodec {
    const val MAX_PAYLOAD = 8 * 1024 * 1024
    const val HEADER_SIZE = 5

    fun encode(m: Message): ByteArray {
        require(m.payload.size <= MAX_PAYLOAD) { "payload exceeds $MAX_PAYLOAD bytes" }
        return ByteBuffer.allocate(HEADER_SIZE + m.payload.size)
            .put(m.type.code.toByte())
            .putInt(m.payload.size)
            .put(m.payload)
            .array()
    }

    /** Drains complete messages from [buffer], leaving any partial tail in it. */
    @Throws(ProtocolException::class)
    fun decode(buffer: FrameBuffer): List<Message> = buffer.drain()
}

/** Accumulates stream bytes and yields complete messages, keeping a partial tail (header included). */
class FrameBuffer(initialCapacity: Int = 64 * 1024) {
    private var bytes = ByteArray(initialCapacity)
    private var start = 0
    private var end = 0

    val size: Int get() = end - start

    /** Appends the first [len] bytes of [data]. */
    fun append(data: ByteArray, len: Int) {
        require(len in 0..data.size) { "len out of range" }
        ensureSpace(len)
        System.arraycopy(data, 0, bytes, end, len)
        end += len
    }

    @Throws(ProtocolException::class)
    fun drain(): List<Message> {
        val out = ArrayList<Message>()
        while (end - start >= MessageCodec.HEADER_SIZE) {
            val code = bytes[start].toInt() and 0xFF
            val type = MessageType.fromCode(code) ?: throw ProtocolException("unknown message type $code")
            val length = readU32(start + 1)
            if (length > MessageCodec.MAX_PAYLOAD) throw ProtocolException("oversize payload $length")
            val bodyStart = start + MessageCodec.HEADER_SIZE
            val bodyEnd = bodyStart + length.toInt()
            if (bodyEnd > end) break
            out += Message(type, bytes.copyOfRange(bodyStart, bodyEnd))
            start = bodyEnd
        }
        if (start == end) {
            start = 0
            end = 0
        }
        return out
    }

    /** Copy of the undrained bytes. */
    fun remaining(): ByteArray = bytes.copyOfRange(start, end)

    private fun readU32(at: Int): Long =
        ((bytes[at].toLong() and 0xFF) shl 24) or
            ((bytes[at + 1].toLong() and 0xFF) shl 16) or
            ((bytes[at + 2].toLong() and 0xFF) shl 8) or
            (bytes[at + 3].toLong() and 0xFF)

    private fun ensureSpace(len: Int) {
        if (bytes.size - end >= len) return
        val live = end - start
        val needed = live + len
        val target = if (needed <= bytes.size) bytes else ByteArray(maxOf(needed, bytes.size * 2))
        System.arraycopy(bytes, start, target, 0, live)
        bytes = target
        start = 0
        end = live
    }
}
