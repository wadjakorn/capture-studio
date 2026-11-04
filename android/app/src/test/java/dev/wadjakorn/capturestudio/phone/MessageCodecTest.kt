package dev.wadjakorn.capturestudio.phone

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class MessageCodecTest {

    private fun bytes(vararg v: Int) = ByteArray(v.size) { v[it].toByte() }

    @Test
    fun roundTripTwoMessagesAndPartialTail() {
        val a = Message(MessageType.STOP, ByteArray(0))
        val b = Message(MessageType.AUDIO_FRAME, bytes(1, 2, 3))
        val wire = MessageCodec.encode(a) + MessageCodec.encode(b) + bytes(0x0E, 0x00)
        val buf = FrameBuffer()
        buf.append(wire, wire.size)
        assertEquals(listOf(a, b), buf.drain())
        assertArrayEquals(bytes(0x0E, 0x00), buf.remaining())
    }

    @Test
    fun messageSplitAcrossAppendsIsReassembled() {
        val m = Message(MessageType.AUDIO_FRAME, bytes(9, 8, 7, 6))
        val wire = MessageCodec.encode(m)
        val buf = FrameBuffer()
        buf.append(wire.copyOfRange(0, 3), 3)
        assertEquals(emptyList<Message>(), buf.drain())
        val rest = wire.copyOfRange(3, wire.size)
        buf.append(rest + bytes(0xFF, 0xFF), rest.size) // len limits what is consumed
        assertEquals(listOf(m), buf.drain())
        assertEquals(0, buf.remaining().size)
    }

    @Test
    fun headerIsBigEndian() {
        val d = MessageCodec.encode(Message(MessageType.VIDEO_FRAME, ByteArray(258)))
        assertArrayEquals(bytes(14, 0, 0, 1, 2), d.copyOfRange(0, 5))
        assertEquals(5 + 258, d.size)
    }

    @Test
    fun messageTypeCodesMatchMac() {
        assertEquals((1..19).toList(), MessageType.entries.map { it.code })
        assertEquals(MessageType.ERROR, MessageType.fromCode(19))
        assertNull(MessageType.fromCode(0))
        assertNull(MessageType.fromCode(20))
    }

    @Test
    fun unknownTypeThrows() {
        val buf = FrameBuffer()
        buf.append(bytes(200, 0, 0, 0, 0), 5)
        assertThrows(ProtocolException::class.java) { buf.drain() }
    }

    @Test
    fun oversizeThrows() {
        val buf = FrameBuffer()
        buf.append(bytes(14, 0xFF, 0xFF, 0xFF, 0xFF), 5)
        assertThrows(ProtocolException::class.java) { buf.drain() }
    }

    @Test
    fun exactlyMaxPayloadHeaderIsAccepted() {
        // 8 MiB = 0x00800000: header alone must not throw, just wait for the body.
        val buf = FrameBuffer()
        buf.append(bytes(14, 0x00, 0x80, 0x00, 0x00), 5)
        assertEquals(emptyList<Message>(), buf.drain())
        val over = FrameBuffer()
        over.append(bytes(14, 0x00, 0x80, 0x00, 0x01), 5)
        assertThrows(ProtocolException::class.java) { over.drain() }
    }

    @Test
    fun videoFrameRoundTripAndLayout() {
        val p = VideoFrame(ptsNs = 123_456_789L, keyframe = true, mirrored = true, rotationDeg = 90, nalus = bytes(0, 0, 0, 1, 0x65))
        val enc = p.encode()
        assertArrayEquals(
            bytes(0, 0, 0, 0, 0x07, 0x5B, 0xCD, 0x15, 0x03, 0x00, 0x5A, 0, 0, 0, 1, 0x65),
            enc,
        )
        assertEquals(p, VideoFrame.decode(enc))
        assertNull(VideoFrame.decode(ByteArray(10)))
    }

    @Test
    fun videoFrameFlagsAreIndependent() {
        val p = VideoFrame(ptsNs = 1, keyframe = false, mirrored = true, rotationDeg = 270, nalus = ByteArray(0))
        val enc = p.encode()
        assertEquals(11, enc.size)
        assertEquals(0x02, enc[8].toInt())
        assertEquals(p, VideoFrame.decode(enc))
    }

    @Test
    fun videoConfigRoundTripAndLayout() {
        val p = VideoConfig(listOf(bytes(0x67, 1, 2), bytes(0x68, 3)))
        val enc = p.encode()
        assertArrayEquals(bytes(2, 0, 3, 0x67, 1, 2, 0, 2, 0x68, 3), enc)
        assertEquals(p, VideoConfig.decode(enc))
        assertEquals(p, VideoConfig.decode(enc + bytes(0xAA))) // trailing bytes ignored
        assertNull(VideoConfig.decode(bytes(2, 0, 1, 0x67)))
        assertNull(VideoConfig.decode(ByteArray(0)))
    }

    @Test
    fun audioFrameRoundTrip() {
        val p = AudioFrame(ptsNs = 42, accessUnit = bytes(9, 8, 7))
        val enc = p.encode()
        assertArrayEquals(bytes(0, 0, 0, 0, 0, 0, 0, 42, 9, 8, 7), enc)
        assertEquals(p, AudioFrame.decode(enc))
        assertNull(AudioFrame.decode(ByteArray(7)))
    }

    @Test
    fun clockPongIsExactly24Bytes() {
        val p = ClockPong(macSendHostNs = 1, phoneRecvNs = 2, phoneSendNs = 3)
        val enc = p.encode()
        assertEquals(24, enc.size)
        assertArrayEquals(
            bytes(0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 3),
            enc,
        )
        assertEquals(p, ClockPong.decode(enc))
        assertNull(ClockPong.decode(ByteArray(23)))
        assertNull(ClockPong.decode(ByteArray(25)))
    }

    @Test
    fun clockPingCarriesMacSendTime() {
        val enc = ClockPing(0x0102030405060708L).encode()
        assertArrayEquals(bytes(1, 2, 3, 4, 5, 6, 7, 8), enc)
        assertEquals(0x0102030405060708L, ClockPing.decode(enc)!!.macSendHostNs)
    }

    @Test
    fun unsignedU64RoundTrips() {
        val p = AudioFrame(ptsNs = -1L, accessUnit = ByteArray(0)) // 0xFFFF_FFFF_FFFF_FFFF
        assertEquals(p, AudioFrame.decode(p.encode()))
    }

    @Test
    fun helloJsonRoundTrip() {
        val h = Hello(pv = 1, deviceName = "Pixel \"8\"", model = "GKWS6", caps = listOf("video", "audio"))
        assertEquals(h, Hello.decode(h.encode()))
    }

    @Test
    fun startConfigDecodesMacJson() {
        val json = """{"video":true,"audio":true,"facing":"back","width":1920,"height":1080,"fps":30,"bitrate":8000000}"""
        val s = StartConfig.decode(json.toByteArray(Charsets.UTF_8))
        assertEquals(StartConfig(video = true, audio = true, facing = "back", width = 1920, height = 1080, fps = 30, bitrate = 8_000_000), s)
        assertEquals(s, StartConfig.decode(s!!.encode()))
    }

    @Test
    fun errorPayloadRoundTrip() {
        val e = ErrorPayload(code = "busy", message = "already recording")
        assertEquals(e, ErrorPayload.decode(e.encode()))
        assertNull(ErrorPayload.decode("not json".toByteArray()))
    }

    @Test
    fun messageEqualityIsByContent() {
        assertEquals(Message(MessageType.STOP, bytes(1, 2)), Message(MessageType.STOP, bytes(1, 2)))
        assertEquals(Message(MessageType.STOP, bytes(1, 2)).hashCode(), Message(MessageType.STOP, bytes(1, 2)).hashCode())
    }
}
