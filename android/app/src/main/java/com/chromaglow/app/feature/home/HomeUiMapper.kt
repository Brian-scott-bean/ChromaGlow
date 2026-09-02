package com.chromaglow.app.feature.home

import com.chromaglow.app.core.identity.BridgeId
import com.chromaglow.app.core.identity.ResourceType
import com.chromaglow.app.core.identity.TargetRef
import com.chromaglow.app.core.session.BridgeSnapshot
import com.chromaglow.app.core.session.ConnectionState
import com.chromaglow.app.core.session.GroupState
import com.chromaglow.app.core.session.HomeSnapshot
import com.chromaglow.app.core.session.SessionErrorReason
import com.chromaglow.app.ui.components.ConnectionRowUi
import com.chromaglow.app.ui.components.ConnectionTone
import kotlin.math.roundToInt

/**
 * Pure mapping from live truth to Home UI. Deterministic given [nowMillis]; JVM-tested.
 *
 * Interaction policy (final, from the approved plan):
 *  - Connected / Stale → controls enabled (stale data is still the user's best lever);
 *  - Connecting with retained data → enabled (a refresh in flight is not a reason to refuse);
 *  - Offline / Revoked / Error → controls disabled with a spoken reason; raw gestures refused.
 *
 * Loading placeholders appear ONLY when no bridge has any snapshot data. There is no demo
 * fallback: a live failure shows the honest state, never fixtures.
 */
object HomeUiMapper {

    fun map(home: HomeSnapshot, nowMillis: Long): HomeUiState {
        if (home.bridges.isEmpty()) {
            return HomeUiState(HomePhase.NO_BRIDGES, emptyList(), emptyList(), emptyList())
        }
        val multi = home.bridges.size > 1
        val strip = home.bridges.keys
            .sortedBy { it.value }
            .map { id -> connectionRow(id, home.connections[id] ?: ConnectionState.Connecting, nowMillis, multi) }

        val rooms = mutableListOf<GroupCardUi>()
        val zones = mutableListOf<GroupCardUi>()
        var anyData = false
        var anyConnecting = false
        for ((id, snapshot) in home.bridges) {
            val connection = home.connections[id] ?: ConnectionState.Connecting
            val hasData = snapshot.generation > 0 || snapshot.rooms.isNotEmpty() || snapshot.zones.isNotEmpty()
            if (hasData) anyData = true
            if (connection is ConnectionState.Connecting && !hasData) anyConnecting = true
            val (enabled, reason) = interaction(connection)
            snapshot.rooms.values.forEach { rooms += card(snapshot, it, enabled, reason) }
            snapshot.zones.values.forEach { zones += card(snapshot, it, enabled, reason) }
        }
        rooms.sortBy { it.name.lowercase() }
        zones.sortBy { it.name.lowercase() }

        val phase = when {
            rooms.isNotEmpty() || zones.isNotEmpty() -> HomePhase.CONTENT
            !anyData && anyConnecting -> HomePhase.LOADING
            else -> HomePhase.EMPTY
        }
        return HomeUiState(phase = phase, strip = strip, rooms = rooms, zones = zones)
    }

    private fun card(
        snapshot: BridgeSnapshot,
        group: GroupState,
        enabled: Boolean,
        reason: String?,
    ): GroupCardUi {
        val grouped = group.groupedLight?.let { snapshot.groupedLights[it] }
        val childSet = group.children.toSet()
        val lightCount = snapshot.lights.values.count { light ->
            light.key in childSet || (light.owner != null && light.owner in childSet)
        }.let { counted ->
            if (counted > 0) counted else group.children.count { it.type == ResourceType.LIGHT }
        }
        return GroupCardUi(
            groupKey = group.key,
            target = group.groupedLight?.let { TargetRef.Live(it) },
            bridgeId = snapshot.bridgeId,
            kind = group.kind,
            name = group.name,
            lightCount = lightCount,
            isOn = grouped?.isOn ?: false,
            brightness = grouped?.brightness?.roundToInt()?.coerceIn(1, 100),
            controlsEnabled = enabled && group.groupedLight != null,
            disabledReason = when {
                !enabled -> reason
                group.groupedLight == null -> "This group has no grouped light to control"
                else -> null
            },
        )
    }

    /** Whether the user may mutate through this connection, and the spoken reason if not. */
    fun interaction(connection: ConnectionState): Pair<Boolean, String?> = when (connection) {
        ConnectionState.Connected, ConnectionState.Connecting, is ConnectionState.Stale -> true to null
        ConnectionState.Offline -> false to "Bridge offline. Controls resume when it reconnects."
        ConnectionState.Revoked -> false to "This app's access was removed on the bridge. Pair again in Settings."
        is ConnectionState.Error -> false to errorCopy(connection.reason)
    }

    fun connectionRow(
        bridgeId: BridgeId,
        connection: ConnectionState,
        nowMillis: Long,
        multi: Boolean,
    ): ConnectionRowUi {
        val label = bridgeLabel(bridgeId, multi)
        return when (connection) {
            ConnectionState.Connecting -> ConnectionRowUi(label, "Connecting", ConnectionTone.WORKING)
            ConnectionState.Connected -> ConnectionRowUi(label, "Connected", ConnectionTone.LIVE)
            is ConnectionState.Stale -> ConnectionRowUi(
                label,
                "Stale ${staleFor(nowMillis - connection.sinceEpochMillis)}",
                ConnectionTone.STALE,
                "Showing the last known state. Controls still work.",
            )
            ConnectionState.Offline -> ConnectionRowUi(label, "Offline", ConnectionTone.BLOCKED, "Controls paused until the bridge is reachable.")
            ConnectionState.Revoked -> ConnectionRowUi(label, "Access removed", ConnectionTone.BLOCKED, "Pair again from Settings to restore control.")
            is ConnectionState.Error -> ConnectionRowUi(label, "Error", ConnectionTone.BLOCKED, errorCopy(connection.reason))
        }
    }

    /** Bridge label for Home. Never the full id; the last four characters only when disambiguating. */
    fun bridgeLabel(bridgeId: BridgeId, multi: Boolean): String =
        if (multi) "Bridge …${bridgeId.value.takeLast(4)}" else "Bridge"

    fun staleFor(elapsedMillis: Long): String {
        val minutes = (elapsedMillis.coerceAtLeast(0) / 60_000L)
        return when {
            minutes < 1 -> "for under a minute"
            minutes < 60 -> "for $minutes min"
            else -> "for ${minutes / 60} h"
        }
    }

    private fun errorCopy(reason: SessionErrorReason): String = when (reason) {
        SessionErrorReason.UNREACHABLE -> "Couldn't reach the bridge. Check that it's powered and on this network."
        SessionErrorReason.TLS_IDENTITY -> "Couldn't verify this bridge's identity. Controls are paused."
        SessionErrorReason.BRIDGE_REJECTED -> "The bridge rejected the last request. Try again in a moment."
        SessionErrorReason.LOCAL_STORAGE -> "Couldn't read this bridge's saved data on this device."
    }
}
