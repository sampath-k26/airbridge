package com.mahi.airbridge.app

import android.content.Context
import android.net.Uri
import android.os.Build
import android.provider.Settings as SysSettings
import com.mahi.airbridge.core.protocol.AbProtocol
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/** User preferences (no secrets are stored here). */
class Settings(private val context: Context) {
    private val prefs = context.getSharedPreferences("settings", Context.MODE_PRIVATE)

    data class Values(
        val deviceName: String,
        val destinationTree: Uri?,      // null = Downloads/AirBridge via MediaStore
        val askBeforeReceiving: Boolean,
        val chunkSize: Int,
    )

    private val _values = MutableStateFlow(read())
    val values: StateFlow<Values> = _values

    private fun read() = Values(
        deviceName = prefs.getString("deviceName", null) ?: defaultName(),
        destinationTree = prefs.getString("destinationTree", null)?.let(Uri::parse),
        askBeforeReceiving = prefs.getBoolean("askBeforeReceiving", false),
        chunkSize = prefs.getInt("chunkSize", AbProtocol.DEFAULT_CHUNK),
    )

    private fun defaultName(): String =
        runCatching { SysSettings.Global.getString(context.contentResolver, SysSettings.Global.DEVICE_NAME) }.getOrNull()
            ?.takeIf { it.isNotBlank() } ?: Build.MODEL

    fun update(block: (Values) -> Values) {
        val v = block(_values.value)
        prefs.edit()
            .putString("deviceName", v.deviceName.take(40))
            .putString("destinationTree", v.destinationTree?.toString())
            .putBoolean("askBeforeReceiving", v.askBeforeReceiving)
            .putInt("chunkSize", v.chunkSize)
            .apply()
        _values.value = v
    }
}
