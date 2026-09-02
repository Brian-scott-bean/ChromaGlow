package com.chromaglow.app.core.session

/**
 * THE single outbound mutation authority for one bridge. Owns: capability refusal, the optimistic
 * overlay and field-aware pending fences, latest-wins coalescing, per-bridge pacing, the
 * [RiseLedger] safety chokepoint, the [EffectSafetyRegister] gate, and rollback-by-token.
 *
 * Binding invariant: no production feature/session path sends an outbound Hue mutation except
 * through this interface (the transport's `putResource` is referenced nowhere else; enforced by
 * ArchitectureBoundaryTest).
 */
interface MutationCoordinator {
    suspend fun submit(mutation: LiveMutation): MutationOutcome
}
