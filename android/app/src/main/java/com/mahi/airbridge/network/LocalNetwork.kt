package com.mahi.airbridge.network

import android.annotation.SuppressLint
import android.content.Context
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.net.Inet4Address
import java.net.NetworkInterface

object LocalNetwork {
    data class Address(val iface: String, val ip: String) {
        /** Hotspot (AP) interfaces are where a Mac joined to the phone's hotspot lives. */
        val isHotspot get() = iface.startsWith("ap") || iface.startsWith("swlan") || iface.startsWith("softap")
    }

    /** IPv4 addresses on Wi-Fi/hotspot/USB interfaces, hotspot first. Cellular is excluded. */
    fun addresses(): List<Address> = runCatching {
        NetworkInterface.getNetworkInterfaces().toList()
            .filter { it.isUp && !it.isLoopback }
            .filter { n -> listOf("wlan", "ap", "swlan", "softap", "rndis", "ncm", "usb", "eth").any { n.name.startsWith(it) } }
            .flatMap { n -> n.inetAddresses.toList().filterIsInstance<Inet4Address>().map { Address(n.name, it.hostAddress!!) } }
            .sortedBy { if (it.isHotspot) 0 else 1 }
    }.getOrDefault(emptyList())
}

/**
 * In-app Local-Only Hotspot (Android 8+). Creates a Wi-Fi network with a random SSID and
 * password that has no internet; the Mac joins it manually. The hotspot lives only while
 * AirBridge holds the reservation.
 */
class HotspotController(context: Context) {
    sealed interface State {
        data object Off : State
        data object Starting : State
        data class On(val ssid: String, val passphrase: String?) : State
        data class Failed(val reason: String) : State
    }

    private val wifi = context.applicationContext.getSystemService(WifiManager::class.java)
    private var reservation: WifiManager.LocalOnlyHotspotReservation? = null
    private val _state = MutableStateFlow<State>(State.Off)
    val state: StateFlow<State> = _state

    @SuppressLint("MissingPermission") // permission is requested by the UI before calling
    fun start() {
        if (_state.value is State.On || _state.value is State.Starting) return
        _state.value = State.Starting
        try {
            wifi.startLocalOnlyHotspot(object : WifiManager.LocalOnlyHotspotCallback() {
                override fun onStarted(r: WifiManager.LocalOnlyHotspotReservation) {
                    reservation = r
                    val (ssid, pass) = if (Build.VERSION.SDK_INT >= 30) {
                        val c = r.softApConfiguration
                        val s = if (Build.VERSION.SDK_INT >= 33) c.wifiSsid?.toString()?.trim('"') else @Suppress("DEPRECATION") c.ssid
                        s to c.passphrase
                    } else {
                        @Suppress("DEPRECATION") val c = r.wifiConfiguration
                        @Suppress("DEPRECATION") (c?.SSID to c?.preSharedKey)
                    }
                    _state.value = State.On(ssid ?: "?", pass)
                }

                override fun onStopped() { reservation = null; _state.value = State.Off }

                override fun onFailed(reason: Int) {
                    reservation = null
                    _state.value = State.Failed(when (reason) {
                        ERROR_TETHERING_DISALLOWED -> "Hotspot is not allowed on this device"
                        ERROR_INCOMPATIBLE_MODE -> "Turn off the regular Wi-Fi hotspot first"
                        ERROR_NO_CHANNEL -> "No free Wi-Fi channel"
                        else -> "Hotspot failed ($reason)"
                    })
                }
            }, Handler(Looper.getMainLooper()))
        } catch (e: SecurityException) {
            _state.value = State.Failed("Permission needed to create a hotspot")
        } catch (e: IllegalStateException) {
            _state.value = State.Failed("A hotspot is already active (${e.message})")
        }
    }

    fun stop() {
        reservation?.close()
        reservation = null
        _state.value = State.Off
    }
}
