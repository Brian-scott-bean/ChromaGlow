package com.chromaglow.app.core.bridge

import android.content.Context
import androidx.datastore.core.CorruptionException
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import kotlinx.coroutines.flow.first
import java.io.File
import java.io.IOException

/**
 * [BridgeRegistry] backed by a Preferences DataStore.
 *
 * The records are stored as a single JSON-array string ([PairedBridgeCodec]) under one preference
 * key. In production the DataStore file lives in the app's `noBackupFilesDir`, so non-secret bridge
 * routing metadata is excluded from cloud/auto backup (mirroring the credential store) and never
 * surfaces in a backup transport. No token is ever read or written here — secrets stay in the
 * Keystore-backed credential store.
 *
 * Construct production instances with [create]; tests inject a DataStore over a temp file via
 * [forDataStore].
 */
class DataStoreBridgeRegistry internal constructor(
    private val dataStore: DataStore<Preferences>,
) : BridgeRegistry {

    override suspend fun bridges(): BridgeRegistryResult<List<PairedBridgeRecord>> {
        val preferences = try {
            dataStore.data.first()
        } catch (cause: CorruptionException) {
            return BridgeRegistryResult.Corrupt
        } catch (cause: IOException) {
            return BridgeRegistryResult.Failure(cause)
        }
        val raw = preferences[RECORDS_KEY] ?: return BridgeRegistryResult.Success(emptyList())
        val recovered = try {
            PairedBridgeCodec.decodeRecoverable(raw)
        } catch (cause: MalformedMetadataException) {
            return BridgeRegistryResult.Corrupt
        }
        // Per-element recovery: damaged entries are dropped and the readable ones are returned.
        // Only a store with entries and NOTHING readable is reported as Corrupt.
        if (recovered.records.isEmpty() && recovered.skipped > 0) return BridgeRegistryResult.Corrupt
        return BridgeRegistryResult.Success(recovered.records)
    }

    override suspend fun upsert(record: PairedBridgeRecord): BridgeRegistryResult<Unit> =
        mutate { current ->
            // Replace any existing record with the same canonical id; otherwise append.
            current.filterNot { it.bridgeId == record.bridgeId } + record
        }

    override suspend fun remove(bridgeId: String): BridgeRegistryResult<Unit> =
        mutate { current -> current.filterNot { it.bridgeId == bridgeId } }

    override suspend fun clear(): BridgeRegistryResult<Unit> =
        mutate { emptyList() }

    /**
     * Authoritatively rewrites the stored list. Readable entries of a partially damaged blob are
     * preserved through the write (per-element recovery); a blob with no readable root is treated
     * as empty so writes — re-pairing after damage, or forgetting to clear corruption — always
     * make progress. IO errors are surfaced as [BridgeRegistryResult.Failure].
     */
    private suspend fun mutate(
        transform: (List<PairedBridgeRecord>) -> List<PairedBridgeRecord>,
    ): BridgeRegistryResult<Unit> =
        try {
            dataStore.edit { preferences ->
                val current = preferences[RECORDS_KEY]?.let { raw ->
                    runCatching { PairedBridgeCodec.decodeRecoverable(raw).records }
                        .getOrDefault(emptyList())
                } ?: emptyList()
                val next = transform(current)
                if (next.isEmpty()) {
                    preferences.remove(RECORDS_KEY)
                } else {
                    preferences[RECORDS_KEY] = PairedBridgeCodec.encode(next)
                }
            }
            BridgeRegistryResult.Success(Unit)
        } catch (cause: IOException) {
            BridgeRegistryResult.Failure(cause)
        }

    companion object {
        /** Preferences DataStore file name (the `.preferences_pb` extension is required). */
        internal const val FILE_NAME = "bridge_registry.preferences_pb"

        private val RECORDS_KEY = stringPreferencesKey("paired_bridges")

        /**
         * DataStore mandates a single active instance per file per process; a second instance over
         * the same file throws. The production registry is therefore a process-wide singleton so
         * every caller (e.g. the Setup view model and any other consumer) shares one DataStore.
         */
        @Volatile
        private var instance: DataStoreBridgeRegistry? = null

        /**
         * Production factory. Returns a process-wide singleton whose DataStore file lives under
         * [Context.getNoBackupFilesDir] so the non-secret routing metadata is excluded from device
         * backup. Safe to call repeatedly.
         */
        fun create(context: Context): DataStoreBridgeRegistry {
            return instance ?: synchronized(this) {
                instance ?: run {
                    val appContext = context.applicationContext
                    val dataStore = PreferenceDataStoreFactory.create(
                        produceFile = { File(appContext.noBackupFilesDir, FILE_NAME) },
                    )
                    DataStoreBridgeRegistry(dataStore).also { instance = it }
                }
            }
        }

        /** Test/injection seam: wrap an already-built DataStore (e.g. over a temp file). */
        fun forDataStore(dataStore: DataStore<Preferences>): DataStoreBridgeRegistry =
            DataStoreBridgeRegistry(dataStore)
    }
}
