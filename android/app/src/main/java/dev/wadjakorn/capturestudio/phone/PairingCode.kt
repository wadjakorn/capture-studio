package dev.wadjakorn.capturestudio.phone

import java.security.MessageDigest

/** Commitment-based pairing code, byte-identical to the Mac's `PairingCode`. */
object PairingCode {
    fun commitment(nonce: ByteArray): ByteArray = sha256(nonce)

    /** Constant-time comparison of `SHA-256(nonce)` against [commitment]. */
    fun verifyCommitment(commitment: ByteArray, nonce: ByteArray): Boolean =
        MessageDigest.isEqual(commitment, sha256(nonce))

    /** `u32BE(SHA-256(fingerprint ‖ macNonce ‖ phoneNonce)[0..<4]) % 1_000_000`, zero-padded to 6 digits. */
    fun deriveCode(fingerprint: ByteArray, macNonce: ByteArray, phoneNonce: ByteArray): String {
        val d = sha256(fingerprint + macNonce + phoneNonce)
        val value = ((d[0].toLong() and 0xFF) shl 24) or
            ((d[1].toLong() and 0xFF) shl 16) or
            ((d[2].toLong() and 0xFF) shl 8) or
            (d[3].toLong() and 0xFF)
        return (value % 1_000_000).toString().padStart(6, '0')
    }

    /** "483921" -> "483 921" */
    fun formatted(code: String): String =
        if (code.length <= 3) code else code.substring(0, 3) + " " + code.substring(3)

    private fun sha256(data: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(data)
}
