package com.chromaglow.app.core.hue.pairing.workflow

import com.chromaglow.app.core.bridge.BridgeRegistryResult
import com.chromaglow.app.core.bridge.PairedBridgeRecord
import com.chromaglow.app.core.credentials.BridgeCredentialStore
import com.chromaglow.app.core.credentials.BridgeSecretResult
import com.chromaglow.app.core.hue.pairing.transport.HuePairingResult
import com.chromaglow.app.core.hue.pairing.transport.PairingFailureReason
import com.chromaglow.app.testing.FakeBridgeRegistry
import com.chromaglow.app.testing.FakeCredentialStore
import com.chromaglow.app.testing.FakeHuePairingClient
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException

/** `restoreAll` is classify-only: it never deletes a token or a record, and never touches the network. */
class LivePairingWorkflowRestoreAllTest {

    private val io = UnconfinedTestDispatcher()
    private val a = PairedBridgeRecord("001788FFFE112233", "A", "192.168.1.10", 443, true)
    private val b = PairedBridgeRecord("AABBCCDDEEFF0011", "B", "192.168.1.11", 443, false)

    private fun workflow(registry: FakeBridgeRegistry, store: BridgeCredentialStore) =
        LivePairingWorkflow(FakeHuePairingClient(HuePairingResult.Failure(PairingFailureReason.TransportError)), store, registry, io)

    @Test
    fun classifiesPairedAndNeedsRepair_perRecord() = runTest {
        val registry = FakeBridgeRegistry().apply { records += a; records += b }
        val store = FakeCredentialStore().apply { tokens[a.bridgeId] = "tok-a" }

        val restored = workflow(registry, store).restoreAll()

        assertEquals(listOf(a), restored.paired)
        assertEquals(listOf(b), restored.needsRepair)
        assertTrue(!restored.metadataUnavailable)
        assertEquals(0, store.deleteCount)
    }

    @Test
    fun unreadableToken_isNeedsRepair_andIsNeverDeleted() = runTest {
        val registry = FakeBridgeRegistry().apply { records += a }
        val store = object : BridgeCredentialStore {
            var deletes = 0
            override fun saveApiToken(bridgeId: String, token: String) = Unit
            override fun loadApiToken(bridgeId: String): BridgeSecretResult = BridgeSecretResult.Failure(IllegalStateException("keystore"))
            override fun deleteApiToken(bridgeId: String) { deletes++ }
        }

        val restored = workflow(registry, store).restoreAll()

        assertEquals(listOf(a), restored.needsRepair)
        assertEquals(0, store.deletes)
    }

    @Test
    fun storeThatThrows_isNeedsRepair_notACrash() = runTest {
        val registry = FakeBridgeRegistry().apply { records += a }
        val store = object : BridgeCredentialStore {
            override fun saveApiToken(bridgeId: String, token: String) = Unit
            override fun loadApiToken(bridgeId: String): BridgeSecretResult = throw IllegalStateException("boom")
            override fun deleteApiToken(bridgeId: String) = Unit
        }
        assertEquals(listOf(a), workflow(registry, store).restoreAll().needsRepair)
    }

    @Test
    fun corruptOrFailingRegistry_isMetadataUnavailable_andTokensAreUntouched() = runTest {
        val store = FakeCredentialStore().apply { tokens[a.bridgeId] = "tok-a" }
        for (result in listOf(BridgeRegistryResult.Corrupt, BridgeRegistryResult.Failure(IOException("io")))) {
            val registry = FakeBridgeRegistry().apply { readResult = result }
            val restored = workflow(registry, store).restoreAll()
            assertTrue(restored.metadataUnavailable)
            assertTrue(restored.paired.isEmpty() && restored.needsRepair.isEmpty())
        }
        assertEquals("tok-a", store.tokens[a.bridgeId])
        assertEquals(0, store.deleteCount)
    }

    @Test
    fun emptyRegistry_isEmpty() = runTest {
        val restored = workflow(FakeBridgeRegistry(), FakeCredentialStore()).restoreAll()
        assertTrue(restored.isEmpty)
    }

    @Test
    fun restoreAll_agreesWithSingleBridgeRestore_onTheActiveRecord() = runTest {
        val registry = FakeBridgeRegistry().apply { records += a; records += b }
        val store = FakeCredentialStore().apply { tokens[a.bridgeId] = "tok-a" }
        val wf = workflow(registry, store)
        assertEquals(RestoredState.Paired(a), wf.restore())
        assertTrue(wf.restoreAll().paired.contains(a))
    }
}
