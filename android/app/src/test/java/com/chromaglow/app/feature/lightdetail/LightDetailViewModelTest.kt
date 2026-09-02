package com.chromaglow.app.feature.lightdetail

import com.chromaglow.app.core.hue.capability.CieXy
import com.chromaglow.app.core.hue.capability.MirekRange
import com.chromaglow.app.core.identity.TargetRef
import com.chromaglow.app.core.session.ConnectionState
import com.chromaglow.app.core.session.EffectParameters
import com.chromaglow.app.core.session.LightState
import com.chromaglow.app.core.session.LiveMutation
import com.chromaglow.app.core.session.MutationEvent
import com.chromaglow.app.core.session.RefusalReason
import kotlinx.coroutines.test.runCurrent
import org.junit.Assert.assertNull
import com.chromaglow.app.core.session.TimedEffect
import com.chromaglow.app.core.session.safety.EffectSafetyRegister
import com.chromaglow.app.feature.testing.Caps
import com.chromaglow.app.feature.testing.FakeLiveHome
import com.chromaglow.app.feature.testing.RecordingHomeCommands
import com.chromaglow.app.feature.testing.RecordingHomeCommands.Call
import com.chromaglow.app.feature.testing.homeOf
import com.chromaglow.app.feature.testing.light
import com.chromaglow.app.feature.testing.snapshot
import com.chromaglow.app.ui.components.ColorMath
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class LightDetailViewModelTest {

    private val dispatcher = StandardTestDispatcher()
    private val commands = RecordingHomeCommands()

    @Before fun setUp() = Dispatchers.setMain(dispatcher)
    @After fun tearDown() = Dispatchers.resetMain()

    private fun vm(
        l: LightState,
        connection: ConnectionState = ConnectionState.Connected,
        register: EffectSafetyRegister? = null,
    ): LightDetailViewModel {
        val home = FakeLiveHome(homeOf(snapshot(lights = listOf(l)) to connection))
        val store = InMemoryNoticeAcknowledgementStore(initial = true)
        return if (register != null) {
            LightDetailViewModel(home, commands, l.key, register = register, noticeStore = store, clock = { 0L })
        } else {
            LightDetailViewModel(home, commands, l.key, noticeStore = store, clock = { 0L })
        }
    }

    private val colour = light("c", "Lamp", mirek = 366, mirekValid = true, capabilities = Caps.color(range = MirekRange(153, 454)))
    private val target = TargetRef.Live(colour.key)

    @Test
    fun powerAndBrightness_forwardWithClamp() {
        val vm = vm(colour)
        vm.setPower(false)
        vm.setBrightness(0)
        assertEquals(listOf<Call>(Call.LightPower(target, false), Call.LightBrightness(target, 1)), commands.calls)
    }

    @Test
    fun colour_isClampedIntoTheLampsGamut() {
        val vm = vm(colour)
        vm.setColor(CieXy(0.9, 0.05)) // outside gamut C
        val sent = (commands.calls.single() as Call.LightColor).xy
        val gamut = Caps.color().color.value!!
        assertTrue(ColorMath.inside(sent, gamut.red, gamut.green, gamut.blue))
    }

    @Test
    fun mirek_isClampedToTheLampsSchema_notProtocolBounds() {
        val vm = vm(colour)
        vm.setMirek(500)
        assertEquals(listOf<Call>(Call.LightCt(target, 454)), commands.calls)
    }

    @Test
    fun ctWithoutSchema_refusesWarmthWrites() {
        val vm = vm(light("c", "Lamp", capabilities = Caps.ctWithoutSchema()))
        vm.setMirek(300)
        assertTrue(commands.calls.isEmpty())
    }

    @Test
    fun whiteOnly_refusesColourWrites_beforeTheWire() {
        val vm = vm(light("w", "Ceiling", capabilities = Caps.white()))
        vm.setColor(CieXy(0.4, 0.4))
        vm.selectEffect("candle")
        vm.startTimed()
        vm.applyGradient()
        assertTrue(commands.calls.isEmpty())
    }

    @Test
    fun unknownCapabilities_refuseEveryOptionalWrite_butAllowPower() {
        val vm = vm(light("u", "Mystery", capabilities = Caps.unknown()))
        vm.setColor(CieXy(0.4, 0.4))
        vm.setMirek(300)
        vm.selectEffect("candle")
        vm.setPower(true)
        assertEquals(listOf<Call>(Call.LightPower(TargetRef.Live(com.chromaglow.app.feature.testing.lightKey("u")), true)), commands.calls)
    }

    @Test
    fun selectEffect_sendsSpeedAndOnlyKnownParams_noneStops() {
        val vm = vm(colour)
        vm.selectEffect("candle")
        vm.selectEffect(null)
        assertEquals(
            listOf<Call>(
                Call.Effect(target, "candle", EffectParameters(speed = 0.5, color = null, mirek = null)),
                Call.StopEffect(target),
            ),
            commands.calls,
        )
    }

    @Test
    fun v1OnlyLamp_sendsNoParameters() {
        val vm = vm(light("c", "Lamp", capabilities = Caps.color().copy(effectsV2 = com.chromaglow.app.core.hue.capability.Capability.absent())))
        vm.selectEffect("candle")
        assertEquals(EffectParameters(), (commands.calls.single() as Call.Effect).parameters)
    }

    @Test
    fun deniedEffect_isRefused_evenIfRequestedDirectly() {
        val register = object : EffectSafetyRegister { override val denied = setOf("sparkle") }
        val vm = vm(colour, register = register)
        vm.selectEffect("sparkle")
        assertTrue(commands.calls.isEmpty())
    }

    @Test
    fun unofferedEffect_isRefused() {
        val vm = vm(colour)
        vm.selectEffect("prism")
        assertTrue(commands.calls.isEmpty())
    }

    @Test
    fun speedChange_reSendsTheActiveEffect_withNewSpeed() = runTest(dispatcher) {
        val vm = vm(light("c", "Lamp", activeEffect = "fire", capabilities = Caps.color()))
        vm.setEffectSpeed(80)
        assertEquals(listOf<Call>(Call.Effect(TargetRef.Live(colour.key), "fire", EffectParameters(speed = 0.8))), commands.calls)
    }

    @Test
    fun speedChange_withNoActiveEffect_sendsNothing() {
        val vm = vm(colour)
        vm.setEffectSpeed(80)
        assertTrue(commands.calls.isEmpty())
    }

    @Test
    fun effectColourAndMirek_clampedAndSentWithActiveEffect() = runTest(dispatcher) {
        val vm = vm(light("c", "Lamp", activeEffect = "candle", capabilities = Caps.color(range = MirekRange(153, 454))))
        vm.setEffectMirek(600)
        val sent = commands.calls.last() as Call.Effect
        assertEquals(454, sent.parameters.mirek)
        vm.setEffectColor(CieXy(0.95, 0.02))
        val gamut = Caps.color().color.value!!
        val xy = (commands.calls.last() as Call.Effect).parameters.color!!
        assertTrue(ColorMath.inside(xy, gamut.red, gamut.green, gamut.blue))
    }

    @Test
    fun timed_startUsesSelectionAndDuration_cancelSends() {
        val vm = vm(colour)
        vm.selectTimed(TimedEffect.SUNSET)
        vm.setTimedDuration(60)
        vm.setTimedDuration(7) // not a choice → ignored
        vm.startTimed()
        vm.cancelTimed()
        assertEquals(
            listOf<Call>(Call.Timed(target, TimedEffect.SUNSET, 60 * 60_000L), Call.CancelTimed(target)),
            commands.calls,
        )
    }

    @Test
    fun gradient_applySendsAtMostTheLampsCap_andClearsDraft() {
        val vm = vm(light("g", "Strip", capabilities = Caps.gradient(pointsCapable = 3)))
        vm.selectGradientPoint(2)
        vm.setGradientPointColor(CieXy(0.2, 0.6))
        vm.selectGradientMode("random_pixelated")
        vm.applyGradient()
        val sent = commands.calls.single() as Call.Gradient
        assertEquals(3, sent.points.size)
        assertEquals("random_pixelated", sent.mode)
        val gamut = Caps.color().color.value!!
        assertTrue(sent.points.all { ColorMath.inside(it, gamut.red, gamut.green, gamut.blue) })
    }

    @Test
    fun gradient_unknownMode_isIgnored() = runTest(dispatcher) {
        val vm = vm(light("g", "Strip", capabilities = Caps.gradient()))
        vm.selectGradientMode("not_a_mode")
        vm.applyGradient()
        assertEquals("interpolated_palette", (commands.calls.single() as Call.Gradient).mode)
    }

    @Test
    fun offline_refusesEverything() {
        val vm = vm(colour, connection = ConnectionState.Offline)
        vm.setPower(true); vm.setBrightness(50); vm.setColor(CieXy(0.4, 0.4)); vm.setMirek(300)
        vm.selectEffect("candle"); vm.startTimed(); vm.cancelTimed(); vm.applyGradient()
        assertTrue(commands.calls.isEmpty())
    }

    @Test
    fun acknowledgeNotice_hidesIt() = runTest(dispatcher) {
        val home = FakeLiveHome(homeOf(snapshot(lights = listOf(colour)) to ConnectionState.Connected))
        val store = InMemoryNoticeAcknowledgementStore()
        val vm = LightDetailViewModel(home, commands, colour.key, noticeStore = store, clock = { 0L })
        assertTrue(vm.uiState.value.showPhotosensitivityNotice)
        vm.acknowledgeNotice()
        val after = vm.uiState.first { !it.showPhotosensitivityNotice }
        assertTrue(!after.showPhotosensitivityNotice)
        assertTrue(store.isAcknowledged())
    }

    @Test
    fun noticeAcknowledgedOnOneViewModel_isNotShownByAnotherOnTheSameStore() {
        val home = FakeLiveHome(homeOf(snapshot(lights = listOf(colour)) to ConnectionState.Connected))
        val store = InMemoryNoticeAcknowledgementStore()
        val first = LightDetailViewModel(home, commands, colour.key, noticeStore = store, clock = { 0L })
        assertTrue(first.uiState.value.showPhotosensitivityNotice)
        first.acknowledgeNotice()
        val second = LightDetailViewModel(home, commands, colour.key, noticeStore = store, clock = { 0L })
        assertTrue(!second.uiState.value.showPhotosensitivityNotice)
        val unrelated = LightDetailViewModel(home, commands, colour.key, noticeStore = InMemoryNoticeAcknowledgementStore(), clock = { 0L })
        assertTrue(unrelated.uiState.value.showPhotosensitivityNotice)
    }

    @Test
    fun feedback_onlyForThisLight_namesIt() = runTest(dispatcher) {
        val home = FakeLiveHome(homeOf(snapshot(lights = listOf(colour, light("o", "Other"))) to ConnectionState.Connected))
        val vm = LightDetailViewModel(home, commands, colour.key, noticeStore = InMemoryNoticeAcknowledgementStore(true), clock = { 0L })
        runCurrent()
        home.emitEvent(MutationEvent.Refused(LiveMutation.SetPower(com.chromaglow.app.feature.testing.lightKey("o"), true), RefusalReason.OFFLINE))
        runCurrent()
        assertNull(vm.feedback.value)
        home.emitEvent(MutationEvent.Refused(LiveMutation.SelectEffect(colour.key, "candle"), RefusalReason.EFFECT_DENIED_BY_SAFETY_REGISTER))
        runCurrent()
        assertEquals("Lamp effect isn't available on this app.", vm.feedback.value!!.message)
    }
}
