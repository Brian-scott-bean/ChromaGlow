package com.chromaglow.app.core.session

import com.chromaglow.app.core.identity.ResourceKey

/**
 * Field-aware optimistic authority for one bridge. A claim on (ResourceKey, FieldGroup) says
 * "the app's optimistic value for THIS field wins over incoming events until [deadlineMillis]
 * or until it is released"; other fields of the same resource are untouched, so a pending
 * brightness never suppresses a colour event and a pending effect never suppresses on/off.
 *
 * Every claim carries the token that made it and the prior value so rollback is by token: a
 * failure for an older token never clobbers a newer write.
 */
class PendingAuthority {
    data class Claim(
        val token: MutationToken,
        val deadlineMillis: Long,
        /** What the field looked like before the overlay; applied on rollback. */
        val restore: (BridgeSnapshot) -> BridgeSnapshot,
    )

    private val claims = HashMap<Pair<ResourceKey, FieldGroup>, Claim>()

    @Synchronized
    fun claim(key: ResourceKey, field: FieldGroup, token: MutationToken, deadlineMillis: Long, restore: (BridgeSnapshot) -> BridgeSnapshot) {
        val existing = claims[key to field]
        // A newer claim keeps the OLDEST prior so a chain of overlays rolls back to the truth,
        // but is owned by the newest token.
        claims[key to field] = Claim(token, deadlineMillis, existing?.restore ?: restore)
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
    @Synchronized
    fun takeForRollback(key: ResourceKey, field: FieldGroup, token: MutationToken): Claim? = release(key, field, token)

    @Synchronized
    fun clear() = claims.clear()
}
