package dev.wadjakorn.capturestudio.phone

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Log
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.spec.ECGenParameterSpec
import java.util.Date
import java.util.concurrent.TimeUnit
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.security.auth.x500.X500Principal

/**
 * The phone's TLS identity: an AndroidKeyStore EC P-256 key with the self-signed
 * certificate AndroidKeyStore issues for it. The private key never leaves the
 * keystore. The Mac pins SHA-256 of the certificate DER ([fingerprint]).
 */
object Identity {
    const val ALIAS = "capturestudio-phone"
    private const val PROVIDER = "AndroidKeyStore"
    private const val TAG = "CSPhone"

    private fun keyStore(): KeyStore = KeyStore.getInstance(PROVIDER).apply { load(null) }

    /** Generates the identity key on first use; a no-op afterwards. */
    @Synchronized
    fun ensureKey() {
        if (keyStore().containsAlias(ALIAS)) return
        val now = System.currentTimeMillis()
        // DIGEST_NONE is required: Conscrypt signs the pre-hashed TLS handshake
        // data with NONEwithECDSA. No user authentication: the key must be usable
        // by the foreground service with the screen off.
        val spec = KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN)
            .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
            .setDigests(
                KeyProperties.DIGEST_NONE,
                KeyProperties.DIGEST_SHA256,
                KeyProperties.DIGEST_SHA384,
                KeyProperties.DIGEST_SHA512,
            )
            .setCertificateSubject(X500Principal("CN=Capture Studio Phone"))
            .setCertificateSerialNumber(BigInteger.ONE)
            .setCertificateNotBefore(Date(now - TimeUnit.DAYS.toMillis(1)))
            .setCertificateNotAfter(Date(now + TimeUnit.DAYS.toMillis(3650)))
            .setUserAuthenticationRequired(false)
            .build()
        KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, PROVIDER).apply {
            initialize(spec)
            generateKeyPair()
        }
        Log.i(TAG, "Generated phone identity key")
    }

    /** SHA-256 of the identity certificate's DER encoding. */
    fun fingerprint(): ByteArray {
        val cert = keyStore().getCertificate(ALIAS) ?: error("identity key missing")
        return MessageDigest.getInstance("SHA-256").digest(cert.encoded)
    }

    /** Server-side TLS context presenting the identity certificate. */
    fun sslContext(): SSLContext {
        val kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm())
        kmf.init(keyStore(), null)
        return SSLContext.getInstance("TLS").apply { init(kmf.keyManagers, null, null) }
    }
}
