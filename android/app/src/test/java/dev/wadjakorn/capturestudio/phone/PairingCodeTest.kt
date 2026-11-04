package dev.wadjakorn.capturestudio.phone

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PairingCodeTest {

    @Test
    fun crossPlatformVector() {
        val fp = ByteArray(32) { 0xAB.toByte() }
        val nm = ByteArray(32) { 0x01 }
        val np = ByteArray(32) { 0x02 }
        // Frozen vector shared with the Mac (PhonePairingCodeTests.swift).
        assertEquals("601340", PairingCode.deriveCode(fp, nm, np))
    }

    @Test
    fun codeIsZeroPaddedSixDigits() {
        for (i in 0 until 64) {
            val code = PairingCode.deriveCode(ByteArray(32) { i.toByte() }, ByteArray(32), ByteArray(32))
            assertEquals(6, code.length)
            assertTrue(code.all { it in '0'..'9' })
        }
    }

    @Test
    fun commitmentVerifiesRightRevealOnly() {
        val n = ByteArray(32) { 7 }
        val c = PairingCode.commitment(n)
        assertEquals(32, c.size)
        assertTrue(PairingCode.verifyCommitment(c, n))
        assertFalse(PairingCode.verifyCommitment(c, ByteArray(32) { 8 }))
        assertFalse(PairingCode.verifyCommitment(c.copyOf(31), n))
    }

    @Test
    fun formatted() {
        assertEquals("483 921", PairingCode.formatted("483921"))
    }
}
