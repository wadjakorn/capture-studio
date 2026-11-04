package dev.wadjakorn.capturestudio.phone

import java.nio.ByteBuffer

/** Annex-B (start-code) H.264 helpers for MediaCodec output. */
object AnnexB {
    private const val NAL_SPS = 7
    private const val NAL_PPS = 8

    /** First SPS and PPS (no start codes) from a `BUFFER_FLAG_CODEC_CONFIG` buffer. */
    fun parameterSets(codecConfig: ByteArray): Pair<ByteArray, ByteArray> {
        val units = nalUnits(codecConfig)
        val sps = units.firstOrNull { nalType(it) == NAL_SPS }
        val pps = units.firstOrNull { nalType(it) == NAL_PPS }
        require(sps != null && pps != null) { "codec config lacks SPS/PPS" }
        return sps to pps
    }

    /** Annex-B frame -> AVCC (4-byte BE length prefixes), dropping SPS/PPS (sent only via VIDEO_CONFIG). */
    fun toAvcc(frame: ByteArray): ByteArray {
        val kept = nalRanges(frame).filter { (s, _) ->
            val t = frame[s].toInt() and 0x1F
            t != NAL_SPS && t != NAL_PPS
        }
        val out = ByteBuffer.allocate(kept.sumOf { (s, e) -> 4 + (e - s) })
        for ((s, e) in kept) {
            out.putInt(e - s)
            out.put(frame, s, e - s)
        }
        return out.array()
    }

    /** NAL units (header byte onward, no start codes) split on 3- or 4-byte start codes. */
    fun nalUnits(data: ByteArray): List<ByteArray> = nalRanges(data).map { (s, e) -> data.copyOfRange(s, e) }

    private fun nalType(nal: ByteArray): Int = nal[0].toInt() and 0x1F

    /**
     * Half-open [start, end) ranges of each NAL. Bytes before the first start code are ignored;
     * trailing zero bytes (the leading 0x00 of a following 4-byte start code, or trailing_zero_8bits)
     * are trimmed — a valid NAL never ends in 0x00. Empty NALs are skipped.
     */
    private fun nalRanges(data: ByteArray): List<Pair<Int, Int>> {
        val starts = ArrayList<Int>() // index just after each 00 00 01
        var i = 0
        while (i + 2 < data.size) {
            if (data[i].toInt() == 0 && data[i + 1].toInt() == 0 && data[i + 2].toInt() == 1) {
                starts += i + 3
                i += 3
            } else {
                i++
            }
        }
        val ranges = ArrayList<Pair<Int, Int>>(starts.size)
        for ((k, s) in starts.withIndex()) {
            var e = if (k + 1 < starts.size) starts[k + 1] - 3 else data.size
            while (e > s && data[e - 1].toInt() == 0) e--
            if (e > s) ranges += s to e
        }
        return ranges
    }
}
