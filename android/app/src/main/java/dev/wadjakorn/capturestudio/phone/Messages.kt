package dev.wadjakorn.capturestudio.phone

import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.nio.ByteBuffer

/** Wire message types shared with the Mac (`PhoneMessageType`). Codes are frozen. */
enum class MessageType(val code: Int) {
    HELLO(1),
    AUTH(2),
    AUTH_OK(3),
    AUTH_FAIL(4),
    PAIR_COMMIT(5),
    PAIR_NONCE(6),
    PAIR_REVEAL(7),
    PAIR_OK(8),
    PAIR_DENIED(9),
    CLOCK_PING(10),
    CLOCK_PONG(11),
    START(12),
    VIDEO_CONFIG(13),
    VIDEO_FRAME(14),
    AUDIO_CONFIG(15),
    AUDIO_FRAME(16),
    KEYFRAME_REQ(17),
    STOP(18),
    ERROR(19);

    companion object {
        private val byCode = entries.associateBy { it.code }
        fun fromCode(code: Int): MessageType? = byCode[code]
    }
}

class Message(val type: MessageType, val payload: ByteArray) {
    override fun equals(other: Any?): Boolean =
        other is Message && type == other.type && payload.contentEquals(other.payload)

    override fun hashCode(): Int = 31 * type.hashCode() + payload.contentHashCode()

    override fun toString(): String = "Message(type=$type, payload=${payload.size} bytes)"
}

/** VIDEO_CONFIG: `u8 count`, then count x (`u16 len`, NAL bytes incl. header byte, no start code). */
class VideoConfig(val parameterSets: List<ByteArray>) {
    fun encode(): ByteArray {
        require(parameterSets.size <= 0xFF) { "too many parameter sets" }
        val buf = ByteBuffer.allocate(1 + parameterSets.sumOf { 2 + it.size })
        buf.put(parameterSets.size.toByte())
        for (s in parameterSets) {
            require(s.size <= 0xFFFF) { "parameter set too large" }
            buf.putShort(s.size.toShort())
            buf.put(s)
        }
        return buf.array()
    }

    override fun equals(other: Any?): Boolean =
        other is VideoConfig && parameterSets.size == other.parameterSets.size &&
            parameterSets.indices.all { parameterSets[it].contentEquals(other.parameterSets[it]) }

    override fun hashCode(): Int = parameterSets.fold(1) { h, s -> 31 * h + s.contentHashCode() }

    companion object {
        /** Returns null if truncated; trailing bytes are ignored. */
        fun decode(data: ByteArray): VideoConfig? {
            if (data.isEmpty()) return null
            val buf = ByteBuffer.wrap(data)
            val count = buf.get().toInt() and 0xFF
            val sets = ArrayList<ByteArray>(count)
            repeat(count) {
                if (buf.remaining() < 2) return null
                val len = buf.getShort().toInt() and 0xFFFF
                if (buf.remaining() < len) return null
                sets += ByteArray(len).also { buf.get(it) }
            }
            return VideoConfig(sets)
        }
    }
}

/**
 * VIDEO_FRAME: `u64 ptsNs`, `u8 flags` (bit0 keyframe, bit1 mirrored), `u16 rotationDeg`,
 * then AVCC NAL units (4-byte BE length prefixes). [ptsNs] carries u64 bits.
 */
class VideoFrame(
    val ptsNs: Long,
    val keyframe: Boolean,
    val mirrored: Boolean,
    val rotationDeg: Int,
    val nalus: ByteArray,
) {
    fun encode(): ByteArray {
        val buf = ByteBuffer.allocate(HEADER + nalus.size)
        buf.putLong(ptsNs)
        buf.put(((if (keyframe) 0x01 else 0) or (if (mirrored) 0x02 else 0)).toByte())
        buf.putShort(rotationDeg.toShort())
        buf.put(nalus)
        return buf.array()
    }

    override fun equals(other: Any?): Boolean =
        other is VideoFrame && ptsNs == other.ptsNs && keyframe == other.keyframe &&
            mirrored == other.mirrored && rotationDeg == other.rotationDeg && nalus.contentEquals(other.nalus)

    override fun hashCode(): Int =
        listOf(ptsNs.hashCode(), keyframe.hashCode(), mirrored.hashCode(), rotationDeg, nalus.contentHashCode())
            .fold(1) { h, v -> 31 * h + v }

    override fun toString(): String =
        "VideoFrame(ptsNs=$ptsNs, keyframe=$keyframe, mirrored=$mirrored, rotationDeg=$rotationDeg, nalus=${nalus.size} bytes)"

    companion object {
        const val HEADER = 11

        fun decode(data: ByteArray): VideoFrame? {
            if (data.size < HEADER) return null
            val buf = ByteBuffer.wrap(data)
            val pts = buf.getLong()
            val flags = buf.get().toInt()
            val rotation = buf.getShort().toInt() and 0xFFFF
            return VideoFrame(pts, flags and 0x01 != 0, flags and 0x02 != 0, rotation, data.copyOfRange(HEADER, data.size))
        }
    }
}

/** AUDIO_FRAME: `u64 ptsNs`, then the AAC access unit. */
class AudioFrame(val ptsNs: Long, val accessUnit: ByteArray) {
    fun encode(): ByteArray =
        ByteBuffer.allocate(8 + accessUnit.size).putLong(ptsNs).put(accessUnit).array()

    override fun equals(other: Any?): Boolean =
        other is AudioFrame && ptsNs == other.ptsNs && accessUnit.contentEquals(other.accessUnit)

    override fun hashCode(): Int = 31 * ptsNs.hashCode() + accessUnit.contentHashCode()

    override fun toString(): String = "AudioFrame(ptsNs=$ptsNs, accessUnit=${accessUnit.size} bytes)"

    companion object {
        fun decode(data: ByteArray): AudioFrame? {
            if (data.size < 8) return null
            return AudioFrame(ByteBuffer.wrap(data).getLong(), data.copyOfRange(8, data.size))
        }
    }
}

/** CLOCK_PING: `u64 macSendHostNs`. */
data class ClockPing(val macSendHostNs: Long) {
    fun encode(): ByteArray = ByteBuffer.allocate(8).putLong(macSendHostNs).array()

    companion object {
        fun decode(data: ByteArray): ClockPing? =
            if (data.size < 8) null else ClockPing(ByteBuffer.wrap(data).getLong())
    }
}

/** CLOCK_PONG: `u64 macSendHostNs, u64 phoneRecvNs, u64 phoneSendNs` — exactly 24 bytes. */
data class ClockPong(val macSendHostNs: Long, val phoneRecvNs: Long, val phoneSendNs: Long) {
    fun encode(): ByteArray =
        ByteBuffer.allocate(SIZE).putLong(macSendHostNs).putLong(phoneRecvNs).putLong(phoneSendNs).array()

    companion object {
        const val SIZE = 24

        fun decode(data: ByteArray): ClockPong? {
            if (data.size != SIZE) return null
            val buf = ByteBuffer.wrap(data)
            return ClockPong(buf.getLong(), buf.getLong(), buf.getLong())
        }
    }
}

/** HELLO (JSON): `{"pv":1,"deviceName":"…","model":"…","caps":["video","audio"]}`. */
data class Hello(val pv: Int, val deviceName: String, val model: String, val caps: List<String>) {
    fun encode(): ByteArray = JSONObject()
        .put("pv", pv)
        .put("deviceName", deviceName)
        .put("model", model)
        .put("caps", JSONArray(caps))
        .toUtf8()

    companion object {
        fun decode(data: ByteArray): Hello? = parseJson(data) { o ->
            val arr = o.getJSONArray("caps")
            Hello(o.getInt("pv"), o.getString("deviceName"), o.getString("model"), List(arr.length()) { arr.getString(it) })
        }
    }
}

/** START (JSON): capture parameters requested by the Mac. */
data class StartConfig(
    val video: Boolean,
    val audio: Boolean,
    val facing: String,
    val width: Int,
    val height: Int,
    val fps: Int,
    val bitrate: Int,
) {
    fun encode(): ByteArray = JSONObject()
        .put("video", video)
        .put("audio", audio)
        .put("facing", facing)
        .put("width", width)
        .put("height", height)
        .put("fps", fps)
        .put("bitrate", bitrate)
        .toUtf8()

    companion object {
        fun decode(data: ByteArray): StartConfig? = parseJson(data) { o ->
            StartConfig(
                video = o.getBoolean("video"),
                audio = o.getBoolean("audio"),
                facing = o.getString("facing"),
                width = o.getInt("width"),
                height = o.getInt("height"),
                fps = o.getInt("fps"),
                bitrate = o.getInt("bitrate"),
            )
        }
    }
}

/** ERROR (JSON): `{"code":"busy|version|denied|internal","message":"…"}`. */
data class ErrorPayload(val code: String, val message: String) {
    fun encode(): ByteArray = JSONObject().put("code", code).put("message", message).toUtf8()

    companion object {
        const val BUSY = "busy"
        const val VERSION = "version"
        const val DENIED = "denied"
        const val INTERNAL = "internal"

        fun decode(data: ByteArray): ErrorPayload? = parseJson(data) { o ->
            ErrorPayload(o.getString("code"), o.getString("message"))
        }
    }
}

private fun JSONObject.toUtf8(): ByteArray = toString().toByteArray(Charsets.UTF_8)

private inline fun <T> parseJson(data: ByteArray, build: (JSONObject) -> T): T? =
    try {
        build(JSONObject(String(data, Charsets.UTF_8)))
    } catch (e: JSONException) {
        null
    }
