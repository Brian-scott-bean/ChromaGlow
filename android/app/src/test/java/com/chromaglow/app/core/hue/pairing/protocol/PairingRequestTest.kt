package com.chromaglow.app.core.hue.pairing.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class PairingRequestTest {

    @Test
    fun createUserBody_isExactlyDeviceTypeOnly() {
        assertEquals("""{"devicetype":"chromaglow#android"}""", PairingRequest.createUserBody())
    }

    @Test
    fun deviceType_const_isChromaglowAndroid() {
        assertEquals("chromaglow#android", PairingRequest.DEVICE_TYPE)
    }

    @Test
    fun createUserBody_neverEmitsGenerateClientKey() {
        assertFalse(PairingRequest.createUserBody().contains("generateclientkey"))
    }

    @Test
    fun createUserBody_neverEmitsClientKey() {
        assertFalse(PairingRequest.createUserBody().contains("clientkey"))
    }
}
