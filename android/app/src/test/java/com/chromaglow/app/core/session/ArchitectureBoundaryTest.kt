package com.chromaglow.app.core.session

import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File

/**
 * 11. The transport mutation boundary is architecturally enforced at the dependency level, not by
 * a text grep over method names:
 *  - only the core/session tree and the transport package itself may reference `HueClipClient`
 *    (the only holder of the outbound mutation primitive `putResource`);
 *  - the feature, ui and app trees never import `core.hue.rest` or `core.hue.sse`;
 *  - production core/session code never uses Thread.sleep / runBlocking / GlobalScope.
 * Runs against the production source tree of this module (Gradle's working dir is the module).
 */
class ArchitectureBoundaryTest {

    private val root = File("src/main/java/com/chromaglow/app")

    private fun kotlinFiles(): List<File> = root.walkTopDown().filter { it.isFile && it.extension == "kt" }.toList()

    private fun rel(f: File) = f.relativeTo(root).path

    @Test
    fun productionTreeIsPresent() {
        assertTrue("expected production sources at ${root.absolutePath}", root.isDirectory)
    }

    @Test
    fun onlySessionAndTransportMayReferenceTheClipClient() {
        val offenders = kotlinFiles().filter { f ->
            val path = rel(f)
            val allowed = path.startsWith("core/session/") || path.startsWith("core/hue/rest/")
            !allowed && f.readText().contains("HueClipClient")
        }
        if (offenders.isNotEmpty()) fail("HueClipClient referenced outside core/session and core/hue/rest: ${offenders.map(::rel)}")
    }

    /**
     * A-03 / D-05: the boundary is un-bypassable, not merely un-imported. ANY occurrence (fully
     * qualified references included) of a transport/credential/composition-root token in feature,
     * ui, data or the router shell fails; only app/LiveAppGraph.kt (the composition root) is exempt.
     */
    @Test
    fun featureUiDataAndShellNeverReferenceTransportCredentialsOrTheCompositionRoot() {
        val tokens = listOf("HueClipClient", "ClipWriteBody", "putResource", "core.hue.rest", "core.hue.sse", "core.credentials", "app.LiveAppGraph", ".environment")
        // CHARLES QUESTION for Adam: feature/setup/SetupViewModel.kt reaches LiveAppGraph.get(ctx).pairingWorkflow
        // (Adam-owned, pre-existing). It is exempted for that ONE token only so the guard can land; the
        // exemption should disappear when the workflow is injected instead.
        val knownCompositionRootAccess = mapOf("feature/setup/SetupViewModel.kt" to setOf("app.LiveAppGraph"))
        val offenders = kotlinFiles().mapNotNull { f ->
            val path = rel(f)
            val guarded = path.startsWith("feature/") || path.startsWith("ui/") || path.startsWith("data/") || path == "app/ChromaGlowApp.kt"
            if (!guarded) return@mapNotNull null
            val text = f.readText()
            val hits = tokens.filter { text.contains(it) } - knownCompositionRootAccess[path].orEmpty()
            if (hits.isEmpty()) null else "$path -> $hits"
        }
        if (offenders.isNotEmpty()) fail("boundary bypass: $offenders")
    }

    @Test
    fun sessionEnvironmentIsNotReachableFromOutsideCore() {
        val source = File(root, "core/session/DefaultBridgeSession.kt").readText()
        assertTrue("DefaultBridgeSession.environment must be internal", source.contains("internal val environment"))
    }

    @Test
    fun sessionProductionCodeHasNoBlockingOrGlobalCoroutines() {
        val forbidden = listOf("Thread.sleep", "runBlocking", "GlobalScope")
        val offenders = kotlinFiles().filter { f ->
            rel(f).startsWith("core/session/") && f.readLines().any { line ->
                val code = line.substringBefore("//")
                forbidden.any { code.contains(it) }
            }
        }
        if (offenders.isNotEmpty()) fail("blocking/global coroutine use in core/session: ${offenders.map(::rel)}")
    }
}
