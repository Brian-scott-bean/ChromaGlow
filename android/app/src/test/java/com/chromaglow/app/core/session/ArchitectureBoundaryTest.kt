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

    @Test
    fun featureUiAndAppNeverImportTransportOrStreamPackages() {
        val offenders = kotlinFiles().filter { f ->
            val path = rel(f)
            (path.startsWith("feature/") || path.startsWith("ui/") || path.startsWith("app/")) &&
                f.readLines().any { line ->
                    line.startsWith("import com.chromaglow.app.core.hue.rest") ||
                        line.startsWith("import com.chromaglow.app.core.hue.sse")
                }
        }
        if (offenders.isNotEmpty()) fail("feature/ui/app code imports transport packages: ${offenders.map(::rel)}")
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
