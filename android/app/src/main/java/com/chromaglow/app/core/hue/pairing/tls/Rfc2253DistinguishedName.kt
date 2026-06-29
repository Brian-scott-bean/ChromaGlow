package com.chromaglow.app.core.hue.pairing.tls

/**
 * Self-contained RFC 2253 Distinguished Name tokenizer.
 *
 * The Android SDK does NOT bundle `javax.naming` (JNDI), so `javax.naming.ldap.LdapName`
 * is unavailable in production code. This object implements just enough of RFC 2253
 * (the string representation produced by
 * [javax.security.auth.x500.X500Principal.getName] with the `RFC2253` format) to
 * structurally extract attribute type/value pairs:
 *
 *  - RDNs are separated by an unescaped, unquoted `,`.
 *  - Multi-valued RDN components are separated by an unescaped, unquoted `+`.
 *  - A `\` escapes the following character; `\` followed by two hex digits encodes a byte.
 *  - Double quotes delimit a quoted value in which `,` / `+` lose their special meaning.
 *  - Attribute-type/value pairs are split on the first unescaped, unquoted `=`.
 *
 * This is deliberately NOT a naive `split(",")` / regex over the raw DN: it respects
 * escaping and quoting so values containing commas (for example) are preserved intact.
 */
internal object Rfc2253DistinguishedName {

    /** A single attribute type/value pair, e.g. type `CN`, value `001788FFFE112233`. */
    data class AttributeTypeAndValue(
        val type: String,
        val value: String,
    )

    /**
     * Parse [distinguishedName] into its Relative Distinguished Names.
     *
     * The outer list is the sequence of RDNs (separated by `,`); each inner list is the
     * one-or-more multi-valued attribute components of that RDN (separated by `+`).
     * Returns an empty list for a blank input.
     */
    fun parse(distinguishedName: String): List<List<AttributeTypeAndValue>> {
        if (distinguishedName.isBlank()) return emptyList()

        val rdns = mutableListOf<List<AttributeTypeAndValue>>()
        var currentRdn = mutableListOf<AttributeTypeAndValue>()
        val component = StringBuilder()
        var inQuotes = false
        var i = 0
        val n = distinguishedName.length

        while (i < n) {
            val c = distinguishedName[i]
            when {
                c == '\\' -> {
                    // Preserve the escape verbatim; it is interpreted later in unescape().
                    component.append(c)
                    if (i + 1 < n) {
                        component.append(distinguishedName[i + 1])
                        i += 2
                    } else {
                        i += 1
                    }
                }

                c == '"' -> {
                    inQuotes = !inQuotes
                    component.append(c)
                    i += 1
                }

                c == ',' && !inQuotes -> {
                    currentRdn.add(parseComponent(component.toString()))
                    rdns.add(currentRdn)
                    currentRdn = mutableListOf()
                    component.setLength(0)
                    i += 1
                }

                c == '+' && !inQuotes -> {
                    currentRdn.add(parseComponent(component.toString()))
                    component.setLength(0)
                    i += 1
                }

                else -> {
                    component.append(c)
                    i += 1
                }
            }
        }

        currentRdn.add(parseComponent(component.toString()))
        rdns.add(currentRdn)
        return rdns
    }

    private fun parseComponent(rawComponent: String): AttributeTypeAndValue {
        val equalsIndex = indexOfUnescapedEquals(rawComponent)
        if (equalsIndex < 0) {
            // Malformed component with no attribute-type separator; surface the raw text as
            // the type so it simply fails to match a known attribute such as CN.
            return AttributeTypeAndValue(type = rawComponent.trim(), value = "")
        }
        val type = rawComponent.substring(0, equalsIndex).trim()
        val rawValue = rawComponent.substring(equalsIndex + 1)
        return AttributeTypeAndValue(type = type, value = unescape(rawValue))
    }

    private fun indexOfUnescapedEquals(component: String): Int {
        var i = 0
        var inQuotes = false
        while (i < component.length) {
            val c = component[i]
            when {
                c == '\\' -> i += 2
                c == '"' -> {
                    inQuotes = !inQuotes
                    i += 1
                }

                c == '=' && !inQuotes -> return i
                else -> i += 1
            }
        }
        return -1
    }

    /**
     * Resolve RFC 2253 escaping within an attribute value:
     *  - `\X` yields the literal character `X`.
     *  - `\HH` (two hex digits) yields the byte `0xHH` as a character.
     *  - Structural double quotes are dropped.
     */
    private fun unescape(value: String): String {
        val out = StringBuilder()
        var i = 0
        val n = value.length
        while (i < n) {
            val c = value[i]
            when {
                c == '\\' -> {
                    if (i + 1 >= n) {
                        i += 1
                    } else if (i + 2 < n && isHexDigit(value[i + 1]) && isHexDigit(value[i + 2])) {
                        val byte = value.substring(i + 1, i + 3).toInt(16)
                        out.append(byte.toChar())
                        i += 3
                    } else {
                        out.append(value[i + 1])
                        i += 2
                    }
                }

                c == '"' -> i += 1
                else -> {
                    out.append(c)
                    i += 1
                }
            }
        }
        return out.toString()
    }

    private fun isHexDigit(c: Char): Boolean =
        c in '0'..'9' || c in 'a'..'f' || c in 'A'..'F'
}
