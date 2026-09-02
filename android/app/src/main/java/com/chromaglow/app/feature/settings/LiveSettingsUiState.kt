package com.chromaglow.app.feature.settings

import com.chromaglow.app.core.identity.BridgeId
import com.chromaglow.app.core.session.ConnectionState
import com.chromaglow.app.core.session.HomeSnapshot
import com.chromaglow.app.feature.home.HomeUiMapper
import com.chromaglow.app.ui.components.ConnectionRowUi

/** Live Settings: list-ready paired bridges with status, the mode, and About. */
data class LiveSettingsUiState(
    val modeLabel: String,
    val bridges: List<PairedBridgeRowUi>,
    val appVersion: String,
    /** The bridge a Forget confirmation is open for, if any. */
    val confirmingForget: BridgeId?,
)

data class PairedBridgeRowUi(
    val bridgeId: BridgeId,
    val label: String,
    val row: ConnectionRowUi,
)

object LiveSettingsUiMapper {
    fun map(home: HomeSnapshot, appVersion: String, confirmingForget: BridgeId?, nowMillis: Long): LiveSettingsUiState {
        val multi = home.bridges.size > 1
        val bridges = home.bridges.keys.sortedBy { it.value }.map { id ->
            PairedBridgeRowUi(
                bridgeId = id,
                label = HomeUiMapper.bridgeLabel(id, multi),
                row = HomeUiMapper.connectionRow(id, home.connections[id] ?: ConnectionState.Connecting, nowMillis, multi),
            )
        }
        return LiveSettingsUiState(
            modeLabel = "Live Mode",
            bridges = bridges,
            appVersion = appVersion,
            confirmingForget = confirmingForget?.takeIf { it in home.bridges.keys },
        )
    }
}
