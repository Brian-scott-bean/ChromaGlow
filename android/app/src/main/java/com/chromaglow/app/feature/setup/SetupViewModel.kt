package com.chromaglow.app.feature.setup

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.chromaglow.app.core.bridge.DataStoreBridgeRegistry
import com.chromaglow.app.core.credentials.AndroidKeystoreBridgeCredentialStore
import com.chromaglow.app.core.hue.discovery.AndroidNsdBridgeDiscoveryService
import com.chromaglow.app.core.hue.discovery.BridgeDiscoveryService
import com.chromaglow.app.core.hue.discovery.BridgeEndpoint
import com.chromaglow.app.core.hue.discovery.ManualBridgeEndpointParser
import com.chromaglow.app.core.hue.pairing.transport.OkHttpHuePairingClient
import com.chromaglow.app.core.hue.pairing.workflow.ForgetResult
import com.chromaglow.app.core.hue.pairing.workflow.LivePairingWorkflow
import com.chromaglow.app.core.hue.pairing.workflow.PairingErrorReason
import com.chromaglow.app.core.hue.pairing.workflow.PairingOutcome
import com.chromaglow.app.core.hue.pairing.workflow.RestoredState
import kotlinx.coroutines.launch

/**
 * Drives the Setup screen: bridge discovery/manual entry plus the live-pairing transaction.
 *
 * Collaborators are injected ([LivePairingWorkflow], [BridgeDiscoveryService]) so Compose tests can
 * exercise every pairing state with fakes and NEVER contact a real bridge or build a real
 * DataStore. Production instances are built by [factory]. UI state is exposed as a single
 * snapshot-backed [uiState]; the workflow keeps the token out of it entirely.
 */
class SetupViewModel internal constructor(
    private val workflow: LivePairingWorkflow,
    private val discovery: BridgeDiscoveryService,
    private val onBridgeSelected: (BridgeEndpoint) -> Unit = {},
) : ViewModel() {

    var uiState: SetupUiState by mutableStateOf(SetupUiState())
        private set

    init {
        // Startup reconciliation: restore a paired session only when record + readable token exist.
        viewModelScope.launch {
            uiState = uiState.copy(pairing = workflow.restore().toPairingState())
        }
    }

    fun scanForBridge() {
        discovery.stop()
        uiState = SetupUiState(isScanning = true)
        discovery.start { snapshot ->
            uiState = uiState.copy(
                isScanning = snapshot.isScanning,
                choices = snapshot.choices,
                statusMessage = snapshot.statusMessage,
            )
        }
    }

    fun enterManualEntry() {
        discovery.stop()
        uiState = SetupUiState(manualVisible = true)
    }

    fun updateManualText(text: String) {
        uiState = uiState.copy(manualText = text)
    }

    fun submitManualEntry() {
        when (val result = ManualBridgeEndpointParser.parse(uiState.manualText)) {
            is ManualBridgeEndpointParser.Parsed.Valid -> selectBridge(result.endpoint)
            is ManualBridgeEndpointParser.Parsed.Invalid ->
                uiState = uiState.copy(manualError = result.message)
        }
    }

    fun selectDiscoveredBridge(bridge: BridgeEndpoint) {
        discovery.stop()
        selectBridge(bridge)
    }

    private fun selectBridge(bridge: BridgeEndpoint) {
        uiState = uiState.copy(
            manualVisible = false,
            manualText = "",
            manualError = null,
            isScanning = false,
            choices = emptyList(),
            statusMessage = null,
            pairing = BridgePairingUiState.Selected(bridge),
        )
        onBridgeSelected(bridge)
    }

    fun scanAgain() = scanForBridge()

    /** Start one pairing attempt. Ignored unless a bridge is selected (suppresses duplicate taps). */
    fun pair() {
        val bridge = when (val current = uiState.pairing) {
            is BridgePairingUiState.Selected -> current.bridge
            else -> return
        }
        uiState = uiState.copy(pairing = BridgePairingUiState.Pairing(bridge))
        viewModelScope.launch {
            val outcome = workflow.pair(bridge)
            uiState = uiState.copy(pairing = outcome.toPairingState(bridge))
        }
    }

    /** Retry after a recoverable terminal failure: return to the selected state. */
    fun tryAgain() {
        val recovery = uiState.pairing as? BridgePairingUiState.Recovery ?: return
        val bridge = recovery.retryBridge ?: return
        uiState = uiState.copy(pairing = BridgePairingUiState.Selected(bridge))
    }

    /** Local-only forget of the currently paired (or repairable) bridge. */
    fun forget() {
        val bridgeId = when (val current = uiState.pairing) {
            is BridgePairingUiState.Paired -> current.bridge.bridgeId
            is BridgePairingUiState.Recovery -> current.forgettableBridgeId ?: return
            else -> return
        }
        viewModelScope.launch {
            uiState = uiState.copy(
                pairing = when (workflow.forget(bridgeId)) {
                    ForgetResult.Forgotten -> BridgePairingUiState.None
                    ForgetResult.CleanupFailed -> BridgePairingUiState.Recovery(
                        message = FORGET_FAILED_MESSAGE,
                        forgettableBridgeId = bridgeId,
                    )
                },
            )
        }
    }

    override fun onCleared() {
        discovery.stop()
    }

    private fun PairingOutcome.toPairingState(bridge: BridgeEndpoint): BridgePairingUiState =
        when (this) {
            is PairingOutcome.Paired -> BridgePairingUiState.Paired(this.bridge)
            PairingOutcome.LinkButtonRequired ->
                BridgePairingUiState.Selected(bridge, retryMessage = LINK_BUTTON_MESSAGE)
            is PairingOutcome.Failed ->
                BridgePairingUiState.Recovery(message = reason.toMessage(), retryBridge = bridge)
        }

    private fun RestoredState.toPairingState(): BridgePairingUiState =
        when (this) {
            RestoredState.Unpaired -> BridgePairingUiState.None
            is RestoredState.Paired -> BridgePairingUiState.Paired(bridge)
            is RestoredState.NeedsRepair -> BridgePairingUiState.Recovery(
                message = NEEDS_REPAIR_MESSAGE,
                forgettableBridgeId = bridge.bridgeId,
            )
            RestoredState.Unavailable -> BridgePairingUiState.Recovery(message = UNAVAILABLE_MESSAGE)
        }

    private fun PairingErrorReason.toMessage(): String =
        when (this) {
            PairingErrorReason.INVALID_REQUEST ->
                "This bridge rejected the request. Make sure it's a supported Hue bridge and try again."
            PairingErrorReason.IDENTITY_MISMATCH ->
                "Couldn't verify this bridge's identity. Connect to the same network and try again."
            PairingErrorReason.UNTRUSTED_OR_UNREACHABLE ->
                "Couldn't reach this bridge securely. Check your connection and try again."
            PairingErrorReason.BRIDGE_ERROR ->
                "The bridge reported a problem. Try again in a moment."
            PairingErrorReason.BRIDGE_RESPONSE_INVALID ->
                "The bridge sent an unexpected response. Try again."
            PairingErrorReason.LOCAL_PERSISTENCE ->
                "Couldn't save this bridge on your device. Try again."
        }

    companion object {
        const val LINK_BUTTON_MESSAGE =
            "Press the link button on your Hue bridge, then tap Pair."
        const val NEEDS_REPAIR_MESSAGE =
            "Your saved bridge needs to be set up again. Forget it, then pair to reconnect."
        const val UNAVAILABLE_MESSAGE =
            "Your saved bridge couldn't be restored. Scan or enter its address to pair again."
        const val FORGET_FAILED_MESSAGE =
            "Couldn't remove the saved bridge from this device. Try again."

        /** Production factory: wires the real transport, Keystore store, registry, and discovery. */
        fun factory(
            context: Context,
            onBridgeSelected: (BridgeEndpoint) -> Unit,
        ): ViewModelProvider.Factory = viewModelFactory {
            initializer {
                val appContext = context.applicationContext
                val workflow = LivePairingWorkflow(
                    pairingClient = OkHttpHuePairingClient.fromContext(appContext),
                    credentialStore = AndroidKeystoreBridgeCredentialStore(appContext),
                    bridgeRegistry = DataStoreBridgeRegistry.create(appContext),
                )
                SetupViewModel(
                    workflow = workflow,
                    discovery = AndroidNsdBridgeDiscoveryService(appContext),
                    onBridgeSelected = onBridgeSelected,
                )
            }
        }
    }
}
