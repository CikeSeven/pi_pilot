package com.pipilot.pi_pilot

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/// 后台豁免判定逻辑的纯函数回归。
///
/// 项目里只有 junit4,没有 Robolectric,且 testOptions isReturnDefaultValues=true
/// 会让 framework 调用静默返回默认值而不是抛错。所以 BackgroundPermissionState
/// 把 framework 读取与判定拆开,测试只覆盖纯函数部分,保证跑的不是 stub 的
/// 默认值。
class BackgroundPermissionStateTest {

    private fun readings(
        sdkInt: Int = 36,
        ignoring: Boolean = false,
        restricted: Boolean = false,
        bucket: Int = BackgroundPermissionState.BUCKET_UNKNOWN,
    ) = BackgroundPermissionState.Readings(
        sdkInt = sdkInt,
        ignoringBatteryOptimizations = ignoring,
        backgroundRestricted = restricted,
        standbyBucket = bucket,
    )

    @Test
    fun `低 SDK 无可判定语义`() {
        // Doze 从 API 23 引入,更低版本没有可判定的机制。
        assertEquals(
            BackgroundPermissionState.Verdict.UNKNOWN,
            BackgroundPermissionState.evaluate(readings(sdkInt = 22)),
        )
    }

    @Test
    fun `出厂默认状态是 OPTIMIZED`() {
        // 绝大多数用户的真实状态:不在白名单,但也没被显式限制。
        // 这正是需要引导的场景。
        assertEquals(
            BackgroundPermissionState.Verdict.OPTIMIZED,
            BackgroundPermissionState.evaluate(readings()),
        )
    }

    @Test
    fun `用户显式限制优先于白名单缺失`() {
        // 即使不在白名单,显式限制是更强的信号,引导话术不同,
        // 所以判定顺序必须先查限制。
        assertEquals(
            BackgroundPermissionState.Verdict.RESTRICTED,
            BackgroundPermissionState.evaluate(readings(restricted = true)),
        )
    }

    @Test
    fun `RESTRICTED bucket 视为限制`() {
        // 三星休眠应用的实际落地机制就是 RESTRICTED bucket。
        assertEquals(
            BackgroundPermissionState.Verdict.RESTRICTED,
            BackgroundPermissionState.evaluate(
                readings(bucket = BackgroundPermissionState.BUCKET_RESTRICTED),
            ),
        )
    }

    @Test
    fun `NEVER bucket 也视为限制`() {
        assertEquals(
            BackgroundPermissionState.Verdict.RESTRICTED,
            BackgroundPermissionState.evaluate(
                readings(bucket = BackgroundPermissionState.BUCKET_NEVER),
            ),
        )
    }

    @Test
    fun `中间 bucket 不参与判定`() {
        // 官方明确「Don't try to influence which bucket」,且充电时无视 bucket,
        // 所以 ACTIVE/WORKING_SET/FREQUENT/RARE 都不能作为限制信号。
        for (bucket in listOf(
            BackgroundPermissionState.BUCKET_ACTIVE,
            BackgroundPermissionState.BUCKET_WORKING_SET,
            BackgroundPermissionState.BUCKET_FREQUENT,
            BackgroundPermissionState.BUCKET_RARE,
        )) {
            assertEquals(
                "bucket=$bucket 不该被误判为限制",
                BackgroundPermissionState.Verdict.OPTIMIZED,
                BackgroundPermissionState.evaluate(readings(bucket = bucket)),
            )
        }
    }

    @Test
    fun `三好条件是 UNRESTRICTED`() {
        // 实测小米 HyperOS V816 上设为「无限制」后包名会进 deviceidle 白名单,
        // 同时 RUN_IN_BACKGROUND 为 allow,bucket 不被压,所以这是可达状态。
        assertEquals(
            BackgroundPermissionState.Verdict.UNRESTRICTED,
            BackgroundPermissionState.evaluate(readings(ignoring = true)),
        )
    }

    @Test
    fun `UNRESTRICTED 与 UNKNOWN 不提示`() {
        assertFalse(
            BackgroundPermissionState.shouldPrompt(BackgroundPermissionState.Verdict.UNRESTRICTED),
        )
        // UNKNOWN 不提示:拿不到信息时不该用无法验证的弹窗骚扰用户。
        assertFalse(
            BackgroundPermissionState.shouldPrompt(BackgroundPermissionState.Verdict.UNKNOWN),
        )
    }

    @Test
    fun `OPTIMIZED 与 RESTRICTED 需要提示`() {
        assertTrue(
            BackgroundPermissionState.shouldPrompt(BackgroundPermissionState.Verdict.OPTIMIZED),
        )
        assertTrue(
            BackgroundPermissionState.shouldPrompt(BackgroundPermissionState.Verdict.RESTRICTED),
        )
    }
}

class OemVendorTest {

    @Test
    fun `小米系识别`() {
        for (m in listOf("Xiaomi", "xiaomi", "Redmi", "POCO")) {
            assertEquals(m, OemVendor.XIAOMI, OemVendor.detect(m))
        }
    }

    @Test
    fun `三星识别`() {
        assertEquals(OemVendor.SAMSUNG, OemVendor.detect("samsung"))
    }

    @Test
    fun `vivo 识别`() {
        assertEquals(OemVendor.VIVO, OemVendor.detect("vivo"))
    }

    @Test
    fun `一加要在 OPPO 之前判`() {
        // 两家共用 ColorOS 后属性会混,但 MANUFACTURER 是 OnePlus 时要识别为一加。
        assertEquals(OemVendor.ONEPLUS, OemVendor.detect("OnePlus"))
        assertEquals(OemVendor.OPPO, OemVendor.detect("OPPO"))
        assertEquals(OemVendor.OPPO, OemVendor.detect("realme"))
    }

    @Test
    fun `华为与荣耀区分`() {
        assertEquals(OemVendor.HUAWEI, OemVendor.detect("HUAWEI"))
        assertEquals(OemVendor.HONOR, OemVendor.detect("HONOR"))
    }

    @Test
    fun `未识别厂商归为 AOSP 兜底`() {
        // AOSP 是安全默认:只走标准 Intent,不做厂商私有跳转。
        for (m in listOf("Google", "UnknownVendor", "", "motorola")) {
            assertEquals(m, OemVendor.AOSP, OemVendor.detect(m))
        }
    }
}
