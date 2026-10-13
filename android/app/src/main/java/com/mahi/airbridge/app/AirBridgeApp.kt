package com.mahi.airbridge.app

import android.app.Application
import android.content.Context
import com.mahi.airbridge.core.crypto.TrustStore
import com.mahi.airbridge.discovery.NsdDiscovery
import com.mahi.airbridge.network.HotspotController
import com.mahi.airbridge.security.KeystoreIdentity
import com.mahi.airbridge.transfer.SessionManager
import com.mahi.airbridge.transfer.TransferHistory
import java.io.File

/** Process-wide singletons (manual dependency injection — no DI framework needed). */
class AppGraph(context: Context) {
    val settings = Settings(context)
    val identity = KeystoreIdentity.loadOrCreate()
    val trust = TrustStore(File(context.filesDir, "trust.json"))
    val history = TransferHistory(File(context.filesDir, "history.json"))
    val discovery = NsdDiscovery(context)
    val hotspot = HotspotController(context)
    val sessions = SessionManager(context, identity, trust, settings, history, discovery)
}

class AirBridgeApp : Application() {
    lateinit var graph: AppGraph
        private set

    override fun onCreate() {
        super.onCreate()
        graph = AppGraph(this)
    }
}

val Context.graph: AppGraph get() = (applicationContext as AirBridgeApp).graph
