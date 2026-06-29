package com.chromaglow.app.core.hue.pairing.tls

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for the self-contained RFC 2253 DN tokenizer. These exercise escaping, quoting,
 * multi-valued RDNs and hex escapes directly so the higher-level identity extractor can rely on
 * structured parsing rather than a naive `split(",")`.
 */
class Rfc2253DistinguishedNameTest {

    private fun parse(dn: String) = Rfc2253DistinguishedName.parse(dn)

    @Test
    fun simpleThreeRdnDn_isSplitInOrder() {
        val rdns = parse("CN=root-bridge,O=Philips Hue,C=NL")

        assertEquals(3, rdns.size)
        assertEquals(Rfc2253DistinguishedName.AttributeTypeAndValue("CN", "root-bridge"), rdns[0].single())
        assertEquals(Rfc2253DistinguishedName.AttributeTypeAndValue("O", "Philips Hue"), rdns[1].single())
        assertEquals(Rfc2253DistinguishedName.AttributeTypeAndValue("C", "NL"), rdns[2].single())
    }

    @Test
    fun escapedComma_isPreservedInsideValue() {
        val rdns = parse("""CN=ab\,cd,O=x""")

        assertEquals(2, rdns.size)
        assertEquals("ab,cd", rdns[0].single().value)
        assertEquals("x", rdns[1].single().value)
    }

    @Test
    fun escapedPlus_isPreservedInsideValue() {
        val rdns = parse("""CN=a\+b""")

        assertEquals(1, rdns.size)
        assertEquals("a+b", rdns[0].single().value)
    }

    @Test
    fun quotedValue_stripsQuotesAndKeepsComma() {
        val rdns = parse("""CN="ab,cd",O=x""")

        assertEquals(2, rdns.size)
        assertEquals("ab,cd", rdns[0].single().value)
        assertEquals("x", rdns[1].single().value)
    }

    @Test
    fun multiValuedRdn_splitsOnUnescapedPlus() {
        val rdns = parse("OU=a+CN=001788FFFE112233,O=x")

        assertEquals(2, rdns.size)
        assertEquals(2, rdns[0].size)
        assertEquals(Rfc2253DistinguishedName.AttributeTypeAndValue("OU", "a"), rdns[0][0])
        assertEquals(Rfc2253DistinguishedName.AttributeTypeAndValue("CN", "001788FFFE112233"), rdns[0][1])
        assertEquals(Rfc2253DistinguishedName.AttributeTypeAndValue("O", "x"), rdns[1].single())
    }

    @Test
    fun hexEscape_decodesByte() {
        // \41 == 'A', \42 == 'B'
        val rdns = parse("""CN=\41\42""")

        assertEquals("AB", rdns[0].single().value)
    }

    @Test
    fun escapedBackslash_isPreserved() {
        val rdns = parse("""CN=a\\b""")

        assertEquals("""a\b""", rdns[0].single().value)
    }

    @Test
    fun blankInput_isEmpty() {
        assertTrue(parse("").isEmpty())
        assertTrue(parse("   ").isEmpty())
    }

    @Test
    fun typeIsCaptured_verbatimForCaseInsensitiveMatchingLater() {
        val rdns = parse("cn=001788FFFE112233")
        assertEquals("cn", rdns.single().single().type)
    }
}
