package com.chromaglow.app.core.bridge

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files

/**
 * JVM unit tests for [DataStoreBridgeRegistry], exercised against a real Preferences DataStore over
 * a temp file (the production [DataStoreBridgeRegistry.create] only differs by placing that file in
 * `noBackupFilesDir`, covered by the instrumented test). No Android framework is required.
 */
class DataStoreBridgeRegistryTest {

    private val recordsKey = stringPreferencesKey("paired_bridges")

    private val recordA = PairedBridgeRecord("001788FFFE112233", "Bridge A", "192.168.1.10", 443, true)
    private val recordB = PairedBridgeRecord("AABBCCDDEEFF0011", "Bridge B", "192.168.1.11", 443, false)

    private lateinit var tempDir: File

    @Before
    fun setUp() {
        tempDir = Files.createTempDirectory("bridge-registry-test").toFile()
    }

    @After
    fun tearDown() {
        tempDir.deleteRecursively()
    }

    @Test
    fun emptyStore_readsEmptyList() = runTest {
        withRegistry { registry, _ ->
            assertEquals(
                BridgeRegistryResult.Success(emptyList<PairedBridgeRecord>()),
                registry.bridges(),
            )
        }
    }

    @Test
    fun upsert_insertsThenReplacesBySameBridgeId() = runTest {
        withRegistry { registry, _ ->
            registry.upsert(recordA)
            registry.upsert(recordB)
            assertEquals(setOf(recordA, recordB), loadedBridges(registry).toSet())

            // Same canonical id, changed fields → replacement, not a duplicate.
            val updatedA = recordA.copy(host = "10.0.0.5", isActive = false)
            registry.upsert(updatedA)

            val all = loadedBridges(registry)
            assertEquals(2, all.size)
            assertTrue(all.contains(updatedA))
            assertTrue(all.none { it == recordA })
        }
    }

    @Test
    fun remove_isIdempotentAndRetryable() = runTest {
        withRegistry { registry, _ ->
            registry.upsert(recordA)
            registry.upsert(recordB)

            assertEquals(BridgeRegistryResult.Success(Unit), registry.remove(recordA.bridgeId))
            assertEquals(listOf(recordB), loadedBridges(registry))

            // Removing an absent id still succeeds (idempotent / retryable).
            assertEquals(BridgeRegistryResult.Success(Unit), registry.remove(recordA.bridgeId))
            assertEquals(listOf(recordB), loadedBridges(registry))
        }
    }

    @Test
    fun records_surviveStoreRecreationFromDisk() = runTest {
        val file = File(tempDir, DataStoreBridgeRegistry.FILE_NAME)

        // First "process": write records, then fully release the DataStore (cancel + join).
        val firstJob = SupervisorJob()
        val firstScope = CoroutineScope(Dispatchers.IO + firstJob)
        val first = DataStoreBridgeRegistry.forDataStore(dataStore(firstScope, file))
        first.upsert(recordA)
        first.upsert(recordB)
        firstJob.cancelAndJoin()

        // Second "process": a brand-new DataStore over the same file must read the persisted data.
        val secondJob = SupervisorJob()
        val secondScope = CoroutineScope(Dispatchers.IO + secondJob)
        val second = DataStoreBridgeRegistry.forDataStore(dataStore(secondScope, file))
        assertEquals(setOf(recordA, recordB), loadedBridges(second).toSet())
        secondJob.cancelAndJoin()
    }

    @Test
    fun corruptStoredMetadata_readsCorrupt() = runTest {
        withRegistry { registry, dataStore ->
            dataStore.edit { it[recordsKey] = "this is not json" }

            assertEquals(BridgeRegistryResult.Corrupt, registry.bridges())
        }
    }

    @Test
    fun upsert_overCorruptMetadata_recoversAuthoritatively() = runTest {
        withRegistry { registry, dataStore ->
            dataStore.edit { it[recordsKey] = "{ corrupt" }

            // A re-pair must still succeed and yield a clean, readable list.
            assertEquals(BridgeRegistryResult.Success(Unit), registry.upsert(recordA))
            assertEquals(listOf(recordA), loadedBridges(registry))
        }
    }

    @Test
    fun storedBlob_isTheNonSecretRecordListOnly() = runTest {
        withRegistry { registry, dataStore ->
            registry.upsert(recordA)

            val raw = dataStore.data.first()[recordsKey]
            // The persisted blob is the non-secret record list; it carries no credential field.
            assertTrue(raw != null && raw.contains(recordA.bridgeId))
            val lowered = raw!!.lowercase()
            assertTrue(!lowered.contains("token") && !lowered.contains("username"))
        }
    }

    // --- helpers ------------------------------------------------------------------------------

    private fun dataStore(scope: CoroutineScope, file: File): DataStore<Preferences> =
        PreferenceDataStoreFactory.create(scope = scope, produceFile = { file })

    private suspend fun loadedBridges(registry: DataStoreBridgeRegistry): List<PairedBridgeRecord> {
        val result = registry.bridges()
        assertTrue("expected Success, was $result", result is BridgeRegistryResult.Success)
        return (result as BridgeRegistryResult.Success).value
    }

    /** Runs [block] with a fresh registry over a temp file, releasing the DataStore afterward. */
    private suspend fun withRegistry(
        block: suspend (DataStoreBridgeRegistry, DataStore<Preferences>) -> Unit,
    ) {
        val job = SupervisorJob()
        val scope = CoroutineScope(Dispatchers.IO + job)
        val file = File(tempDir, "store-${System.identityHashCode(job)}.preferences_pb")
        val store = dataStore(scope, file)
        try {
            block(DataStoreBridgeRegistry.forDataStore(store), store)
        } finally {
            (job as Job).cancelAndJoin()
        }
    }
}
