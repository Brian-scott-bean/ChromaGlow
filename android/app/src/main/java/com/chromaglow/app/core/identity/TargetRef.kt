package com.chromaglow.app.core.identity

/**
 * The exact target a UI callback or navigation argument addresses. Feature code never passes a
 * bare resource id: a live target carries its full bridge-qualified [ResourceKey]; a demo target
 * carries a [DemoTargetId] from the separate demo domain.
 */
sealed interface TargetRef {
    data class Live(val key: ResourceKey) : TargetRef
    data class Demo(val id: DemoTargetId) : TargetRef
}
