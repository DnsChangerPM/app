package com.dnschanger.app

/**
 * Persist/restore the last successful VPN config for the QS tile and BootReceiver.
 * Pure string encoding so JVM unit tests do not need Android JSON APIs.
 */
object VpnLastConfig {
    const val PREFS = "vpn_last_config"
    const val KEY = "json"

    fun toJson(config: VpnConfig): String {
        return buildString {
            append('{')
            append("\"addresses\":").append(stringList(config.encodedAddresses))
            append(",\"allowed\":").append(stringList(config.allowedPackages))
            append(",\"disallowed\":").append(stringList(config.disallowedPackages))
            append(",\"enableIpv6\":").append(config.enableIpv6)
            append(",\"autoReconnect\":").append(config.autoReconnect)
            append(",\"timeoutMs\":").append(config.timeoutMs)
            append(",\"fallbackSecondary\":").append(config.fallbackSecondary)
            append(",\"dnsLeakProtection\":").append(config.dnsLeakProtection)
            append('}')
        }
    }

    fun fromJson(raw: String?): VpnConfig? {
        if (raw.isNullOrBlank()) return null
        return try {
            val addresses = parseStringList(raw, "addresses")
            val allowed = parseStringList(raw, "allowed")
            val disallowed = parseStringList(raw, "disallowed")
            val enableIpv6 = parseBool(raw, "enableIpv6", true)
            val autoReconnect = parseBool(raw, "autoReconnect", true)
            val timeoutMs = parseInt(raw, "timeoutMs", 2500)
            val fallback = parseBool(raw, "fallbackSecondary", true)
            val leak = parseBool(raw, "dnsLeakProtection", true)
            VpnConfig.parse(
                addresses, 53, allowed, disallowed, enableIpv6,
                autoReconnect, timeoutMs, fallback, leak
            )
        } catch (_: Exception) {
            null
        }
    }

    fun shouldScheduleReconnect(
        isCurrent: Boolean,
        sessionPhase: VpnPhase,
        runtimePhase: VpnPhase,
        autoReconnect: Boolean
    ): Boolean {
        return isCurrent &&
            autoReconnect &&
            sessionPhase == VpnPhase.CONNECTED &&
            runtimePhase == VpnPhase.CONNECTED
    }

    private fun stringList(values: List<String>): String {
        return values.joinToString(prefix = "[", postfix = "]") { "\"${escape(it)}\"" }
    }

    private fun escape(value: String): String = buildString {
        for (ch in value) {
            when (ch) {
                '\\' -> append("\\\\")
                '"' -> append("\\\"")
                else -> append(ch)
            }
        }
    }

    private fun parseStringList(json: String, key: String): List<String> {
        val marker = "\"$key\":"
        val start = json.indexOf(marker)
        if (start < 0) return emptyList()
        val open = json.indexOf('[', start)
        val close = json.indexOf(']', open)
        if (open < 0 || close < 0) return emptyList()
        val body = json.substring(open + 1, close).trim()
        if (body.isEmpty()) return emptyList()
        return body.split(',').map { it.trim().trim('"') }.filter { it.isNotEmpty() }
    }

    private fun parseBool(json: String, key: String, default: Boolean): Boolean {
        val marker = "\"$key\":"
        val start = json.indexOf(marker)
        if (start < 0) return default
        val rest = json.substring(start + marker.length).trimStart()
        return rest.startsWith("true")
    }

    private fun parseInt(json: String, key: String, default: Int): Int {
        val marker = "\"$key\":"
        val start = json.indexOf(marker)
        if (start < 0) return default
        val rest = json.substring(start + marker.length).trimStart()
        val digits = rest.takeWhile { it.isDigit() || it == '-' }
        return digits.toIntOrNull() ?: default
    }
}
