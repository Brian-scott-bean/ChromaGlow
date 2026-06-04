package com.chromaglow.app.core.credentials

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.security.KeyStore
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class AndroidKeystoreBridgeCredentialStoreTest {
    private val context = ApplicationProvider.getApplicationContext<android.content.Context>()

    @Test
    fun missingLoad_returnsAbsent() {
        val bridgeId = syntheticBridgeId("missing")
        val store = AndroidKeystoreBridgeCredentialStore(context)

        try {
            val result = store.loadApiToken(bridgeId)
            assertEquals(BridgeSecretResult.Absent, result)
        } finally {
            store.deleteApiToken(bridgeId)
        }
    }

    @Test
    fun saveThenLoad_returnsPresentWithEqualRuntimeToken() {
        val bridgeId = syntheticBridgeId("save-load")
        val token = syntheticToken("save-load")
        val store = AndroidKeystoreBridgeCredentialStore(context)

        try {
            store.saveApiToken(bridgeId, token)
            val result = store.loadApiToken(bridgeId)

            assertTrue(result is BridgeSecretResult.Present)
            assertEquals(token, (result as BridgeSecretResult.Present).token)
        } finally {
            store.deleteApiToken(bridgeId)
        }
    }

    @Test
    fun overwrite_replacesPriorRuntimeToken() {
        val bridgeId = syntheticBridgeId("overwrite")
        val firstToken = syntheticToken("overwrite-first")
        val secondToken = syntheticToken("overwrite-second")
        val store = AndroidKeystoreBridgeCredentialStore(context)

        try {
            store.saveApiToken(bridgeId, firstToken)
            store.saveApiToken(bridgeId, secondToken)
            val result = store.loadApiToken(bridgeId)

            assertTrue(result is BridgeSecretResult.Present)
            assertEquals(secondToken, (result as BridgeSecretResult.Present).token)
        } finally {
            store.deleteApiToken(bridgeId)
        }
    }

    @Test
    fun deleteThenLoad_returnsAbsent() {
        val bridgeId = syntheticBridgeId("delete")
        val token = syntheticToken("delete")
        val store = AndroidKeystoreBridgeCredentialStore(context)

        try {
            store.saveApiToken(bridgeId, token)
            store.deleteApiToken(bridgeId)
            val result = store.loadApiToken(bridgeId)

            assertEquals(BridgeSecretResult.Absent, result)
        } finally {
            store.deleteApiToken(bridgeId)
        }
    }

    @Test
    fun delete_isIdempotent() {
        val bridgeId = syntheticBridgeId("idempotent")
        val store = AndroidKeystoreBridgeCredentialStore(context)

        try {
            store.deleteApiToken(bridgeId)
            store.deleteApiToken(bridgeId)
            val result = store.loadApiToken(bridgeId)

            assertEquals(BridgeSecretResult.Absent, result)
        } finally {
            store.deleteApiToken(bridgeId)
        }
    }

    @Test
    fun keyWithoutBlob_returnsFailure() {
        val bridgeId = syntheticBridgeId("key-without-blob")
        val token = syntheticToken("key-without-blob")
        val store = AndroidKeystoreBridgeCredentialStore(context)

        try {
            store.saveApiToken(bridgeId, token)
            val blobFile =
                context.noBackupFilesDir
                    .resolve("credentials")
                    .resolve(BridgeCredentialAlias.ciphertextFileName(bridgeId))
            assertTrue(blobFile.delete())

            val result = store.loadApiToken(bridgeId)

            assertTrue(result is BridgeSecretResult.Failure)
        } finally {
            store.deleteApiToken(bridgeId)
        }
    }

    @Test
    fun blobWithoutKey_returnsFailure() {
        val bridgeId = syntheticBridgeId("blob-without-key")
        val token = syntheticToken("blob-without-key")
        val store = AndroidKeystoreBridgeCredentialStore(context)

        try {
            store.saveApiToken(bridgeId, token)
            KeyStore.getInstance("AndroidKeyStore").apply {
                load(null)
                deleteEntry(BridgeCredentialAlias.keystoreAlias(bridgeId))
            }

            val result = store.loadApiToken(bridgeId)

            assertTrue(result is BridgeSecretResult.Failure)
        } finally {
            store.deleteApiToken(bridgeId)
        }
    }

    @Test
    fun saveWithDirectoryAtCiphertextPath_throws() {
        val bridgeId = syntheticBridgeId("save-dir")
        val store = AndroidKeystoreBridgeCredentialStore(context)
        val ciphertextPath = ciphertextPathForBridge(bridgeId)

        try {
            assertTrue(ciphertextPath.mkdir())
            try {
                store.saveApiToken(bridgeId, syntheticToken("save-dir"))
                fail("Expected IllegalStateException")
            } catch (_: IllegalStateException) {
            }
        } finally {
            removeCiphertextPath(ciphertextPath)
            deleteKeystoreAliasIfPresent(bridgeId)
        }
    }

    @Test
    fun loadWithDirectoryAtCiphertextPath_returnsFailure() {
        val bridgeId = syntheticBridgeId("load-dir")
        val store = AndroidKeystoreBridgeCredentialStore(context)
        val ciphertextPath = ciphertextPathForBridge(bridgeId)

        try {
            assertTrue(ciphertextPath.mkdir())
            val result = store.loadApiToken(bridgeId)

            assertTrue(result is BridgeSecretResult.Failure)
        } finally {
            removeCiphertextPath(ciphertextPath)
            deleteKeystoreAliasIfPresent(bridgeId)
        }
    }

    @Test
    fun deleteWithDirectoryAtCiphertextPath_throws() {
        val bridgeId = syntheticBridgeId("delete-dir")
        val store = AndroidKeystoreBridgeCredentialStore(context)
        val ciphertextPath = ciphertextPathForBridge(bridgeId)

        try {
            assertTrue(ciphertextPath.mkdir())
            try {
                store.deleteApiToken(bridgeId)
                fail("Expected IllegalStateException")
            } catch (_: IllegalStateException) {
            }
        } finally {
            removeCiphertextPath(ciphertextPath)
            deleteKeystoreAliasIfPresent(bridgeId)
        }
    }

    @Test
    fun oversizedCiphertextBlob_returnsFailure() {
        val bridgeId = syntheticBridgeId("oversized-blob")
        val token = syntheticToken("oversized-blob")
        val store = AndroidKeystoreBridgeCredentialStore(context)
        val ciphertextPath = ciphertextPathForBridge(bridgeId)

        try {
            store.saveApiToken(bridgeId, token)
            val oversized =
                ByteArray(MAX_BLOB_LENGTH + 1) { 0 }
            ciphertextPath.writeBytes(oversized)

            val result = store.loadApiToken(bridgeId)

            assertTrue(result is BridgeSecretResult.Failure)
        } finally {
            store.deleteApiToken(bridgeId)
        }
    }

    @Test
    fun ciphertextFileBytes_doNotContainRuntimeTokenUtf8Bytes() {
        val bridgeId = syntheticBridgeId("ciphertext")
        val token = syntheticToken("ciphertext")
        val store = AndroidKeystoreBridgeCredentialStore(context)

        try {
            store.saveApiToken(bridgeId, token)
            val blobFile =
                context.noBackupFilesDir
                    .resolve("credentials")
                    .resolve(BridgeCredentialAlias.ciphertextFileName(bridgeId))
            val blobBytes = blobFile.readBytes()
            val tokenBytes = token.toByteArray(Charsets.UTF_8)

            assertTrue(blobFile.isFile)
            assertFalse(containsSubsequence(blobBytes, tokenBytes))
        } finally {
            store.deleteApiToken(bridgeId)
        }
    }

    private fun ciphertextPathForBridge(bridgeId: String): File =
        context.noBackupFilesDir
            .resolve("credentials")
            .resolve(BridgeCredentialAlias.ciphertextFileName(bridgeId))

    private fun removeCiphertextPath(path: File) {
        if (path.isDirectory) {
            path.deleteRecursively()
        } else if (path.exists()) {
            path.delete()
        }
    }

    private fun deleteKeystoreAliasIfPresent(bridgeId: String) {
        KeyStore.getInstance("AndroidKeyStore").apply {
            load(null)
            val alias = BridgeCredentialAlias.keystoreAlias(bridgeId)
            if (containsAlias(alias)) {
                deleteEntry(alias)
            }
        }
    }

    private fun syntheticBridgeId(label: String): String =
        "test-$label-${UUID.randomUUID()}"

    private fun syntheticToken(label: String): String =
        "synthetic-token-$label-${UUID.randomUUID()}"

    private fun containsSubsequence(haystack: ByteArray, needle: ByteArray): Boolean {
        if (needle.isEmpty() || needle.size > haystack.size) {
            return false
        }
        for (start in 0..haystack.size - needle.size) {
            var matches = true
            for (index in needle.indices) {
                if (haystack[start + index] != needle[index]) {
                    matches = false
                    break
                }
            }
            if (matches) {
                return true
            }
        }
        return false
    }
}
