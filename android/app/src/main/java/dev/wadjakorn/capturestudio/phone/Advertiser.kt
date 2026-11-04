package dev.wadjakorn.capturestudio.phone

import android.annotation.SuppressLint
import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.util.Log
import java.util.UUID

/** Bonjour/DNS-SD advertisement of the TLS server as `_capturestudio._tcp`. */
class Advertiser(context: Context) {
    private val appContext = context.applicationContext
    private val nsd = appContext.getSystemService(NsdManager::class.java)
    private var listener: NsdManager.RegistrationListener? = null

    /** The name actually registered (NSD may rename on collision), or null. */
    @Volatile var registeredName: String? = null
        private set

    @Synchronized
    fun register(port: Int) {
        if (listener != null) return
        val info = NsdServiceInfo().apply {
            serviceName = Build.MODEL
            serviceType = SERVICE_TYPE
            setPort(port)
            setAttribute("id", stableId(appContext))
            setAttribute("name", Build.MODEL)
            setAttribute("pv", PROTOCOL_VERSION.toString())
        }
        val l = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {
                registeredName = info.serviceName
                Log.i(TAG, "Advertising as '${info.serviceName}' on port $port")
            }

            override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                Log.e(TAG, "NSD registration failed: $errorCode")
                synchronized(this@Advertiser) { if (listener === this) listener = null }
            }

            override fun onServiceUnregistered(info: NsdServiceInfo) {
                Log.i(TAG, "NSD service unregistered")
                registeredName = null
            }

            override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "NSD unregistration failed: $errorCode")
            }
        }
        listener = l
        nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, l)
    }

    @Synchronized
    fun unregister() {
        val l = listener ?: return
        listener = null
        try {
            nsd.unregisterService(l)
        } catch (e: IllegalArgumentException) {
            Log.w(TAG, "NSD unregister: listener not registered", e)
        }
    }

    companion object {
        const val SERVICE_TYPE = "_capturestudio._tcp"
        const val PROTOCOL_VERSION = 1
        private const val TAG = "CSPhone"

        /** Stable advertisement id, generated once and persisted. */
        @SuppressLint("ApplySharedPref") // must be durable before it is advertised
        @Synchronized
        fun stableId(context: Context): String {
            val prefs = context.getSharedPreferences("identity", Context.MODE_PRIVATE)
            prefs.getString("id", null)?.let { return it }
            val id = UUID.randomUUID().toString()
            prefs.edit().putString("id", id).commit()
            return id
        }
    }
}
