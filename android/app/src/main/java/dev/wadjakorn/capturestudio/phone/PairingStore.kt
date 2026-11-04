package dev.wadjakorn.capturestudio.phone

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.security.MessageDigest

data class PairedMac(val name: String, val hash: String, val pairedAt: Long)

/**
 * Paired computers. Only `SHA-256(token)` (hex) and the Mac's name are stored —
 * never the token itself, so a copy of this file cannot be replayed as AUTH.
 */
class PairingStore private constructor(private val prefs: SharedPreferences) {
    private val lock = Any()
    private val _paired = MutableStateFlow(load())
    val paired: StateFlow<List<PairedMac>> = _paired.asStateFlow()

    fun all(): List<PairedMac> = _paired.value

    fun add(name: String, tokenHash: String) = synchronized(lock) {
        save(_paired.value + PairedMac(name, tokenHash, System.currentTimeMillis()))
    }

    fun revoke(hash: String) = synchronized(lock) {
        save(_paired.value.filterNot { it.hash == hash })
    }

    /**
     * The pairing whose hash equals `SHA-256(token)`, or null. Every entry is
     * compared with the constant-time `MessageDigest.isEqual`, with no early exit.
     */
    fun matches(token: ByteArray): PairedMac? {
        val candidate = sha256(token)
        var found: PairedMac? = null
        for (p in _paired.value) {
            val stored = hexToBytes(p.hash) ?: continue
            if (MessageDigest.isEqual(stored, candidate) && found == null) found = p
        }
        return found
    }

    private fun save(list: List<PairedMac>) {
        val arr = JSONArray()
        for (p in list) arr.put(JSONObject().put("name", p.name).put("hash", p.hash).put("pairedAt", p.pairedAt))
        prefs.edit().putString(KEY, arr.toString()).apply()
        _paired.value = list
    }

    private fun load(): List<PairedMac> {
        val raw = prefs.getString(KEY, null) ?: return emptyList()
        return try {
            val arr = JSONArray(raw)
            List(arr.length()) { i ->
                val o = arr.getJSONObject(i)
                PairedMac(o.getString("name"), o.getString("hash"), o.getLong("pairedAt"))
            }
        } catch (e: JSONException) {
            Log.e("CSPhone", "Corrupt pairing store; ignoring", e)
            emptyList()
        }
    }

    companion object {
        private const val KEY = "paired"

        @Volatile private var instance: PairingStore? = null

        fun get(context: Context): PairingStore = instance ?: synchronized(this) {
            instance ?: PairingStore(
                context.applicationContext.getSharedPreferences("pairings", Context.MODE_PRIVATE),
            ).also { instance = it }
        }

        fun sha256(data: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(data)

        fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it.toInt() and 0xFF) }

        private fun hexToBytes(s: String): ByteArray? {
            if (s.length % 2 != 0) return null
            return try {
                ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
            } catch (e: NumberFormatException) {
                null
            }
        }
    }
}
