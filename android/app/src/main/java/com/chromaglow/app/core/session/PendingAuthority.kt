package com.chromaglow.app.core.session

import com.chromaglow.app.core.identity.ResourceKey

/**
 * Field-aware optimistic authority for one bridge. A claim on (ResourceKey, FieldGroup) says
 * "the app's optimistic value for THIS field wins over incoming truth until [Claim.deadlineMillis]
 * or until it is released"; other fields of the same resource are untouched, so a pending
 * brightness never suppresses a colour event and a pending effect never suppresses on/off.
 *
 * Keys are full bridge-qualified [ResourceKey]s: the same rid on another bridge or of another
 * type is a different claim (D-07). Every claim carries the token that made it and the prior
 * truth so rollback is by token: a failure for an older token never clobbers a newer write.
 * An authoritative load re-applies every unexpired claim on top of the loaded snapshot (B-01).
 */
class PendingAuthority {
    class Claim(
        val token: MutationToken,
        val deadlineMillis: Long,
        /** The truth BEFORE the first overlay of a chain: applied on rollback. */
        val prior: BridgeSnapshot,
    )

    private val claims = HashMap<Pair<ResourceKey, FieldGroup>, Claim>()

    @Synchronized
    fun claim(key: ResourceKey, field: FieldGroup, token: MutationToken, deadlineMillis: Long, prior: BridgeSnapshot) {
        val existing = claims[key to field]
        // A newer claim keeps the OLDEST prior so a chain of overlays rolls back to the truth,
        // but is owned by the newest token.
        claims[key to field] = Claim(token, maxOf(deadlineMillis, existing?.deadlineMillis ?: 0L), existing?.prior ?: prior)
    }

    /** Push the deadline out (stamped again at SEND time so a held/paced write is still fenced — B-09). */
    @Synchronized
    fun extend(key: ResourceKey, field: FieldGroup, token: MutationToken, deadlineMillis: Long) {
        val c = claims[key to field] ?: return
        if (c.token != token || deadlineMillis <= c.deadlineMillis) return
        claims[key to field] = Claim(c.token, deadlineMillis, c.prior)
    }

    @Synchronized
    fun isPending(key: ResourceKey, field: FieldGroup, nowMillis: Long): Boolean {
        val c = claims[key to field] ?: return false
        if (nowMillis > c.deadlineMillis) {
            claims.remove(key to field)
            return false
        }
        return true
    }

    @Synchronized
    fun owner(key: ResourceKey, field: FieldGroup): MutationToken? = claims[key to field]?.token

    /** Release only if [token] still owns the claim. Returns the claim when released. */
    @Synchronized
    fun release(key: ResourceKey, field: FieldGroup, token: MutationToken): Claim? {
        val c = claims[key to field] ?: return null
        if (c.token != token) return null
        claims.remove(key to field)
        return c
    }

    /** Take the claim for rollback only if [token] still owns it; a stale failure returns null. */
    fun takeForRollback(key: ResourceKey, field: FieldGroup, token: MutationToken): Claim? = release(key, field, token)

    /** Restore exactly this claim's field from its recorded prior truth. */
    fun rollback(current: BridgeSnapshot, key: ResourceKey, field: FieldGroup, claim: Claim): BridgeSnapshot =
        FieldOverlay.copy(target = current, source = claim.prior, key = key, field = field)

    /**
     * Re-apply every unexpired claim from [current] (the optimistic snapshot) onto [loaded] (the
     * authoritative one), so a load landing mid-mutation never flickers the pending fields (B-01).
     */
    @Synchronized
    fun overlayPending(loaded: BridgeSnapshot, current: BridgeSnapshot, nowMillis: Long): BridgeSnapshot {
        claims.entries.removeIf { nowMillis > it.value.deadlineMillis }
        var out = loaded
        for ((slot, _) in claims) out = FieldOverlay.copy(target = out, source = current, key = slot.first, field = slot.second)
        return out
    }

    @Synchronized
    fun pendingCount(): Int = claims.size

    @Synchronized
    fun clear() = claims.clear()
}
