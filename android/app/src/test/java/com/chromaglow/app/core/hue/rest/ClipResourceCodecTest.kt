package com.chromaglow.app.core.hue.rest

import com.chromaglow.app.core.hue.rest.wire.ClipBlocks
import com.chromaglow.app.core.hue.rest.wire.ClipGroupKind
import com.chromaglow.app.core.hue.rest.wire.ClipResourceCodec
import com.chromaglow.app.core.hue.rest.wire.ClipXy
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.random.Random

/** ClipResourceParserTest: every shape, absent blocks, unknown keys, malformed entries, fuzz. */
class ClipResourceCodecTest {

    private fun fixture(name: String): JsonObject {
        val text = javaClass.classLoader!!.getResource("clip/$name")!!.readText()
        return Json.parseToJsonElement(text).jsonObject
    }

    @Test
    fun light_fullFixture_decodesEveryBlock() {
        val light = ClipResourceCodec.light(fixture("light_full.json"))!!

        assertEquals("6d0f9d3a-0b1e-4c7d-9c2a-1f2e3d4c5b6a", light.id)
        assertEquals("/lights/3", light.idV1)
        assertEquals("dev-1", light.owner!!.rid)
        assertEquals("Play Gradient", light.name)
        assertEquals("hue_lightstrip", light.archetype)
        assertEquals(true, light.on)
        assertEquals(62.5, light.dimming!!.brightness!!, 0.0)
        assertEquals(0.2, light.dimming!!.minDimLevel!!, 0.0)
        assertEquals(ClipXy(0.3127, 0.329), light.color!!.xy)
        assertEquals(ClipXy(0.17, 0.7), light.color!!.gamut!!.green)
        assertEquals("C", light.color!!.gamutType)
        assertEquals(366, light.colorTemperature!!.mirek)
        assertEquals(true, light.colorTemperature!!.mirekValid)
        assertEquals(153, light.colorTemperature!!.schema!!.minimum)
        assertEquals(500, light.colorTemperature!!.schema!!.maximum)
        assertEquals("none", light.dynamics!!.status)
        assertEquals(listOf("none", "dynamic_palette"), light.dynamics!!.statusValues)
        assertEquals(0.5, light.dynamics!!.speed!!, 0.0)
        assertEquals(listOf("no_effect", "candle", "fire"), light.effects!!.effectValues)
        assertEquals(8, light.effectsV2!!.actionEffectValues!!.size)
        assertEquals("candle", light.effectsV2!!.statusEffect)
        assertEquals(0.6, light.effectsV2!!.statusParameters!!.speed!!, 0.0)
        assertEquals(ClipXy(0.5, 0.4), light.effectsV2!!.statusParameters!!.color)
        assertEquals(250, light.effectsV2!!.statusParameters!!.mirek)
        assertEquals(listOf("no_effect", "sunrise", "sunset"), light.timedEffects!!.effectValues)
        assertEquals(0L, light.timedEffects!!.duration)
        assertEquals(2, light.gradient!!.points!!.size)
        assertEquals("interpolated_palette", light.gradient!!.mode)
        assertEquals(3, light.gradient!!.modeValues!!.size)
        assertEquals(5, light.gradient!!.pointsCapable)
        assertEquals(7, light.gradient!!.pixelCount)
        assertEquals(listOf("no_signal", "on_off", "on_off_color", "alternating"), light.signaling!!.signalValues)
        assertEquals("no_signal", light.signaling!!.statusSignal)
        assertEquals("normal", light.mode)
        // Unknown keys are recorded as present and ignored.
        assertTrue(light.hasBlock("future_block_nobody_knows"))
    }

    @Test
    fun light_minimalFixture_hasEveryOptionalBlockAbsent() {
        val light = ClipResourceCodec.light(fixture("light_minimal.json"))!!

        assertEquals("min-1", light.id)
        assertEquals(false, light.on)
        assertNull(light.dimming)
        assertNull(light.color)
        assertNull(light.colorTemperature)
        assertNull(light.effects)
        assertNull(light.effectsV2)
        assertNull(light.timedEffects)
        assertNull(light.gradient)
        assertNull(light.signaling)
        assertNull(light.dynamics)
        for (block in listOf(ClipBlocks.COLOR, ClipBlocks.COLOR_TEMPERATURE, ClipBlocks.EFFECTS, ClipBlocks.GRADIENT, ClipBlocks.SIGNALING)) {
            assertFalse(block, light.hasBlock(block))
        }
    }

    @Test
    fun light_ctWithoutSchema_isPresentButSchemaNull() {
        val light = ClipResourceCodec.light(fixture("light_ct_no_schema.json"))!!
        assertTrue(light.hasBlock(ClipBlocks.COLOR_TEMPERATURE))
        assertEquals(300, light.colorTemperature!!.mirek)
        assertNull(light.colorTemperature!!.schema)
    }

    @Test
    fun light_presentButGarbageBlock_isRecordedPresentWithNullValue() {
        val obj = Json.parseToJsonElement("""{"id":"g1","type":"light","color_temperature":"nope","gradient":42,"effects":[1,2]}""").jsonObject
        val light = ClipResourceCodec.light(obj)!!
        assertTrue(light.hasBlock(ClipBlocks.COLOR_TEMPERATURE))
        assertNull(light.colorTemperature)
        assertTrue(light.hasBlock(ClipBlocks.GRADIENT))
        assertNull(light.gradient)
        assertNull(light.effects)
    }

    @Test
    fun light_missingBlankOrWhitespaceId_isNull_andWrongTypeIsNull() {
        assertNull(ClipResourceCodec.light(Json.parseToJsonElement("""{"type":"light"}""").jsonObject))
        assertNull(ClipResourceCodec.light(Json.parseToJsonElement("""{"id":"","type":"light"}""").jsonObject))
        assertNull(ClipResourceCodec.light(Json.parseToJsonElement("""{"id":"a b","type":"light"}""").jsonObject))
        assertNull(ClipResourceCodec.light(Json.parseToJsonElement("""{"id":42,"type":"light"}""").jsonObject))
        assertNull(ClipResourceCodec.light(Json.parseToJsonElement("""{"id":"x","type":"scene"}""").jsonObject))
        // A missing type is tolerated (older firmware); the caller asked the light collection.
        assertNotNull(ClipResourceCodec.light(Json.parseToJsonElement("""{"id":"x"}""").jsonObject))
    }

    @Test
    fun quotedNumbers_areNotAcceptedAsNumbers() {
        val obj = Json.parseToJsonElement("""{"id":"q","type":"light","dimming":{"brightness":"50"},"color_temperature":{"mirek":"300","mirek_schema":{"mirek_minimum":"153","mirek_maximum":500}}}""").jsonObject
        val light = ClipResourceCodec.light(obj)!!
        assertNull(light.dimming!!.brightness)
        assertNull(light.colorTemperature!!.mirek)
        assertNull(light.colorTemperature!!.schema)
    }

    @Test
    fun nonFiniteDoubles_neverEnterTheModel() {
        val obj = Json { isLenient = true }.parseToJsonElement("""{"id":"n","type":"light","dimming":{"brightness":NaN},"color":{"xy":{"x":Infinity,"y":0.3}}}""").jsonObject
        val light = ClipResourceCodec.light(obj)!!
        assertNull(light.dimming!!.brightness)
        assertNull(light.color!!.xy)
    }

    @Test
    fun room_decodesChildrenAndServices_skippingMalformedRefs() {
        val room = ClipResourceCodec.group(fixture("room.json"), ClipGroupKind.ROOM)!!
        assertEquals("Living", room.name)
        assertEquals("living_room", room.archetype)
        assertEquals(listOf("dev-1", "dev-2"), room.children.map { it.rid })
        assertEquals("gl-1", room.groupedLightRid)
        assertEquals(2, room.services.size)
    }

    @Test
    fun zone_decodes_andRoomCodecRefusesAZoneElement() {
        val zone = ClipResourceCodec.group(fixture("zone.json"), ClipGroupKind.ZONE)!!
        assertEquals(ClipGroupKind.ZONE, zone.kind)
        assertEquals("light", zone.children.single().rtype)
        assertEquals("gl-2", zone.groupedLightRid)
        assertNull(ClipResourceCodec.group(fixture("zone.json"), ClipGroupKind.ROOM))
    }

    @Test
    fun groupedLight_decodes() {
        val gl = ClipResourceCodec.groupedLight(fixture("grouped_light.json"))!!
        assertEquals("room-1", gl.owner!!.rid)
        assertEquals(true, gl.on)
        assertEquals(40.0, gl.brightness!!, 0.0)
        assertEquals(listOf("breathe"), gl.alertActionValues)
        assertEquals(listOf("no_signal", "on_off"), gl.signalValues)
        assertNull(gl.xy)
    }

    @Test
    fun scene_decodesStatusGroupActionsAndPalette_skippingMalformedActions() {
        val scene = ClipResourceCodec.scene(fixture("scene.json"))!!
        assertEquals("Relax", scene.name)
        assertEquals("room-1", scene.group!!.rid)
        assertEquals("static", scene.statusActive)
        assertTrue(scene.isActive)
        assertFalse(scene.isDynamic)
        assertEquals(0.5, scene.speed!!, 0.0)
        assertEquals(false, scene.autoDynamic)
        assertEquals(1, scene.actions!!.size)
        assertEquals(447, scene.actions!![0].mirek)
        assertEquals(listOf(ClipXy(0.5, 0.4)), scene.paletteColors)
    }

    @Test
    fun scene_dynamicPaletteStatus_isActiveAndDynamic() {
        val obj = Json.parseToJsonElement("""{"id":"s","type":"scene","status":{"active":"dynamic_palette"}}""").jsonObject
        val scene = ClipResourceCodec.scene(obj)!!
        assertTrue(scene.isActive && scene.isDynamic)
        val inactive = ClipResourceCodec.scene(Json.parseToJsonElement("""{"id":"s","type":"scene","status":{"active":"inactive"}}""").jsonObject)!!
        assertFalse(inactive.isActive)
    }

    @Test
    fun bridge_decodes() {
        val bridge = ClipResourceCodec.bridge(Json.parseToJsonElement("""{"id":"b","type":"bridge","bridge_id":"001788fffe112233","time_zone":{"time_zone":"Europe/Amsterdam"}}""").jsonObject)!!
        assertEquals("001788fffe112233", bridge.bridgeId)
        assertEquals("Europe/Amsterdam", bridge.timeZone)
    }

    // --- envelope -----------------------------------------------------------------------------

    @Test
    fun envelope_oneMalformedElement_neverFailsTheDocument() {
        val env = ClipEnvelopeParser.parse("""{"errors":[],"data":[{"id":"a","type":"light"},42,"x",null,{"id":"b","type":"light"}]}""") as ClipEnvelope.Document
        assertEquals(2, env.document.data.size)
        assertEquals(3, env.skippedElements)
    }

    @Test
    fun envelope_errorsWithoutDescription_becomeUnspecified() {
        val env = ClipEnvelopeParser.parse("""{"errors":[{"foo":1},{"description":""},{"description":"real"}],"data":[]}""") as ClipEnvelope.Document
        assertEquals(listOf(ClipEnvelopeParser.UNSPECIFIED_ERROR, ClipEnvelopeParser.UNSPECIFIED_ERROR, "real"), env.document.errors)
        assertTrue(ClipEnvelopeParser.toResult(env) is ClipResult.Err)
        assertEquals(ClipError.BridgeRejected(env.document.errors), (ClipEnvelopeParser.toResult(env) as ClipResult.Err).error)
    }

    @Test
    fun envelope_nonObjectRoot_isMalformed_andBlankIsEmpty() {
        assertTrue(ClipEnvelopeParser.parse("[]") is ClipEnvelope.Malformed)
        assertTrue(ClipEnvelopeParser.parse("nope") is ClipEnvelope.Malformed)
        val blank = ClipEnvelopeParser.parse("   ") as ClipEnvelope.Document
        assertTrue(blank.document.data.isEmpty() && blank.document.errors.isEmpty())
    }

    // --- fuzz ---------------------------------------------------------------------------------

    private fun mutate(element: JsonElement, rng: Random, depth: Int = 0): JsonElement {
        if (depth > 6) return element
        val roll = rng.nextInt(100)
        return when (element) {
            is JsonObject -> {
                val map = LinkedHashMap(element)
                when {
                    roll < 10 -> return JsonPrimitive(rng.nextInt())
                    roll < 15 -> return JsonNull
                    roll < 20 -> return JsonArray(map.values.toList())
                    roll < 40 && map.isNotEmpty() -> map.remove(map.keys.random(rng))
                    else -> if (map.isNotEmpty()) {
                        val k = map.keys.random(rng); map[k] = mutate(map.getValue(k), rng, depth + 1)
                    }
                }
                JsonObject(map)
            }
            is JsonArray -> when {
                roll < 15 -> JsonPrimitive("array-was-here")
                roll < 30 -> JsonArray(element + JsonNull + JsonPrimitive(3.5))
                element.isEmpty() -> element
                else -> JsonArray(element.mapIndexed { i, e -> if (i == rng.nextInt(element.size)) mutate(e, rng, depth + 1) else e })
            }
            is JsonPrimitive -> when (roll % 6) {
                0 -> JsonNull
                1 -> JsonPrimitive("str")
                2 -> JsonPrimitive(rng.nextDouble(-1e9, 1e9))
                3 -> JsonPrimitive(rng.nextBoolean())
                4 -> JsonObject(mapOf("x" to element))
                else -> JsonArray(listOf(element))
            }
            else -> element
        }
    }

    @Test
    fun fuzz_oneThousandMutations_ofEveryFixture_neverThrow() {
        val rng = Random(20260902)
        val seeds = listOf("light_full.json", "light_minimal.json", "light_ct_no_schema.json", "room.json", "zone.json", "grouped_light.json", "scene.json")
        var decodedSomething = 0
        for (seed in seeds) {
            var current: JsonElement = fixture(seed)
            repeat(1_000) {
                current = mutate(current, rng)
                val obj = current as? JsonObject
                if (obj != null) {
                    // Every decoder must be total on every object.
                    ClipResourceCodec.light(obj)?.let { decodedSomething++ }
                    ClipResourceCodec.group(obj, ClipGroupKind.ROOM)
                    ClipResourceCodec.group(obj, ClipGroupKind.ZONE)
                    ClipResourceCodec.groupedLight(obj)
                    ClipResourceCodec.scene(obj)
                    ClipResourceCodec.bridge(obj)
                    ClipEnvelopeParser.parse(JsonObject(mapOf("data" to JsonArray(listOf(obj, current)), "errors" to current)).toString())
                } else {
                    current = fixture(seed)
                }
            }
        }
        assertTrue(decodedSomething > 0)
    }
}
