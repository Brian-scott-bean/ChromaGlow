package com.chromaglow.app.core.session

import com.chromaglow.app.core.credentials.BridgeCredentialStore
import com.chromaglow.app.core.credentials.BridgeSecretResult
import com.chromaglow.app.core.hue.rest.ApplicationKey
import com.chromaglow.app.core.hue.rest.ApplicationKeyProvider
import com.chromaglow.app.core.identity.BridgeId
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.withContext

/** Whether a session has a usable key. Secret-free. */
sealed interface CredentialState {
    data object Loaded : CredentialState

    /** No token stored for this record: the approved NeedsRepair/unavailable state; zero network. */
    data object Absent : CredentialState

    /** Keystore/IO failure reading the token: same product state as Absent; the token is NOT deleted. */
    data object Unreadable : CredentialState

    /** Explicit 401/403 dropped the key from memory; the record and the stored token are kept. */
    data object Dropped : CredentialState
}

/**
 * The session's [ApplicationKeyProvider]: reads the token ONCE (on [ioDispatcher]) into an
 * [ApplicationKey], hands it to the transport per request, and [drop]s it from memory on
 * revocation. It never deletes anything from the store — Forget is the shell's explicit act.
 */
class SessionCredentials(
    private val bridgeId: BridgeId,
    private val store: BridgeCredentialStore,
    private val ioDispatcher: CoroutineDispatcher,
) : ApplicationKeyProvider {

    @Volatile
    private var key: ApplicationKey? = null

    @Volatile
    var state: CredentialState = CredentialState.Absent
        private set

    suspend fun load(): CredentialState {
        val result = withContext(ioDispatcher) {
            try {
                store.loadApiToken(bridgeId.value)
            } catch (e: RuntimeException) {
                BridgeSecretResult.Failure(e)
            }
        }
        state = when (result) {
            is BridgeSecretResult.Present -> {
                key = ApplicationKey.of(result.token)
                CredentialState.Loaded
            }
            BridgeSecretResult.Absent -> CredentialState.Absent
            is BridgeSecretResult.Failure -> CredentialState.Unreadable
        }
        return state
    }

    /** Wipe the in-memory key. Every later request fails with MissingCredentials and transmits nothing. */
    fun drop() {
        key?.clear()
        key = null
        state = CredentialState.Dropped
    }

    override fun applicationKey(): ApplicationKey? = key?.takeIf { !it.isCleared }

    /** Mask this session's own key wherever it appears in [line] (diagnostics hygiene, D-08). */
    fun redact(line: String): String {
        val k = key?.takeIf { !it.isCleared } ?: return line
        return k.withHeaderValue { value -> if (value.length >= 4 && line.contains(value)) line.replace(value, com.chromaglow.app.core.hue.rest.Redactor.MASK) else line }
    }
}
