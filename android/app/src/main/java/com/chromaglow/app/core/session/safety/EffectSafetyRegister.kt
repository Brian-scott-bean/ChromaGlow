package com.chromaglow.app.core.session.safety

/**
 * Deny mechanism for bridge-run firmware effects. After the initiating PUT the bridge owns the
 * animation cadence and the app-side [RiseLedger] cannot constrain it, so an effect observed on
 * hardware violating the realized-output invariant is placed here: it is neither rendered as a
 * chip nor accepted by the coordinator until resolved. Empty by default; populated only from
 * recorded physical cadence evidence.
 */
interface EffectSafetyRegister {
    val denied: Set<String>

    fun isDenied(effectId: String): Boolean = effectId in denied
}

/** The shipped register. Add an effect id here ONLY with a recorded H12-C cadence finding. */
object DefaultEffectSafetyRegister : EffectSafetyRegister {
    override val denied: Set<String> = emptySet()
}
