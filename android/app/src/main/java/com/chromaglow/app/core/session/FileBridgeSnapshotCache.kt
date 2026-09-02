package com.chromaglow.app.core.session

import com.chromaglow.app.core.identity.BridgeId
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.StandardCopyOption

/**
 * [BridgeSnapshotCache] over one file per bridge in [directory] (production: a folder under
 * `noBackupFilesDir`). Atomic write via temp file + rename; any read problem — missing, damaged,
 * wrong version, another bridge's snapshot — is a nonfatal [CacheReadResult.Discarded] or
 * [CacheReadResult.Miss]. The bytes are a [BridgeSnapshot] and nothing else (secret-free by
 * construction; pinned by a byte-scan test).
 */
class FileBridgeSnapshotCache(
    override val bridgeId: BridgeId,
    private val directory: File,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) : BridgeSnapshotCache {

    private val file: File get() = File(directory, "snapshot_${bridgeId.value}.v${BridgeSnapshotCache.FORMAT_VERSION}.json")

    override suspend fun read(): CacheReadResult = withContext(ioDispatcher) {
        val target = file
        if (!target.exists()) return@withContext CacheReadResult.Miss
        val text = try {
            target.readText(StandardCharsets.UTF_8)
        } catch (e: IOException) {
            return@withContext CacheReadResult.Discarded("unreadable: ${e::class.simpleName}")
        }
        try {
            CacheReadResult.Hit(SnapshotCodec.decode(text, bridgeId))
        } catch (e: SnapshotFormatException) {
            CacheReadResult.Discarded(e.message ?: "malformed")
        }
    }

    override suspend fun write(snapshot: BridgeSnapshot): CacheWriteResult = withContext(ioDispatcher) {
        if (snapshot.bridgeId != bridgeId) return@withContext CacheWriteResult.Failed("snapshot belongs to another bridge")
        try {
            if (!directory.isDirectory && !directory.mkdirs()) return@withContext CacheWriteResult.Failed("cannot create cache directory")
            val tmp = File(directory, file.name + ".tmp")
            tmp.writeText(SnapshotCodec.encodeToString(snapshot), StandardCharsets.UTF_8)
            try {
                Files.move(tmp.toPath(), file.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
            } catch (_: java.nio.file.AtomicMoveNotSupportedException) {
                Files.move(tmp.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING)
            }
            CacheWriteResult.Written
        } catch (e: IOException) {
            CacheWriteResult.Failed(e::class.simpleName ?: "io")
        } catch (e: SecurityException) {
            CacheWriteResult.Failed("security")
        }
    }

    override suspend fun clear() = withContext(ioDispatcher) {
        runCatching { file.delete() }
        runCatching { File(directory, file.name + ".tmp").delete() }
        Unit
    }
}
