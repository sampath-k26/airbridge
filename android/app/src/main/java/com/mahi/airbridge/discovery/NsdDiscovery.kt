package com.mahi.airbridge.discovery

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.util.Log
import com.mahi.airbridge.core.protocol.AbProtocol
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.util.concurrent.Executors

/**
 * Optional DNS-SD discovery of `_airbridge._tcp`. Discovery never grants trust; it only
 * finds the current address of an already paired device (matched by TXT `id`).
 */
class NsdDiscovery(context: Context) {
    data class Found(val serviceName: String, val host: String, val port: Int, val deviceId: String?, val name: String?)

    private val nsd = context.getSystemService(NsdManager::class.java)
    private val wifi = context.applicationContext.getSystemService(WifiManager::class.java)
    private var multicastLock: WifiManager.MulticastLock? = null
    private var discovery: NsdManager.DiscoveryListener? = null
    private var registration: NsdManager.RegistrationListener? = null
    private val executor = Executors.newSingleThreadExecutor()
    private val _found = MutableStateFlow<Map<String, Found>>(emptyMap())
    val found: StateFlow<Map<String, Found>> = _found

    fun startDiscovery() {
        if (discovery != null) return
        multicastLock = wifi.createMulticastLock("airbridge-mdns").apply { setReferenceCounted(false); acquire() }
        val l = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) { Log.w(TAG, "discovery failed $errorCode") }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onServiceFound(info: NsdServiceInfo) = resolve(info)
            override fun onServiceLost(info: NsdServiceInfo) { _found.value = _found.value - info.serviceName }
        }
        discovery = l
        runCatching { nsd.discoverServices(AbProtocol.SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, l) }
    }

    @Suppress("DEPRECATION")
    private fun resolve(info: NsdServiceInfo) {
        val cb = object : NsdManager.ResolveListener {
            override fun onResolveFailed(si: NsdServiceInfo, errorCode: Int) {}
            override fun onServiceResolved(si: NsdServiceInfo) {
                val host = if (Build.VERSION.SDK_INT >= 34) si.hostAddresses.firstOrNull { it.address.size == 4 }?.hostAddress
                    else si.host?.hostAddress
                host ?: return
                val txt = si.attributes
                _found.value = _found.value + (si.serviceName to Found(si.serviceName, host, si.port,
                    txt["id"]?.toString(Charsets.UTF_8), txt["n"]?.toString(Charsets.UTF_8)))
            }
        }
        runCatching {
            if (Build.VERSION.SDK_INT >= 34) nsd.resolveService(info, executor, cb) else nsd.resolveService(info, cb)
        }
    }

    fun stopDiscovery() {
        discovery?.let { runCatching { nsd.stopServiceDiscovery(it) } }
        discovery = null
        multicastLock?.release(); multicastLock = null
        _found.value = emptyMap()
    }

    fun register(name: String, port: Int, deviceId: String) {
        unregister()
        val info = NsdServiceInfo().apply {
            serviceName = name; serviceType = AbProtocol.SERVICE_TYPE; this.port = port
            setAttribute("v", AbProtocol.VERSION.toString()); setAttribute("id", deviceId); setAttribute("n", name)
        }
        val l = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(si: NsdServiceInfo) {}
            override fun onRegistrationFailed(si: NsdServiceInfo, errorCode: Int) { Log.w(TAG, "register failed $errorCode") }
            override fun onServiceUnregistered(si: NsdServiceInfo) {}
            override fun onUnregistrationFailed(si: NsdServiceInfo, errorCode: Int) {}
        }
        registration = l
        runCatching { nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, l) }
    }

    fun unregister() {
        registration?.let { runCatching { nsd.unregisterService(it) } }
        registration = null
    }

    private companion object { const val TAG = "AirBridgeNsd" }
}
