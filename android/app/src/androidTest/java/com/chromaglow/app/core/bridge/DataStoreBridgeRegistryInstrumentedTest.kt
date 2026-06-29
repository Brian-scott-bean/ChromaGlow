package com.chromaglow.app.core.bridge

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * Instrumented test for the production [DataStoreBridgeRegistry.create] path. Proves the metadata
 * file is created under `noBackupFilesDir` and round-trips on a real device. A single registry
 * instance is used because DataStore forbids two active instances over the same file in a process.
 */
@RunWith(AndroidJUnit4::class)
class DataStoreBridgeRegistryInstrumentedTest {

    private val recordA = PairedBridgeRecord("001788FFFE112233", "Bridge A", "192.168.1.10", 443, true)
    private val recordB = PairedBridgeRecord("AABBCCDDEEFF0011", "Bridge B", "192.168.1.11", 443, false)

    @Test
    fun create_persistsUnderNoBackupFilesDir_andRoundTrips() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val expectedFile = File(context.noBackupFilesDir, DataStoreBridgeRegistry.FILE_NAME)
        // Start from a clean slate (nothing holds the file before the first create()).
        expectedFile.delete()

        val registry = DataStoreBridgeRegistry.create(context)
        try {
            assertEquals(BridgeRegistryResult.Success(Unit), registry.upsert(recordA))
            registry.upsert(recordB)

            assertTrue("metadata file must live in noBackupFilesDir", expectedFile.exists())

            val bridges = registry.bridges()
            assertTrue(bridges is BridgeRegistryResult.Success)
            assertEquals(
                setOf(recordA, recordB),
                (bridges as BridgeRegistryResult.Success).value.toSet(),
            )

            assertEquals(BridgeRegistryResult.Success(Unit), registry.remove(recordA.bridgeId))
            assertEquals(
                listOf(recordB),
                (registry.bridges() as BridgeRegistryResult.Success).value,
            )
        } finally {
            // Leave no paired metadata behind for other tests.
            registry.remove(recordA.bridgeId)
            registry.remove(recordB.bridgeId)
        }
    }
}
