package com.chromaglow.app.core.hue.capability

/**
 * How much we actually know about an optional capability of a fetched resource.
 *
 * UNKNOWN is not UNSUPPORTED: a capability we have not read yet renders as CHECKING and is never
 * interactive, but it is never refused with "this light can't do that" either.
 */
enum class Evidence {
    /** The resource reports the capability and the value is readable. Interactive. */
    KNOWN,

    /** The authoritative fetched resource has no such block at all (e.g. a white-only lamp). */
    ABSENT,

    /** The block exists but excludes the requested value (e.g. an effect not in effect_values). */
    UNSUPPORTED,

    /** The block exists but its schema/value could not be read (e.g. CT without mirek_schema). */
    UNREADABLE,

    /** Not fetched yet, or fetch failed. Shown as CHECKING; never a refusal, never interactive. */
    UNKNOWN,
}

/**
 * A capability value paired with the evidence that justifies it. Only [Evidence.KNOWN] with a
 * non-null value is ever interactive; everything else is staged or hidden per the UI rules.
 */
data class Capability<out T>(val value: T?, val evidence: Evidence) {
    init {
        if (evidence == Evidence.KNOWN) require(value != null) { "KNOWN capability requires a value" }
        if (evidence != Evidence.KNOWN) require(value == null) { "only KNOWN carries a value" }
    }

    /** True only for KNOWN. The single gate for rendering a live control or admitting a write. */
    val isInteractive: Boolean get() = evidence == Evidence.KNOWN

    /** True when the UI should render a staged CHECKING placeholder instead of a control. */
    val isChecking: Boolean get() = evidence == Evidence.UNKNOWN || evidence == Evidence.UNREADABLE

    /** True when nothing is rendered for this capability at all (no fake control). */
    val isHidden: Boolean get() = evidence == Evidence.ABSENT || evidence == Evidence.UNSUPPORTED

    companion object {
        fun <T> known(value: T): Capability<T> = Capability(value, Evidence.KNOWN)
        fun <T> absent(): Capability<T> = Capability(null, Evidence.ABSENT)
        fun <T> unsupported(): Capability<T> = Capability(null, Evidence.UNSUPPORTED)
        fun <T> unreadable(): Capability<T> = Capability(null, Evidence.UNREADABLE)
        fun <T> unknown(): Capability<T> = Capability(null, Evidence.UNKNOWN)
    }
}
