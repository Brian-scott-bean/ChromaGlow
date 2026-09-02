package com.chromaglow.app.feature.setup

import com.chromaglow.app.core.bridge.PairedBridgeRecord
import com.chromaglow.app.core.hue.discovery.BridgeEndpoint

/**
 * State of the single selected/paired bridge card that replaces the old inert "Selected bridge"
 * card. No variant ever carries the application key/username — [Paired] holds only the non-secret
 * [PairedBridgeRecord], and [Recovery] holds only static, user-safe text.
 */
sealed interface BridgePairingUiState {

    /** No bridge selected; the chooser/manual entry is in control. */
    data object None : BridgePairingUiState

    /**
     * A bridge is selected and ready to pair. [retryMessage] is set (non-null) for the
     * link-button-required case: the same selected card with a concise retry prompt, where pairing
     * is retried only on the user's next tap.
     */
    data class Selected(
        val bridge: BridgeEndpoint,
        val retryMessage: String? = null,
    ) : BridgePairingUiState

    /** A single pairing attempt is in flight; the Pair action is suppressed. */
    data class Pairing(val bridge: BridgeEndpoint) : BridgePairingUiState

    /** Durable "Bridge connected" state with the non-secret bridge name/address and local forget. */
    data class Paired(val bridge: PairedBridgeRecord) : BridgePairingUiState

    /**
     * Recovery/error: static, user-safe [message] only. [retryBridge] (when set) offers Try Again
     * back to [Selected]; [forgettableBridgeId] (when set) offers a local Forget Bridge;
     * [canResetSavedBridges] (when true) offers the explicit local metadata reset for the case
     * where saved bridge data is unreadable and no bridge id exists to forget. Neither affordance
     * ever runs without a user tap, and no credential is deleted by the reset.
     */
    data class Recovery(
        val message: String,
        val retryBridge: BridgeEndpoint? = null,
        val forgettableBridgeId: String? = null,
        val canResetSavedBridges: Boolean = false,
    ) : BridgePairingUiState
}

/**
 * Complete Setup UI state. Discovery/manual-entry fields preserve the existing scan/manual/Scan
 * Again behavior; [pairing] drives the new live-pairing card.
 */
data class SetupUiState(
    val isScanning: Boolean = false,
    val choices: List<BridgeEndpoint> = emptyList(),
    val statusMessage: String? = null,
    val manualVisible: Boolean = false,
    val manualText: String = "",
    val manualError: String? = null,
    val pairing: BridgePairingUiState = BridgePairingUiState.None,
)
