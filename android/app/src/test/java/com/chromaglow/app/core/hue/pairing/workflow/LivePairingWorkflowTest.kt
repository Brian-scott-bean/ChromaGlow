package com.chromaglow.app.core.hue.pairing.workflow

import com.chromaglow.app.core.bridge.BridgeRegistry
import com.chromaglow.app.core.bridge.BridgeRegistryResult
import com.chromaglow.app.core.bridge.PairedBridgeRecord
import com.chromaglow.app.core.credentials.BridgeCredentialStore
import com.chromaglow.app.core.credentials.BridgeSecretResult
import com.chromaglow.app.core.hue.discovery.BridgeEndpoint
import com.chromaglow.app.core.hue.pairing.transport.HuePairingClient
import com.chromaglow.app.core.hue.pairing.transport.HuePairingResult
import com.chromaglow.app.core.hue.pairing.transport.PairingFailureReason
import com.chromaglow.app.core.hue.pairing.transport.PairingStage
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException
import java.util.concurrent.Executors
import kotlin.coroutines.CoroutineContext

@OptIn(ExperimentalCoroutinesApi::class)
class LivePairingWorkflowTest {

    private val bridgeId = "001788FFFE112233"
    private val username = "appkey-abc123"
    private val selected = BridgeEndpoint(name = "Living Room", host = "192.168.1.50", port = 80)
    private val pairedRecord = PairedBridgeRecord(bridgeId, "Living Room", "192.168.1.50", 443, true)

    private val io = UnconfinedTestDispatcher()

    // --- pair: success + transaction ----------------------------------------------------------

    @Test
    fun pair_success_savesTokenThenUpsertsRecord_returnsNonSecretRecord() = runTest {
        val client = FakeHuePairingClient(HuePairingResult.Success(bridgeId, username))
        val store = FakeCredentialStore()
        val registry = FakeBridgeRegistry()
        val workflow = LivePairingWorkflow(client, store, registry, io)

        val outcome = workflow.pair(selected)

        assertEquals(PairingOutcome.Paired(pairedRecord), outcome)
        // Token committed under the canonical id; metadata committed; result carries no token.
        assertEquals(username, store.tokens[bridgeId])
        assertEquals(listOf(pairedRecord), registry.records)
    }

    @Test
    fun pair_derivesHttpsPort443_fromSelectedNonHttpsPort() = runTest {
        val client = FakeHuePairingClient(HuePairingResult.Success(bridgeId, username))
        val workflow = LivePairingWorkflow(client, FakeCredentialStore(), FakeBridgeRegistry(), io)

        workflow.pair(selected)

        val used = requireNotNull(client.lastEndpoint)
        assertEquals(443, used.port)
        assertEquals("192.168.1.50", used.host)
        assertEquals("Living Room", used.name)
        // No identity hint is passed; the transport authenticates from the leaf.
        assertNull(client.lastHint)
    }

    @Test
    fun pair_transportThrows_becomesTypedFailure_andPersistsNothing() = runTest {
        // L-38: a defect below the (contractually non-throwing) transport must degrade to a typed,
        // UI-safe outcome rather than crashing the caller's coroutine scope.
        val throwing = object : HuePairingClient {
            override fun pair(endpoint: BridgeEndpoint, expectedBridgeId: String?): HuePairingResult =
                throw IllegalArgumentException("unexpected host")
        }
        val store = FakeCredentialStore()
        val registry = FakeBridgeRegistry()

        val outcome = LivePairingWorkflow(throwing, store, registry, io).pair(selected)

        assertEquals(PairingOutcome.Failed(PairingErrorReason.UNTRUSTED_OR_UNREACHABLE), outcome)
        assertTrue(store.tokens.isEmpty())
        assertTrue(registry.records.isEmpty())
    }

    // --- pair: retryable + terminal mapping ---------------------------------------------------

    @Test
    fun pair_linkButtonNotPressed_isRetryable_andPersistsNothing() = runTest {
        val client = FakeHuePairingClient(HuePairingResult.LinkButtonNotPressed)
        val store = FakeCredentialStore()
        val registry = FakeBridgeRegistry()

        val outcome = LivePairingWorkflow(client, store, registry, io).pair(selected)

        assertEquals(PairingOutcome.LinkButtonRequired, outcome)
        assertTrue(store.tokens.isEmpty())
        assertTrue(registry.records.isEmpty())
    }

    @Test
    fun pair_terminalFailures_mapToUiSafeReasons_andPersistNothing() = runTest {
        val cases = mapOf(
            PairingFailureReason.InvalidRequest to PairingErrorReason.INVALID_REQUEST,
            PairingFailureReason.IdentityMismatch to PairingErrorReason.IDENTITY_MISMATCH,
            PairingFailureReason.UnverifiableLeafIdentity to PairingErrorReason.IDENTITY_MISMATCH,
            PairingFailureReason.TransportError to PairingErrorReason.UNTRUSTED_OR_UNREACHABLE,
            PairingFailureReason.BridgeError(4, "x") to PairingErrorReason.BRIDGE_ERROR,
            PairingFailureReason.MalformedResponse(PairingStage.CONFIG, "y") to PairingErrorReason.BRIDGE_RESPONSE_INVALID,
            PairingFailureReason.ResponseTooLarge(PairingStage.CREATE_USER) to PairingErrorReason.BRIDGE_RESPONSE_INVALID,
            PairingFailureReason.UnexpectedHttpStatus(PairingStage.CONFIG, 500) to PairingErrorReason.BRIDGE_RESPONSE_INVALID,
        )
        for ((reason, expected) in cases) {
            val store = FakeCredentialStore()
            val registry = FakeBridgeRegistry()
            val client = FakeHuePairingClient(HuePairingResult.Failure(reason))

            val outcome = LivePairingWorkflow(client, store, registry, io).pair(selected)

            assertEquals("for $reason", PairingOutcome.Failed(expected), outcome)
            assertTrue("for $reason no token", store.tokens.isEmpty())
            assertTrue("for $reason no metadata", registry.records.isEmpty())
        }
    }

    // --- pair: persistence transaction failures -----------------------------------------------

    @Test
    fun pair_tokenSaveFails_returnsLocalPersistence_andWritesNoMetadata() = runTest {
        val client = FakeHuePairingClient(HuePairingResult.Success(bridgeId, username))
        val store = FakeCredentialStore().apply { failSave = true }
        val registry = FakeBridgeRegistry()

        val outcome = LivePairingWorkflow(client, store, registry, io).pair(selected)

        assertEquals(PairingOutcome.Failed(PairingErrorReason.LOCAL_PERSISTENCE), outcome)
        assertEquals(0, registry.upsertCount)
        assertTrue(registry.records.isEmpty())
    }

    @Test
    fun pair_metadataUpsertFails_compensatesByDeletingToken() = runTest {
        val client = FakeHuePairingClient(HuePairingResult.Success(bridgeId, username))
        val store = FakeCredentialStore()
        val registry = FakeBridgeRegistry().apply { failUpsert = true }

        val outcome = LivePairingWorkflow(client, store, registry, io).pair(selected)

        assertEquals(PairingOutcome.Failed(PairingErrorReason.LOCAL_PERSISTENCE), outcome)
        // Compensation: the just-saved token was rolled back, leaving no half-committed state.
        assertTrue(store.tokens.isEmpty())
        assertEquals(1, store.deleteCount)
        assertTrue(registry.records.isEmpty())
    }

    // --- restore --------------------------------------------------------------------------------

    @Test
    fun restore_recordWithReadableToken_isPaired() = runTest {
        val store = FakeCredentialStore().apply { tokens[bridgeId] = username }
        val registry = FakeBridgeRegistry().apply { records.add(pairedRecord) }

        val state = LivePairingWorkflow(noClient(), store, registry, io).restore()

        assertEquals(RestoredState.Paired(pairedRecord), state)
    }

    @Test
    fun restore_recordWithAbsentToken_needsRepair() = runTest {
        val registry = FakeBridgeRegistry().apply { records.add(pairedRecord) }

        val state = LivePairingWorkflow(noClient(), FakeCredentialStore(), registry, io).restore()

        assertEquals(RestoredState.NeedsRepair(pairedRecord), state)
    }

    @Test
    fun restore_recordWithUnreadableToken_needsRepair() = runTest {
        val store = FakeCredentialStore().apply { failLoad = true }
        val registry = FakeBridgeRegistry().apply { records.add(pairedRecord) }

        val state = LivePairingWorkflow(noClient(), store, registry, io).restore()

        assertEquals(RestoredState.NeedsRepair(pairedRecord), state)
    }

    @Test
    fun restore_emptyRegistry_isUnpaired() = runTest {
        val state = LivePairingWorkflow(noClient(), FakeCredentialStore(), FakeBridgeRegistry(), io).restore()

        assertEquals(RestoredState.Unpaired, state)
    }

    @Test
    fun restore_corruptOrFailingRegistry_isUnavailable() = runTest {
        val corrupt = FakeBridgeRegistry().apply { readResult = BridgeRegistryResult.Corrupt }
        assertEquals(
            RestoredState.Unavailable,
            LivePairingWorkflow(noClient(), FakeCredentialStore(), corrupt, io).restore(),
        )

        val failing = FakeBridgeRegistry().apply {
            readResult = BridgeRegistryResult.Failure(IOException("io"))
        }
        assertEquals(
            RestoredState.Unavailable,
            LivePairingWorkflow(noClient(), FakeCredentialStore(), failing, io).restore(),
        )
    }

    // --- forget ---------------------------------------------------------------------------------

    @Test
    fun forget_deletesTokenAndRecord_andIsIdempotent() = runTest {
        val store = FakeCredentialStore().apply { tokens[bridgeId] = username }
        val registry = FakeBridgeRegistry().apply { records.add(pairedRecord) }
        val workflow = LivePairingWorkflow(noClient(), store, registry, io)

        assertEquals(ForgetResult.Forgotten, workflow.forget(bridgeId))
        assertTrue(store.tokens.isEmpty())
        assertTrue(registry.records.isEmpty())

        // Re-forget is a no-op success (idempotent / retryable).
        assertEquals(ForgetResult.Forgotten, workflow.forget(bridgeId))
    }

    @Test
    fun forget_tokenDeleteFails_returnsCleanupFailed_andLeavesMetadata() = runTest {
        val store = FakeCredentialStore().apply { tokens[bridgeId] = username; failDelete = true }
        val registry = FakeBridgeRegistry().apply { records.add(pairedRecord) }

        val result = LivePairingWorkflow(noClient(), store, registry, io).forget(bridgeId)

        assertEquals(ForgetResult.CleanupFailed, result)
        // Token-first: when the token delete fails, metadata is left for a clean retry.
        assertEquals(0, registry.removeCount)
        assertEquals(listOf(pairedRecord), registry.records)
    }

    @Test
    fun forget_metadataRemoveFails_returnsCleanupFailed() = runTest {
        val store = FakeCredentialStore().apply { tokens[bridgeId] = username }
        val registry = FakeBridgeRegistry().apply { records.add(pairedRecord); failRemove = true }

        val result = LivePairingWorkflow(noClient(), store, registry, io).forget(bridgeId)

        assertEquals(ForgetResult.CleanupFailed, result)
    }

    // --- threading ------------------------------------------------------------------------------

    @Test
    fun pair_runsBlockingWorkOnInjectedDispatcher() = runTest {
        val executor = Executors.newSingleThreadExecutor()
        val recording = RecordingDispatcher(executor.asCoroutineDispatcher())
        try {
            val client = FakeHuePairingClient(HuePairingResult.Success(bridgeId, username))
            val workflow = LivePairingWorkflow(client, FakeCredentialStore(), FakeBridgeRegistry(), recording)

            workflow.pair(selected)

            // The blocking pairing + Keystore work was dispatched onto the injected IO dispatcher.
            assertTrue("expected work dispatched to injected dispatcher", recording.dispatches > 0)
        } finally {
            executor.shutdown()
        }
    }

    // --- fakes ----------------------------------------------------------------------------------

    private fun noClient(): HuePairingClient = FakeHuePairingClient(
        HuePairingResult.Failure(PairingFailureReason.TransportError),
    )

    private class FakeHuePairingClient(var result: HuePairingResult) : HuePairingClient {
        var lastEndpoint: BridgeEndpoint? = null
        var lastHint: String? = null
        var callCount = 0

        override fun pair(endpoint: BridgeEndpoint, expectedBridgeId: String?): HuePairingResult {
            callCount++
            lastEndpoint = endpoint
            lastHint = expectedBridgeId
            return result
        }
    }

    private class FakeCredentialStore : BridgeCredentialStore {
        val tokens = mutableMapOf<String, String>()
        var failSave = false
        var failDelete = false
        var failLoad = false
        var saveCount = 0
        var deleteCount = 0

        override fun saveApiToken(bridgeId: String, token: String) {
            saveCount++
            if (failSave) throw IllegalStateException("save failed")
            tokens[bridgeId] = token
        }

        override fun loadApiToken(bridgeId: String): BridgeSecretResult {
            if (failLoad) return BridgeSecretResult.Failure(IllegalStateException("load failed"))
            val token = tokens[bridgeId]
            return if (token != null) BridgeSecretResult.Present(token) else BridgeSecretResult.Absent
        }

        override fun deleteApiToken(bridgeId: String) {
            deleteCount++
            if (failDelete) throw IllegalStateException("delete failed")
            tokens.remove(bridgeId)
        }
    }

    private class FakeBridgeRegistry : BridgeRegistry {
        val records = mutableListOf<PairedBridgeRecord>()
        var readResult: BridgeRegistryResult<List<PairedBridgeRecord>>? = null
        var failUpsert = false
        var failRemove = false
        var failClear = false
        var upsertCount = 0
        var removeCount = 0
        var clearCount = 0

        override suspend fun bridges(): BridgeRegistryResult<List<PairedBridgeRecord>> =
            readResult ?: BridgeRegistryResult.Success(records.toList())

        override suspend fun upsert(record: PairedBridgeRecord): BridgeRegistryResult<Unit> {
            upsertCount++
            if (failUpsert) return BridgeRegistryResult.Failure(IOException("upsert failed"))
            records.removeAll { it.bridgeId == record.bridgeId }
            records.add(record)
            return BridgeRegistryResult.Success(Unit)
        }

        override suspend fun remove(bridgeId: String): BridgeRegistryResult<Unit> {
            removeCount++
            if (failRemove) return BridgeRegistryResult.Failure(IOException("remove failed"))
            records.removeAll { it.bridgeId == bridgeId }
            return BridgeRegistryResult.Success(Unit)
        }

        override suspend fun clear(): BridgeRegistryResult<Unit> {
            clearCount++
            if (failClear) return BridgeRegistryResult.Failure(IOException("clear failed"))
            records.clear()
            readResult = null
            return BridgeRegistryResult.Success(Unit)
        }
    }

    private class RecordingDispatcher(private val delegate: CoroutineDispatcher) : CoroutineDispatcher() {
        @Volatile
        var dispatches = 0

        override fun dispatch(context: CoroutineContext, block: Runnable) {
            dispatches++
            delegate.dispatch(context, block)
        }
    }
}
