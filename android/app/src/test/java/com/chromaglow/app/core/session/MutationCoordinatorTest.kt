package com.chromaglow.app.core.session

import com.chromaglow.app.core.hue.capability.CieXy
import com.chromaglow.app.core.hue.rest.ClipDocument
import com.chromaglow.app.core.hue.rest.ClipError
import com.chromaglow.app.core.hue.rest.ClipResult
import com.chromaglow.app.core.identity.ResourceId
import com.chromaglow.app.core.identity.ResourceKey
import com.chromaglow.app.core.identity.ResourceType
import com.chromaglow.app.core.session.safety.DefaultRiseLedger
import com.chromaglow.app.core.session.safety.DeliveryOutcome
import com.chromaglow.app.core.session.safety.EffectSafetyRegister
import com.chromaglow.app.core.session.safety.LedgerWriteKind
import com.chromaglow.app.testing.CoordinatorHarness
import com.chromaglow.app.testing.SpyLedger
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.runCurrent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MutationCoordinatorTest {

    private fun refused(o: MutationOutcome): RefusalReason {
        assertTrue("expected Refused, was $o", o is MutationOutcome.Refused)
        return (o as MutationOutcome.Refused).reason
    }

    private fun accepted(o: MutationOutcome): MutationToken {
        assertTrue("expected Accepted, was $o", o is MutationOutcome.Accepted)
        return (o as MutationOutcome.Accepted).token
    }

    // --- refusals -----------------------------------------------------------------------------

    @Test
    fun refuses_whenRevoked_orOffline_orTargetUnknown_withZeroWireActivity() = runTest {
        val h = CoordinatorHarness(this)
        h.connection.value = ConnectionState.Revoked
        assertEquals(RefusalReason.REVOKED, refused(h.coordinator.submit(LiveMutation.SetPower(h.colorLamp, true))))
        h.connection.value = ConnectionState.Offline
        assertEquals(RefusalReason.OFFLINE, refused(h.coordinator.submit(LiveMutation.SetPower(h.colorLamp, true))))
        h.connection.value = ConnectionState.Error(SessionErrorReason.TLS_IDENTITY)
        assertEquals(RefusalReason.OFFLINE, refused(h.coordinator.submit(LiveMutation.SetPower(h.colorLamp, true))))
        h.connection.value = ConnectionState.Connected
        assertEquals(RefusalReason.TARGET_UNKNOWN, refused(h.coordinator.submit(LiveMutation.SetPower(h.key(ResourceType.LIGHT, "ghost"), true))))
        advanceUntilIdle()
        assertEquals(0, h.transport.putCount)
    }

    @Test
    fun refuses_everyOptionalCapabilityThatIsNotKnown() = runTest {
        val h = CoordinatorHarness(this)
        assertEquals(RefusalReason.CAPABILITY_NOT_KNOWN, refused(h.coordinator.submit(LiveMutation.SetColor(h.unknownLamp, CieXy(0.3, 0.3)))))
        assertEquals(RefusalReason.CAPABILITY_NOT_KNOWN, refused(h.coordinator.submit(LiveMutation.SetColor(h.ctLamp, CieXy(0.3, 0.3)))))
        assertEquals("CT without a readable schema is CHECKING and refused", RefusalReason.CAPABILITY_NOT_KNOWN, refused(h.coordinator.submit(LiveMutation.SetColorTemperature(h.whiteLamp, 300))))
        assertEquals(RefusalReason.CAPABILITY_NOT_KNOWN, refused(h.coordinator.submit(LiveMutation.SelectEffect(h.colorLamp, "sparkle"))))
        assertEquals(RefusalReason.CAPABILITY_NOT_KNOWN, refused(h.coordinator.submit(LiveMutation.SelectEffect(h.unknownLamp, "candle"))))
        assertEquals(RefusalReason.CAPABILITY_NOT_KNOWN, refused(h.coordinator.submit(LiveMutation.StartTimedEffect(h.whiteLamp, TimedEffect.SUNRISE, 60_000))))
        assertEquals("gradient is PER_LIGHT_ONLY", RefusalReason.CAPABILITY_NOT_KNOWN, refused(h.coordinator.submit(LiveMutation.SetGradient(h.room, listOf(CieXy(0.3, 0.3)), null))))
        assertEquals(RefusalReason.CAPABILITY_NOT_KNOWN, refused(h.coordinator.submit(LiveMutation.SetGradient(h.colorLamp, listOf(CieXy(0.3, 0.3)), null))))
        assertEquals("timed effects on a group are all-or-nothing", RefusalReason.CAPABILITY_NOT_KNOWN, refused(h.coordinator.submit(LiveMutation.StartTimedEffect(h.room, TimedEffect.SUNSET, 60_000))))
        advanceUntilIdle()
        assertEquals(0, h.transport.putCount)
        assertEquals(h.initial, h.store.value)
    }

    @Test
    fun effectDeniedBySafetyRegister_isRefused_andNeverSent() = runTest {
        val register = object : EffectSafetyRegister { override val denied = setOf("cosmos") }
        val h = CoordinatorHarness(this, register = register)
        assertEquals(RefusalReason.EFFECT_DENIED_BY_SAFETY_REGISTER, refused(h.coordinator.submit(LiveMutation.SelectEffect(h.colorLamp, "cosmos"))))
        accepted(h.coordinator.submit(LiveMutation.SelectEffect(h.colorLamp, "candle")))
        advanceUntilIdle()
        assertEquals(1, h.transport.putCount)
    }

    // --- bodies + overlay + authority ---------------------------------------------------------

    @Test
    fun setPower_onALight_appliesTheOverlayImmediately_sendsOneGoldenPut_andClaimsOnlyThePowerField() = runTest {
        val h = CoordinatorHarness(this)
        val token = accepted(h.coordinator.submit(LiveMutation.SetPower(h.colorLamp, false)))
        assertFalse(h.light(h.colorLamp).isOn)
        assertTrue(h.authority.isPending(h.colorLamp, FieldGroup.POWER, h.clock.nowMillis()))
        assertFalse(h.authority.isPending(h.colorLamp, FieldGroup.COLOR, h.clock.nowMillis()))
        assertEquals(token, h.authority.owner(h.colorLamp, FieldGroup.POWER))
        advanceUntilIdle()
        val put = h.transport.puts().single()
        assertEquals(h.colorLamp.id, put.id)
        assertEquals("""{"on":{"on":false}}""", put.body.toString())
        assertEquals(listOf(RefreshReason.POST_MUTATION), h.refreshes)
    }

    @Test
    fun groupPowerAndBrightness_goToTheGroupedLight_asOneAtomicBody() = runTest {
        val h = CoordinatorHarness(this)
        accepted(h.coordinator.submit(LiveMutation.SetBrightness(h.room, 70)))
        advanceUntilIdle()
        val put = h.transport.puts().single()
        assertEquals(ResourceType.GROUPED_LIGHT, put.type)
        assertEquals("""{"on":{"on":true},"dimming":{"brightness":70}}""", put.body.toString())
        assertEquals(70.0, h.store.value.groupedLights.getValue(h.grouped).brightness!!, 0.0)
    }

    @Test
    fun colorTemperature_isClampedToTheLampsOwnSchema_withATransition() = runTest {
        val h = CoordinatorHarness(this)
        accepted(h.coordinator.submit(LiveMutation.SetColorTemperature(h.ctLamp, 9000)))
        advanceUntilIdle()
        assertEquals("""{"color_temperature":{"mirek":454},"dynamics":{"duration":400}}""", h.transport.puts().single().body.toString())
        assertEquals(454, h.light(h.ctLamp).mirek)
        assertEquals(true, h.light(h.ctLamp).mirekValid)
    }

    @Test
    fun colourAndColourTemperature_neverShareABody() = runTest {
        val h = CoordinatorHarness(this)
        accepted(h.coordinator.submit(LiveMutation.SetColor(h.colorLamp, CieXy(0.2, 0.4))))
        accepted(h.coordinator.submit(LiveMutation.SetColorTemperature(h.colorLamp, 300)))
        advanceUntilIdle()
        val bodies = h.transport.puts().map { it.body!! }
        assertEquals(2, bodies.size)
        for (b in bodies) assertFalse("color" in b.keys && "color_temperature" in b.keys)
        assertEquals("""{"color":{"xy":{"x":0.2,"y":0.4}},"dynamics":{"duration":400}}""", bodies[0].toString())
    }

    @Test
    fun effectsV2_carriesOnlyKnownParameters_andV1OnlyLampsGetTheV1Enum() = runTest {
        val h = CoordinatorHarness(this)
        accepted(h.coordinator.submit(LiveMutation.SelectEffect(h.colorLamp, "prism", EffectParameters(speed = 0.7, color = CieXy(0.2, 0.4), mirek = 9000))))
        accepted(h.coordinator.submit(LiveMutation.SelectEffect(h.ctLamp, "candle", EffectParameters(speed = 0.7, color = CieXy(0.2, 0.4), mirek = 300))))
        advanceUntilIdle()
        val puts = h.transport.puts()
        assertEquals("""{"effects_v2":{"action":{"effect":"prism","parameters":{"speed":0.7,"color":{"xy":{"x":0.2,"y":0.4}},"color_temperature":{"mirek":454}}}}}""", puts[0].body.toString())
        assertEquals("""{"effects":{"effect":"candle"}}""", puts[1].body.toString())
        assertEquals("prism", h.light(h.colorLamp).activeEffect)
    }

    @Test
    fun stopEffect_usesTheApiTheLampSpeaks() = runTest {
        val h = CoordinatorHarness(this)
        accepted(h.coordinator.submit(LiveMutation.StopEffect(h.colorLamp)))
        accepted(h.coordinator.submit(LiveMutation.StopEffect(h.ctLamp)))
        advanceUntilIdle()
        val puts = h.transport.puts()
        assertEquals("""{"effects_v2":{"action":{"effect":"no_effect"}}}""", puts[0].body.toString())
        assertEquals("""{"effects":{"effect":"no_effect"}}""", puts[1].body.toString())
    }

    @Test
    fun gradient_isCappedByPointsCapable_modeOnlyFromModeValues_andPassesThroughTheLedger() = runTest {
        val spy = SpyLedger(DefaultRiseLedger(com.chromaglow.app.core.identity.BridgeId("001788FFFE112233")))
        val h = CoordinatorHarness(this, ledgerFactory = { spy })
        val seven = (0 until 7).map { CieXy(it / 10.0, 0.3) }
        accepted(h.coordinator.submit(LiveMutation.SetGradient(h.stripLamp, seven.take(5), "not_a_mode")))
        advanceUntilIdle()
        val body = h.transport.puts().single().body!!
        assertEquals(5, body["gradient"].toString().split("\"color\"").size - 1)
        assertFalse(body["gradient"].toString().contains("mode"))
        assertEquals(1, spy.admits)
        assertEquals(5, h.light(h.stripLamp).gradientPoints.size)
        accepted(h.coordinator.submit(LiveMutation.SetGradient(h.stripLamp, seven.take(2), "random_pixelated")))
        advanceUntilIdle()
        assertTrue(h.transport.puts()[1].body.toString().contains("\"mode\":\"random_pixelated\""))
    }

    @Test
    fun sceneRecall_isGroupNative_andTheOverlayClearsSiblings() = runTest {
        val h = CoordinatorHarness(this)
        accepted(h.coordinator.submit(LiveMutation.RecallScene(h.scene)))
        assertTrue(h.store.value.scenes.getValue(h.scene).isActive)
        assertFalse(h.store.value.scenes.getValue(h.scene2).isActive)
        advanceUntilIdle()
        val put = h.transport.puts().single()
        assertEquals(ResourceType.SCENE, put.type)
        assertEquals("""{"recall":{"action":"active"}}""", put.body.toString())
    }

    // --- latest-wins, pacing, rollback ------------------------------------------------------------

    @Test
    fun fiftyUpdatesWhileAPutIsInFlight_collapseToOneMorePut_withTheLatestValue_andPacing() = runTest {
        val h = CoordinatorHarness(this)
        val gate = h.transport.holdNextPut()
        accepted(h.coordinator.submit(LiveMutation.SetBrightness(h.colorLamp, 10)))
        runCurrent()
        assertEquals(1, h.transport.putCount)
        for (i in 1..50) {
            accepted(h.coordinator.submit(LiveMutation.SetBrightness(h.colorLamp, 20 + i)))
            advanceTimeBy(6)
        }
        assertEquals(70.0, h.light(h.colorLamp).brightness!!, 0.0)
        gate.complete(ClipResult.Ok(ClipDocument(emptyList())))
        advanceUntilIdle()
        val puts = h.transport.puts()
        assertEquals(2, puts.size)
        assertEquals("""{"dimming":{"brightness":70}}""", puts[1].body.toString())
        assertTrue(puts[1].atMillis!! - puts[0].atMillis!! >= 100)
    }

    @Test
    fun anOlderFailure_neverClobbersANewerWrite() = runTest {
        val h = CoordinatorHarness(this)
        val gate = h.transport.holdNextPut()
        accepted(h.coordinator.submit(LiveMutation.SetBrightness(h.colorLamp, 30)))
        runCurrent()
        accepted(h.coordinator.submit(LiveMutation.SetBrightness(h.colorLamp, 70)))
        gate.complete(ClipResult.Err(ClipError.Http(500)))
        advanceUntilIdle()
        assertEquals("the newer overlay survives the older failure", 70.0, h.light(h.colorLamp).brightness!!, 0.0)
        assertEquals(2, h.transport.putCount)
    }

    @Test
    fun bridgeRejected_rollsBackByToken_andReleasesTheAuthority() = runTest {
        val h = CoordinatorHarness(this)
        h.transport.putResult = ClipResult.Err(ClipError.BridgeRejected(listOf("nope")))
        accepted(h.coordinator.submit(LiveMutation.SetBrightness(h.colorLamp, 90)))
        assertEquals(90.0, h.light(h.colorLamp).brightness!!, 0.0)
        advanceUntilIdle()
        assertEquals(50.0, h.light(h.colorLamp).brightness!!, 0.0)
        assertNull(h.authority.owner(h.colorLamp, FieldGroup.DIMMING))
        assertTrue(h.refreshes.isEmpty())
    }

    @Test
    fun authorityExpires_afterTheFenceWindow() = runTest {
        val h = CoordinatorHarness(this)
        accepted(h.coordinator.submit(LiveMutation.SetBrightness(h.colorLamp, 90)))
        advanceUntilIdle()
        assertTrue(h.authority.isPending(h.colorLamp, FieldGroup.DIMMING, h.clock.nowMillis()))
        assertFalse(h.authority.isPending(h.colorLamp, FieldGroup.DIMMING, h.clock.nowMillis() + 1_501))
    }

    @Test
    fun unauthorizedOnAPut_isReportedToTheSession_andRolledBack() = runTest {
        val h = CoordinatorHarness(this)
        h.transport.putResult = ClipResult.Err(ClipError.Unauthorized(403))
        accepted(h.coordinator.submit(LiveMutation.SetPower(h.colorLamp, false)))
        advanceUntilIdle()
        assertEquals(listOf(403), h.unauthorized)
        assertTrue(h.light(h.colorLamp).isOn)
    }

    // --- mixed-capability fan-out -------------------------------------------------------------

    @Test
    fun groupColour_fansOutOnlyToColourKnownMembers_paced() = runTest {
        val h = CoordinatorHarness(this)
        accepted(h.coordinator.submit(LiveMutation.SetColor(h.room, CieXy(0.2, 0.4))))
        advanceUntilIdle()
        val puts = h.transport.puts()
        assertEquals(setOf(h.colorLamp.id), puts.map { it.id }.toSet())
        accepted(h.coordinator.submit(LiveMutation.SetColorTemperature(h.room, 9000)))
        advanceUntilIdle()
        val ct = h.transport.puts().drop(1)
        assertEquals(setOf(h.colorLamp.id, h.ctLamp.id), ct.map { it.id }.toSet())
        assertTrue(ct.any { it.body.toString().contains("\"mirek\":454") })
        assertTrue(ct[1].atMillis!! - ct[0].atMillis!! >= 100)
    }

    @Test
    fun groupEffect_routesToTheCapableSubset_andRunUnverifiedNeverSends() = runTest {
        val h = CoordinatorHarness(this)
        accepted(h.coordinator.submit(LiveMutation.SelectEffect(h.room, "candle")))
        advanceUntilIdle()
        assertEquals(setOf(h.colorLamp.id, h.ctLamp.id), h.transport.puts().map { it.id }.toSet())
        // A room whose members report nothing at all → RunUnverified → refused, zero sends.
        val silent = h.key(ResourceType.ROOM, "silent")
        h.store.update { s -> s.copy(rooms = s.rooms + (silent to GroupState(silent, GroupKind.ROOM, "Silent", null, listOf(h.whiteLamp, h.unknownLamp), null))) }
        val before = h.transport.putCount
        assertEquals(RefusalReason.CAPABILITY_NOT_KNOWN, refused(h.coordinator.submit(LiveMutation.SelectEffect(silent, "candle"))))
        advanceUntilIdle()
        assertEquals(before, h.transport.putCount)
    }

    // --- safety chokepoint ----------------------------------------------------------------------

    @Test
    fun twoRisesOnTwoLamps_theSecondIsHeldUntilThePeriod_notMerelyPaced() = runTest {
        val h = CoordinatorHarness(this)
        h.store.update { s -> s.copy(lights = s.lights.mapValues { it.value.copy(isOn = false) }) }
        accepted(h.coordinator.submit(LiveMutation.SetPower(h.colorLamp, true)))
        accepted(h.coordinator.submit(LiveMutation.SetPower(h.ctLamp, true)))
        advanceUntilIdle()
        val puts = h.transport.puts()
        assertEquals(2, puts.size)
        assertTrue("second rise at +${puts[1].atMillis!! - puts[0].atMillis!!} ms", puts[1].atMillis!! - puts[0].atMillis!! >= 340)
    }

    @Test
    fun ambiguousTimeoutAfterTransmission_keepsTheRiseCommitted_soTheNextRiseWaitsTheWholePeriod() = runTest {
        val spy = SpyLedger(DefaultRiseLedger(com.chromaglow.app.core.identity.BridgeId("001788FFFE112233")))
        val h = CoordinatorHarness(this, ledgerFactory = { spy })
        h.store.update { s -> s.copy(lights = s.lights.mapValues { it.value.copy(isOn = false) }) }
        h.transport.putResults[ResourceType.LIGHT to h.colorLamp.id] = ClipResult.Err(ClipError.Timeout(afterTransmission = true))
        accepted(h.coordinator.submit(LiveMutation.SetPower(h.colorLamp, true)))
        advanceUntilIdle()
        assertEquals(listOf(DeliveryOutcome.AMBIGUOUS_AFTER_TRANSMISSION), spy.settles)
        accepted(h.coordinator.submit(LiveMutation.SetPower(h.ctLamp, true)))
        advanceUntilIdle()
        val puts = h.transport.puts()
        assertTrue(puts[1].atMillis!! - puts[0].atMillis!! >= 340)
    }

    @Test
    fun failureBeforeTransmission_releasesTheRise_soTheNextRiseOnlyWaitsForPacing() = runTest {
        val spy = SpyLedger(DefaultRiseLedger(com.chromaglow.app.core.identity.BridgeId("001788FFFE112233")))
        val h = CoordinatorHarness(this, ledgerFactory = { spy })
        h.store.update { s -> s.copy(lights = s.lights.mapValues { it.value.copy(isOn = false) }) }
        h.transport.putResults[ResourceType.LIGHT to h.colorLamp.id] = ClipResult.Err(ClipError.Timeout(afterTransmission = false))
        accepted(h.coordinator.submit(LiveMutation.SetPower(h.colorLamp, true)))
        advanceUntilIdle()
        assertEquals(listOf(DeliveryOutcome.FAILED_BEFORE_TRANSMISSION), spy.settles)
        assertFalse("rolled back", h.light(h.colorLamp).isOn)
        accepted(h.coordinator.submit(LiveMutation.SetPower(h.ctLamp, true)))
        advanceUntilIdle()
        val puts = h.transport.puts()
        val gap = puts[1].atMillis!! - puts[0].atMillis!!
        assertTrue("gap $gap", gap in 100..339)
    }

    @Test
    fun fieldAwareAuthority_pendingBrightnessDoesNotClaimColour_andPendingEffectDoesNotClaimPower() = runTest {
        val h = CoordinatorHarness(this)
        accepted(h.coordinator.submit(LiveMutation.SetBrightness(h.colorLamp, 90)))
        accepted(h.coordinator.submit(LiveMutation.SelectEffect(h.colorLamp, "candle")))
        val now = h.clock.nowMillis()
        assertTrue(h.authority.isPending(h.colorLamp, FieldGroup.DIMMING, now))
        assertTrue(h.authority.isPending(h.colorLamp, FieldGroup.EFFECT, now))
        assertFalse(h.authority.isPending(h.colorLamp, FieldGroup.COLOR, now))
        assertFalse(h.authority.isPending(h.colorLamp, FieldGroup.POWER, now))
        advanceUntilIdle()
    }

    @Test
    fun close_refusesFurtherSubmissions_andDropsQueuedWork() = runTest {
        val h = CoordinatorHarness(this)
        h.transport.holdNextPut()
        accepted(h.coordinator.submit(LiveMutation.SetBrightness(h.colorLamp, 90)))
        runCurrent()
        accepted(h.coordinator.submit(LiveMutation.SetBrightness(h.ctLamp, 90)))
        h.coordinator.close()
        assertEquals(RefusalReason.SESSION_CLOSED, refused(h.coordinator.submit(LiveMutation.SetPower(h.colorLamp, true))))
        advanceUntilIdle()
        assertEquals(1, h.transport.putCount)
    }

    // --- fix batch: E-03/B-02/B-03, E-04, E-05, E-07, E-08, E-09, E-10, B-09 ---------------------

    @Test
    fun b02_ambiguousTimeout_keepsTheOverlay_releasesAuthority_andSchedulesRefresh() = runTest {
        val h = CoordinatorHarness(this)
        h.transport.putResult = ClipResult.Err(ClipError.Timeout(afterTransmission = true))
        val token = accepted(h.coordinator.submit(LiveMutation.SetBrightness(h.colorLamp, 90)))
        advanceUntilIdle()
        assertEquals("the lamp may hold the new value: no rollback", 90.0, h.light(h.colorLamp).brightness!!, 0.0)
        assertNull("authority released so truth can reconcile", h.authority.owner(h.colorLamp, FieldGroup.DIMMING))
        assertEquals(listOf(RefreshReason.POST_MUTATION), h.refreshes)
        assertTrue(token.value > 0)
    }

    @Test
    fun e03_transportFailureAfterTransmission_settlesAmbiguous_andKeepsTheRiseCommitted() = runTest {
        val spy = SpyLedger(DefaultRiseLedger(com.chromaglow.app.core.identity.BridgeId("001788FFFE112233")))
        val h = CoordinatorHarness(this, ledgerFactory = { spy })
        h.store.update { s -> s.copy(lights = s.lights.mapValues { it.value.copy(isOn = false) }) }
        h.transport.putResults[ResourceType.LIGHT to h.colorLamp.id] = ClipResult.Err(ClipError.Transport(afterTransmission = true))
        accepted(h.coordinator.submit(LiveMutation.SetPower(h.colorLamp, true)))
        advanceUntilIdle()
        assertEquals(listOf(DeliveryOutcome.AMBIGUOUS_AFTER_TRANSMISSION), spy.settles)
        assertTrue("overlay kept", h.light(h.colorLamp).isOn)
        accepted(h.coordinator.submit(LiveMutation.SetPower(h.ctLamp, true)))
        advanceUntilIdle()
        val puts = h.transport.puts()
        assertTrue("next rise waits the whole period", puts[1].atMillis!! - puts[0].atMillis!! >= 340)
    }

    @Test
    fun e03_transportFailureBeforeTransmission_stillReleases_andRollsBack() = runTest {
        val spy = SpyLedger(DefaultRiseLedger(com.chromaglow.app.core.identity.BridgeId("001788FFFE112233")))
        val h = CoordinatorHarness(this, ledgerFactory = { spy })
        h.transport.putResults[ResourceType.LIGHT to h.colorLamp.id] = ClipResult.Err(ClipError.Transport(afterTransmission = false))
        accepted(h.coordinator.submit(LiveMutation.SetBrightness(h.colorLamp, 90)))
        advanceUntilIdle()
        assertEquals(listOf(DeliveryOutcome.FAILED_BEFORE_TRANSMISSION), spy.settles)
        assertEquals(50.0, h.light(h.colorLamp).brightness!!, 0.0)
    }

    @Test
    fun e05_rateLimited_isNotApplied_rollsBack_andTheRetriedRiseIsStillHeld() = runTest {
        val spy = SpyLedger(DefaultRiseLedger(com.chromaglow.app.core.identity.BridgeId("001788FFFE112233")))
        val h = CoordinatorHarness(this, ledgerFactory = { spy })
        h.store.update { s -> s.copy(lights = s.lights.mapValues { it.value.copy(brightness = 1.0) }) }
        h.transport.putResults[ResourceType.LIGHT to h.colorLamp.id] = ClipResult.Err(ClipError.RateLimited)
        accepted(h.coordinator.submit(LiveMutation.SetBrightness(h.colorLamp, 100)))
        advanceUntilIdle()
        assertEquals(listOf(DeliveryOutcome.NOT_APPLIED), spy.settles)
        assertEquals("rolled back: the lamp stayed dark", 1.0, h.light(h.colorLamp).brightness!!, 0.0)
        h.transport.putResults.remove(ResourceType.LIGHT to h.colorLamp.id)
        accepted(h.coordinator.submit(LiveMutation.SetBrightness(h.colorLamp, 100)))
        advanceUntilIdle()
        val puts = h.transport.puts()
        assertTrue("the real rise is held to the period from the 429'd stamp", puts[1].atMillis!! - puts[0].atMillis!! >= 340)
    }

    @Test
    fun bridgeRejected_isAmbiguousForTheLedger_butStillRollsBackAndReportsRejected() = runTest {
        // Frank residual: the LEDGER treats a 2xx-with-errors as ambiguous (stamp kept, wire unknown —
        // strictly more conservative), while the UI still rolls back and reports REJECTED_BY_BRIDGE
        // (the Failed/rolledBack event itself is pinned by mutationEvents_applied_failedRolledBack_*).
        val spy = SpyLedger(DefaultRiseLedger(com.chromaglow.app.core.identity.BridgeId("001788FFFE112233")))
        val h = CoordinatorHarness(this, ledgerFactory = { spy })
        h.store.update { s -> s.copy(lights = s.lights.mapValues { it.value.copy(isOn = false) }) }
        h.transport.putResults[ResourceType.LIGHT to h.colorLamp.id] = ClipResult.Err(ClipError.BridgeRejected(listOf("nope")))
        accepted(h.coordinator.submit(LiveMutation.SetPower(h.colorLamp, true)))
        advanceUntilIdle()
        assertEquals(listOf(DeliveryOutcome.AMBIGUOUS_AFTER_TRANSMISSION), spy.settles)
        assertFalse("the UI still rolls back a bridge refusal", h.light(h.colorLamp).isOn)
        // Conservative: the next rise on another lamp waits the whole period behind the ambiguous one.
        accepted(h.coordinator.submit(LiveMutation.SetPower(h.ctLamp, true)))
        advanceUntilIdle()
        val puts = h.transport.puts()
        assertTrue("gap ${puts[1].atMillis!! - puts[0].atMillis!!}", puts[1].atMillis!! - puts[0].atMillis!! >= 340)
    }

    @Test
    fun http5xx_isAmbiguous_butHttp4xx_isNotApplied() = runTest {
        val spy = SpyLedger(DefaultRiseLedger(com.chromaglow.app.core.identity.BridgeId("001788FFFE112233")))
        val h = CoordinatorHarness(this, ledgerFactory = { spy })
        h.transport.putResults[ResourceType.LIGHT to h.colorLamp.id] = ClipResult.Err(ClipError.Http(503))
        h.transport.putResults[ResourceType.LIGHT to h.ctLamp.id] = ClipResult.Err(ClipError.Http(404))
        accepted(h.coordinator.submit(LiveMutation.SetBrightness(h.colorLamp, 90)))
        accepted(h.coordinator.submit(LiveMutation.SetBrightness(h.ctLamp, 90)))
        advanceUntilIdle()
        assertEquals(listOf(DeliveryOutcome.AMBIGUOUS_AFTER_TRANSMISSION, DeliveryOutcome.NOT_APPLIED), spy.settles)
        assertEquals(90.0, h.light(h.colorLamp).brightness!!, 0.0)
        assertEquals(50.0, h.light(h.ctLamp).brightness!!, 0.0)
    }

    @Test
    fun e04_aLampInCtMode_isJudgedAsWhite_notByItsStaleBlueXy() = runTest {
        val spy = SpyLedger(DefaultRiseLedger(com.chromaglow.app.core.identity.BridgeId("001788FFFE112233")))
        val h = CoordinatorHarness(this, ledgerFactory = { spy })
        h.store.update { s -> s.copy(lights = s.lights + (h.ctModeLamp to s.lights.getValue(h.ctModeLamp).copy(brightness = 1.0))) }
        accepted(h.coordinator.submit(LiveMutation.SetBrightness(h.ctModeLamp, 100)))
        advanceUntilIdle()
        val frame = spy.writes.single().frame
        assertTrue("stale blue would score 0.07; CT mode must score as white (${frame.relativeLuminance})", frame.relativeLuminance > 0.9)
        assertFalse(frame.isSaturatedRed)
    }

    @Test
    fun e10_aStripIsJudgedByItsBrightestPoint() = runTest {
        val spy = SpyLedger(DefaultRiseLedger(com.chromaglow.app.core.identity.BridgeId("001788FFFE112233")))
        val h = CoordinatorHarness(this, ledgerFactory = { spy })
        accepted(h.coordinator.submit(LiveMutation.SetBrightness(h.redStrip, 100)))
        advanceUntilIdle()
        val frame = spy.writes.single().frame
        assertTrue("first point is blue (0.07); the white point (1.0) must win (${frame.relativeLuminance})", frame.relativeLuminance > 0.9)
    }

    @Test
    fun e07_effectAndTimedInitiationOnADarkLamp_areJudgedAsFullRises() = runTest {
        val spy = SpyLedger(DefaultRiseLedger(com.chromaglow.app.core.identity.BridgeId("001788FFFE112233")))
        val h = CoordinatorHarness(this, ledgerFactory = { spy })
        h.store.update { s -> s.copy(lights = s.lights.mapValues { it.value.copy(isOn = false) }) }
        accepted(h.coordinator.submit(LiveMutation.SelectEffect(h.colorLamp, "candle")))
        accepted(h.coordinator.submit(LiveMutation.StartTimedEffect(h.ctLamp, TimedEffect.SUNRISE, 900_000L)))
        advanceUntilIdle()
        assertEquals(setOf(LedgerWriteKind.INITIATION), spy.writes.map { it.kind }.toSet())
        assertTrue(spy.writes.all { it.frame.relativeLuminance == 1.0 })
        assertEquals(2, h.transport.putCount)
        val puts = h.transport.puts()
        assertTrue("second initiation is held to the period", puts[1].atMillis!! - puts[0].atMillis!! >= 340)
    }

    @Test
    fun e08_aTimedEffectShorterThanSixtySeconds_isRefused() = runTest {
        val h = CoordinatorHarness(this)
        assertEquals(RefusalReason.UNSAFE_DURATION, refused(h.coordinator.submit(LiveMutation.StartTimedEffect(h.colorLamp, TimedEffect.SUNRISE, 0L))))
        assertEquals(RefusalReason.UNSAFE_DURATION, refused(h.coordinator.submit(LiveMutation.StartTimedEffect(h.colorLamp, TimedEffect.SUNRISE, 59_999L))))
        accepted(h.coordinator.submit(LiveMutation.StartTimedEffect(h.colorLamp, TimedEffect.SUNRISE, 60_000L)))
        advanceUntilIdle()
        assertEquals(1, h.transport.putCount)
    }

    @Test
    fun e09_groupedAndSceneWrites_pacedAtOneSecond_perLightAtHundredMillis() = runTest {
        val h = CoordinatorHarness(this)
        accepted(h.coordinator.submit(LiveMutation.SetBrightness(h.room, 40)))
        accepted(h.coordinator.submit(LiveMutation.SetBrightness(h.room2, 40)))
        accepted(h.coordinator.submit(LiveMutation.SetBrightness(h.colorLamp, 40)))
        accepted(h.coordinator.submit(LiveMutation.SetBrightness(h.ctLamp, 40)))
        advanceUntilIdle()
        val puts = h.transport.puts()
        val grouped = puts.filter { it.type == ResourceType.GROUPED_LIGHT }
        val lights = puts.filter { it.type == ResourceType.LIGHT }
        assertEquals(2, grouped.size)
        assertTrue("grouped gap ${grouped[1].atMillis!! - grouped[0].atMillis!!}", grouped[1].atMillis!! - grouped[0].atMillis!! >= 1_000)
        assertTrue("light gap", lights[1].atMillis!! - lights[0].atMillis!! in 100..339)
    }

    @Test
    fun b09_theFenceIsReStampedAtSend_soAHeldWriteIsStillPendingWhenItLeaves() = runTest {
        val h = CoordinatorHarness(this)
        h.store.update { s -> s.copy(lights = s.lights.mapValues { it.value.copy(isOn = false) }) }
        val gate = h.transport.holdNextPut()
        accepted(h.coordinator.submit(LiveMutation.SetPower(h.colorLamp, true)))
        runCurrent()
        // Second rise is held ~340 ms behind the first; wait 1.4 s from submit, still before it can leave.
        accepted(h.coordinator.submit(LiveMutation.SetPower(h.ctLamp, true)))
        advanceTimeBy(1_400)
        gate.complete(ClipResult.Ok(ClipDocument(emptyList())))
        advanceUntilIdle()
        val sentAt = h.transport.putsTo(h.ctLamp.id).single().atMillis!!
        assertTrue("still pending shortly after send", h.authority.isPending(h.ctLamp, FieldGroup.POWER, sentAt + 1_000))
        assertFalse(h.authority.isPending(h.ctLamp, FieldGroup.POWER, sentAt + 1_600))
    }

    @Test
    fun mutationEvents_applied_failedRolledBack_failedNotRolledBack() = runTest {
        val h = CoordinatorHarness(this)
        val events = mutableListOf<MutationEvent>()
        val job = backgroundScope.launch(h.dispatcher) { h.env.mutationEvents.collect { events += it } }
        runCurrent()
        accepted(h.coordinator.submit(LiveMutation.SetPower(h.colorLamp, false)))
        advanceUntilIdle()
        h.transport.putResult = ClipResult.Err(ClipError.BridgeRejected(listOf("nope")))
        accepted(h.coordinator.submit(LiveMutation.SetBrightness(h.colorLamp, 90)))
        advanceUntilIdle()
        val gate = h.transport.holdNextPut()
        h.transport.putResult = ClipResult.Ok(ClipDocument(emptyList()))
        accepted(h.coordinator.submit(LiveMutation.SetBrightness(h.ctLamp, 30)))
        advanceUntilIdle()                       // the 30 is on the wire, held by the gate
        assertEquals(3, h.transport.putCount)
        accepted(h.coordinator.submit(LiveMutation.SetBrightness(h.ctLamp, 70)))
        gate.complete(ClipResult.Err(ClipError.Http(404)))
        advanceUntilIdle()
        assertTrue(events[0] is MutationEvent.Applied)
        assertEquals(MutationFailure.REJECTED_BY_BRIDGE, (events[1] as MutationEvent.Failed).failure)
        assertTrue((events[1] as MutationEvent.Failed).rolledBack)
        val superseded = events.filterIsInstance<MutationEvent.Failed>().singleOrNull { it.failure == MutationFailure.HTTP_ERROR }
            ?: throw AssertionError("no HTTP_ERROR failure among $events")
        assertFalse("a superseded write's failure does not roll back", superseded.rolledBack)
        assertEquals(30, (superseded.mutation as LiveMutation.SetBrightness).percent)
        job.cancel()
    }

    @Test
    fun noSignalingPathExists_inTheCoordinatorOrItsBodies() {
        val src = java.io.File("src/main/java/com/chromaglow/app/core/session/DefaultMutationCoordinator.kt").readText()
        assertFalse(src.contains("signaling\""))
        assertFalse(src.lowercase().contains("signalbody"))
        val mutations = LiveMutation::class.sealedSubclasses.map { it.simpleName!! }
        assertFalse(mutations.any { it.contains("Signal") })
        assertTrue(ResourceKey(com.chromaglow.app.core.identity.BridgeId("001788FFFE112233"), ResourceType.LIGHT, ResourceId("x")).composeKey.isNotEmpty())
    }
}
