package com.chromaglow.app.app

import android.content.Context
import com.chromaglow.app.core.bridge.BridgeRegistry
import com.chromaglow.app.core.bridge.DataStoreBridgeRegistry
import com.chromaglow.app.core.credentials.AndroidKeystoreBridgeCredentialStore
import com.chromaglow.app.core.credentials.BridgeCredentialStore
import com.chromaglow.app.core.hue.pairing.transport.OkHttpHuePairingClient
import com.chromaglow.app.core.hue.pairing.workflow.LivePairingWorkflow
import com.chromaglow.app.core.hue.tls.HueTrust
import com.chromaglow.app.core.session.DefaultLiveHome
import com.chromaglow.app.core.session.LiveHomeFactories
import com.chromaglow.app.core.session.LiveSessionFactories
import kotlinx.coroutines.CoroutineScope
import java.io.File

/**
 * Process-wide production collaborators shared by Setup (pairing) and the live shell. One
 * instance per process: the registry's DataStore mandates a single active instance per file, and
 * Setup + LiveHome must observe the same records and the same Keystore-backed credential store.
 *
 * Holds only application-context-derived objects; never a token, never a session.
 */
class LiveAppGraph private constructor(context: Context) {

    // Private on purpose (A-02): feature code reaches persisted identity only through the
    // pairing workflow and the live home, never the registry or the credential store directly.
    private val registry: BridgeRegistry = DataStoreBridgeRegistry.create(context)
    private val credentialStore: BridgeCredentialStore = AndroidKeystoreBridgeCredentialStore(context)

    val pairingWorkflow: LivePairingWorkflow = LivePairingWorkflow(
        pairingClient = OkHttpHuePairingClient.fromContext(context),
        credentialStore = credentialStore,
        bridgeRegistry = registry,
    )

    private val factories: LiveHomeFactories by lazy {
        LiveSessionFactories.production(
            trust = HueTrust.fromContext(context),
            // noBackupFilesDir: snapshots are secret-free but bridge-specific; never cloud-backed.
            cacheDirectory = File(context.noBackupFilesDir, "snapshots"),
        )
    }

    /** A started [DefaultLiveHome] whose sessions are children of [scope]. */
    fun newLiveHome(scope: CoroutineScope): DefaultLiveHome =
        DefaultLiveHome(
            registry = registry,
            credentialStore = credentialStore,
            factories = factories,
            parentScope = scope,
        ).also { it.start() }

    companion object {
        @Volatile
        private var instance: LiveAppGraph? = null

        fun get(context: Context): LiveAppGraph =
            instance ?: synchronized(this) {
                instance ?: LiveAppGraph(context.applicationContext).also { instance = it }
            }
    }
}
