package com.chromaglow.app.core.credentials

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.FileOutputStream
import java.nio.charset.StandardCharsets
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.StandardCopyOption
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal const val MAX_BLOB_LENGTH =
    1 + Int.SIZE_BYTES + 32 + Int.SIZE_BYTES + 4096

class AndroidKeystoreBridgeCredentialStore(
    context: Context,
) : BridgeCredentialStore {
    private val appContext = context.applicationContext
    private val credentialsDir: File = resolveCredentialsDir(appContext)

    override fun saveApiToken(bridgeId: String, token: String) {
        val validatedBridgeId = BridgeCredentialAlias.validateBridgeId(bridgeId)
        require(token.isNotBlank()) { "token must not be blank" }
        val plaintext = token.toByteArray(StandardCharsets.UTF_8)
        // Precondition BEFORE any Keystore side effect (audit L-33): an oversize token would fail
        // at blob encoding after the key had already been created.
        require(plaintext.size <= MAX_TOKEN_BYTES) { "token length out of bounds" }

        synchronized(PROCESS_LOCK) {
            val blobPath = ciphertextFile(validatedBridgeId).toPath()
            if (Files.exists(blobPath, LinkOption.NOFOLLOW_LINKS)) {
                if (!Files.isRegularFile(blobPath, LinkOption.NOFOLLOW_LINKS)) {
                    throw IllegalStateException("Ciphertext path is not a regular file")
                }
            }

            // Atomic across key creation and blob write (audit L-33): if encrypt/write fails after a
            // NEW key was generated, the orphan key is removed so the store never holds a bare key
            // with no blob. A pre-existing key (overwrite path) is left untouched so a failed
            // overwrite keeps the previous credential readable.
            val keyExistedBefore = hasKeystoreKey(validatedBridgeId)
            val secretKey = loadOrCreateSecretKey(validatedBridgeId)
            try {
                val cipher = Cipher.getInstance(TRANSFORMATION)
                cipher.init(Cipher.ENCRYPT_MODE, secretKey)
                val iv = cipher.iv
                val ciphertext = cipher.doFinal(plaintext)
                val blob = encodeBlob(iv, ciphertext)
                writeBlobAtomically(validatedBridgeId, blob)
            } catch (failure: Throwable) {
                if (!keyExistedBefore) {
                    try {
                        deleteKeystoreKeyIfPresent(validatedBridgeId)
                    } catch (_: Exception) {
                        // Best-effort compensation; the original failure is what the caller sees.
                    }
                }
                throw failure
            }
        }
    }

    override fun loadApiToken(bridgeId: String): BridgeSecretResult {
        val validatedBridgeId = BridgeCredentialAlias.validateBridgeId(bridgeId)

        synchronized(PROCESS_LOCK) {
            val keyPresent = hasKeystoreKey(validatedBridgeId)
            val blobFile = ciphertextFile(validatedBridgeId)
            val blobPath = blobFile.toPath()
            val blobExists = Files.exists(blobPath, LinkOption.NOFOLLOW_LINKS)
            val blobIsRegularFile = Files.isRegularFile(blobPath, LinkOption.NOFOLLOW_LINKS)

            return when {
                !keyPresent && !blobExists -> BridgeSecretResult.Absent
                blobExists && !blobIsRegularFile ->
                    BridgeSecretResult.Failure(
                        IllegalStateException("Ciphertext path is not a regular file"),
                    )
                keyPresent xor blobIsRegularFile ->
                    BridgeSecretResult.Failure(
                        IllegalStateException("Keystore key and ciphertext blob are inconsistent"),
                    )
                else -> decryptBlob(validatedBridgeId, blobFile)
            }
        }
    }

    override fun deleteApiToken(bridgeId: String) {
        val validatedBridgeId = BridgeCredentialAlias.validateBridgeId(bridgeId)

        synchronized(PROCESS_LOCK) {
            val blobPath = ciphertextFile(validatedBridgeId).toPath()
            if (Files.exists(blobPath, LinkOption.NOFOLLOW_LINKS)) {
                if (!Files.isRegularFile(blobPath, LinkOption.NOFOLLOW_LINKS)) {
                    throw IllegalStateException("Ciphertext path is not a regular file")
                }
                Files.deleteIfExists(blobPath)
            }
            deleteKeystoreKeyIfPresent(validatedBridgeId)
        }
    }

    private fun decryptBlob(bridgeId: String, blobFile: File): BridgeSecretResult {
        return try {
            val blobLength = blobFile.length()
            if (blobLength <= 0L || blobLength > MAX_BLOB_LENGTH) {
                return BridgeSecretResult.Failure(
                    IllegalStateException("Ciphertext blob length out of bounds"),
                )
            }
            val blobBytes = blobFile.readBytes()
            val (iv, ciphertext) = decodeBlob(blobBytes)
            val secretKey = loadSecretKey(bridgeId)
                ?: return BridgeSecretResult.Failure(
                    IllegalStateException("Keystore key missing during decrypt"),
                )
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, secretKey, GCMParameterSpec(GCM_TAG_BITS, iv))
            val plaintext = cipher.doFinal(ciphertext)
            BridgeSecretResult.Present(String(plaintext, StandardCharsets.UTF_8))
        } catch (cause: Exception) {
            BridgeSecretResult.Failure(cause)
        }
    }

    private fun writeBlobAtomically(bridgeId: String, blob: ByteArray) {
        val targetFile = ciphertextFile(bridgeId)
        val tempFile = File.createTempFile("cred-", ".tmp", credentialsDir)
        try {
            FileOutputStream(tempFile).use { output ->
                output.write(blob)
                output.fd.sync()
            }
            val targetPath = targetFile.toPath()
            val tempPath = tempFile.toPath()
            try {
                Files.move(
                    tempPath,
                    targetPath,
                    StandardCopyOption.ATOMIC_MOVE,
                    StandardCopyOption.REPLACE_EXISTING,
                )
            } catch (_: AtomicMoveNotSupportedException) {
                Files.move(
                    tempPath,
                    targetPath,
                    StandardCopyOption.REPLACE_EXISTING,
                )
            }
        } finally {
            if (tempFile.exists()) {
                tempFile.delete()
            }
        }
    }

    private fun encodeBlob(iv: ByteArray, ciphertext: ByteArray): ByteArray {
        require(iv.size in 1..MAX_IV_LENGTH) { "IV length out of bounds" }
        require(ciphertext.size in 1..MAX_CIPHERTEXT_LENGTH) {
            "ciphertext length out of bounds"
        }
        val buffer = java.io.ByteArrayOutputStream(
            1 + Int.SIZE_BYTES + iv.size + Int.SIZE_BYTES + ciphertext.size,
        )
        DataOutputStream(buffer).use { output ->
            output.writeByte(BLOB_VERSION.toInt())
            output.writeInt(iv.size)
            output.write(iv)
            output.writeInt(ciphertext.size)
            output.write(ciphertext)
        }
        return buffer.toByteArray()
    }

    private fun decodeBlob(blob: ByteArray): Pair<ByteArray, ByteArray> {
        DataInputStream(blob.inputStream()).use { input ->
            val version = input.readUnsignedByte()
            if (version != BLOB_VERSION) {
                throw IllegalStateException("Unsupported blob version")
            }
            val ivLength = input.readInt()
            if (ivLength <= 0 || ivLength > MAX_IV_LENGTH) {
                throw IllegalStateException("IV length out of bounds")
            }
            val iv = ByteArray(ivLength)
            input.readFully(iv)
            val ciphertextLength = input.readInt()
            if (ciphertextLength <= 0 || ciphertextLength > MAX_CIPHERTEXT_LENGTH) {
                throw IllegalStateException("ciphertext length out of bounds")
            }
            val ciphertext = ByteArray(ciphertextLength)
            input.readFully(ciphertext)
            if (input.available() > 0) {
                throw IllegalStateException("Trailing blob bytes")
            }
            return iv to ciphertext
        }
    }

    private fun ciphertextFile(bridgeId: String): File {
        val fileName = BridgeCredentialAlias.ciphertextFileName(bridgeId)
        return File(credentialsDir, fileName)
    }

    private fun hasKeystoreKey(bridgeId: String): Boolean {
        val keyStore = openKeyStore()
        return keyStore.containsAlias(BridgeCredentialAlias.keystoreAlias(bridgeId))
    }

    private fun loadSecretKey(bridgeId: String): SecretKey? {
        val keyStore = openKeyStore()
        val alias = BridgeCredentialAlias.keystoreAlias(bridgeId)
        val entry = keyStore.getEntry(alias, null) as? KeyStore.SecretKeyEntry ?: return null
        return entry.secretKey
    }

    private fun loadOrCreateSecretKey(bridgeId: String): SecretKey {
        loadSecretKey(bridgeId)?.let { return it }

        val alias = BridgeCredentialAlias.keystoreAlias(bridgeId)
        val keyGenerator =
            KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        val spec =
            KeyGenParameterSpec.Builder(
                alias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(KEY_SIZE_BITS)
                .build()
        keyGenerator.init(spec)
        return keyGenerator.generateKey()
    }

    private fun deleteKeystoreKeyIfPresent(bridgeId: String) {
        val keyStore = openKeyStore()
        val alias = BridgeCredentialAlias.keystoreAlias(bridgeId)
        if (keyStore.containsAlias(alias)) {
            keyStore.deleteEntry(alias)
        }
    }

    private fun openKeyStore(): KeyStore {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE)
        keyStore.load(null)
        return keyStore
    }

    private companion object {
        private val PROCESS_LOCK = Any()

        const val CREDENTIALS_DIR_NAME = "credentials"
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val KEY_SIZE_BITS = 256
        const val GCM_TAG_BITS = 128
        const val BLOB_VERSION = 1
        const val MAX_IV_LENGTH = 32
        const val MAX_CIPHERTEXT_LENGTH = 4096

        /** Largest plaintext that still fits [MAX_CIPHERTEXT_LENGTH] with the 16-byte GCM tag. */
        const val MAX_TOKEN_BYTES = MAX_CIPHERTEXT_LENGTH - GCM_TAG_BITS / 8

        private fun resolveCredentialsDir(context: Context): File {
            val dir = File(context.noBackupFilesDir, CREDENTIALS_DIR_NAME)
            if (dir.exists()) {
                if (!dir.isDirectory) {
                    throw IllegalStateException("Credentials path is not a directory")
                }
                return dir
            }
            if (!dir.mkdirs() && !dir.isDirectory) {
                throw IllegalStateException("Failed to create credentials directory")
            }
            if (!dir.isDirectory) {
                throw IllegalStateException("Credentials path is not a directory")
            }
            return dir
        }
    }
}
