package com.dnschanger.app

import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.Parameterized

@RunWith(Parameterized::class)
class VpnSessionTest(private val name: String, private val runCheck: () -> Unit) {
    companion object {
        @JvmStatic
        @Parameterized.Parameters(name = "{0}")
        fun cases(): List<Array<Any>> = VpnCoreChecks.cases().map { arrayOf<Any>(it.first, it.second) }
    }

    @Test
    fun lifecycleInvariant() = runCheck()
}
