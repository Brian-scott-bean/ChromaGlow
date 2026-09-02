package com.chromaglow.app.core.hue.pairing.transport

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HuePairingResultTest {

    @Test
    fun success_toString_redactsUsername_keepsBridgeId() {
        // L-31: the application key must never surface through toString() (logs, diagnostics,
        // assertion messages). The non-secret canonical bridge id stays visible.
        val success = HuePairingResult.Success(bridgeId = "001788FFFE112233", username = "appkey-SECRET-42")

        val rendered = success.toString()

        assertFalse(rendered.contains("appkey-SECRET-42"))
        assertFalse(rendered.contains("SECRET"))
        assertTrue(rendered.contains("001788FFFE112233"))
        assertTrue(rendered.contains("***"))
    }

    @Test
    fun success_equalityAndAccessors_areUnaffectedByRedaction() {
        val a = HuePairingResult.Success("001788FFFE112233", "appkey-1")
        val b = HuePairingResult.Success("001788FFFE112233", "appkey-1")

        assertEquals(a, b)
        assertEquals("appkey-1", a.username)
        assertFalse(a.isRetryable)
    }
}
