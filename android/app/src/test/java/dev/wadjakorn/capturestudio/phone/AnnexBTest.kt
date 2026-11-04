package dev.wadjakorn.capturestudio.phone

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class AnnexBTest {

    private fun bytes(vararg v: Int) = ByteArray(v.size) { v[it].toByte() }

    private val stream = bytes(
        0, 0, 0, 1, 0x67, 0x11, 0x22,
        0, 0, 0, 1, 0x68, 0x33,
        0, 0, 0, 1, 0x65, 0x44, 0x55,
    )

    @Test
    fun parameterSetsFromFourByteStartCodes() {
        val (sps, pps) = AnnexB.parameterSets(stream)
        assertArrayEquals(bytes(0x67, 0x11, 0x22), sps)
        assertArrayEquals(bytes(0x68, 0x33), pps)
    }

    @Test
    fun parameterSetsFromThreeByteStartCodes() {
        val cfg = bytes(0, 0, 1, 0x67, 0x11, 0x22, 0, 0, 1, 0x68, 0x33)
        val (sps, pps) = AnnexB.parameterSets(cfg)
        assertArrayEquals(bytes(0x67, 0x11, 0x22), sps)
        assertArrayEquals(bytes(0x68, 0x33), pps)
    }

    @Test
    fun parameterSetsMissingPpsThrows() {
        assertThrows(IllegalArgumentException::class.java) {
            AnnexB.parameterSets(bytes(0, 0, 0, 1, 0x67, 0x11))
        }
    }

    @Test
    fun toAvccDropsSpsAndPps() {
        assertArrayEquals(bytes(0, 0, 0, 3, 0x65, 0x44, 0x55), AnnexB.toAvcc(stream))
    }

    @Test
    fun toAvccMixedStartCodesAndTrailingNal() {
        val frame = bytes(
            0, 0, 1, 0x06, 0x01,             // SEI, 3-byte start code
            0, 0, 0, 1, 0x41, 0x9A, 0x00, 0x07, // P-slice, 4-byte start code (contains 00 inside)
            0, 0, 1, 0x41, 0x02,             // trailing NAL, 3-byte start code
        )
        assertArrayEquals(
            bytes(
                0, 0, 0, 2, 0x06, 0x01,
                0, 0, 0, 4, 0x41, 0x9A, 0x00, 0x07,
                0, 0, 0, 2, 0x41, 0x02,
            ),
            AnnexB.toAvcc(frame),
        )
    }

    @Test
    fun nalUnitsSplitsOnStartCodes() {
        val units = AnnexB.nalUnits(bytes(0, 0, 1, 0x65, 0x01, 0, 0, 0, 1, 0x41))
        assertArrayEquals(bytes(0x65, 0x01), units[0])
        assertArrayEquals(bytes(0x41), units[1])
    }
}
