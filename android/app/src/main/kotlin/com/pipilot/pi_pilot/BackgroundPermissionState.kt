package com.pipilot.pi_pilot

import android.app.ActivityManager
import android.app.usage.UsageStatsManager
import android.content.Context
import android.os.Build
import android.os.PowerManager

/// 后台运行豁免状态检测。
///
/// 为什么必须有这个模块:真机实测(小米 13 / HyperOS V816 / Android 16)证明
/// MIUI 会在应用退到后台约 60-90 秒后冻结**整个进程** —— 前台服务不给豁免,
/// deviceidle 显示 mState=ACTIVE、屏幕亮着、用户正在用手机时依然发生。
/// 冻结期间进程内一切都醒不过来:没有 WorkManager、没有 alarm、没有定时器,
/// 连 OkHttp 回调都停住(实测 CPU jiffies 完全不增长)。
/// 用户手动授予「后台无限制」后,同一场景下 5 分钟 7 条事件全部实时送达
/// (延迟 7-43ms、零丢失、零半开击杀),所以这个权限是后台实时的**决定性变量**,
/// 必须能检测、能引导,而不是让用户自己猜为什么通知会延迟几分钟。
///
/// ## 三个公开 API 各自反映什么(务必不要混淆)
///
/// - `PowerManager.isIgnoringBatteryOptimizations()`:仅反映 AOSP 的
///   deviceidle 豁免名单(Doze / App Standby)。官方明确「other restrictions
///   still apply」,所以它为 true 也**不**代表完全不受限。
/// - `ActivityManager.isBackgroundRestricted()`:用户手动选的「受限制」档。
///   小米官方文档称其 PowerKeeper 私有策略也通过这个值暴露,因此同一个 true
///   在 Pixel 上意味着「用户选了 Restricted」,在小米上可能意味着
///   「PowerKeeper 判定该应用行为不良」—— 跨机型不能当作单一语义。
/// - `UsageStatsManager.getAppStandbyBucket()`:查自身不需要 PACKAGE_USAGE_STATS
///   权限(官方明确),所以可以静默检测。RESTRICTED(45) 是限制最严的一档,
///   也是三星「休眠应用」的实际落地机制。
///
/// ## 实测校正了厂商文档
///
/// 小米文档只承诺「无限制」映射到 `isBackgroundRestricted()`,但真机 adb 验证
/// (HyperOS V816 / Android 16)显示它**同时**把包名写进了 deviceidle 白名单:
///   dumpsys deviceidle whitelist -> user,com.pipilot.pi_pilot,10424
/// 前缀 user 表示用户授予而非系统预置。所以在这台设备上标准 API 就够用,
/// 不需要任何私有 AppOps 逆向。但这只是单机验证,不能推广成全系保证,
/// 因此判定采用「三者并集」而不是只信任其中一个。
///
/// ## 为什么不做 OEM 私有状态检测
///
/// 除小米在文档里给出映射关系外,华为/OPPO/vivo/荣耀均无公开 API 可查询
/// 私有冻结策略状态(dontkillmyapp 对这几家的 dev 端结论都是
/// 「No known solution」)。唯一可行的是逆向私有 AppOps,那既不稳定也不该
/// 进生产。所以本模块的原则是:**状态检测只用公开 API,OEM 差异只体现在
/// Dart 侧的文字引导文案上**。曾实现过 deeplink 直达厂商设置页,但实测
/// HyperOS V816 已移除 powerkeeper 整套 HiddenApps 组件(省电策略页),
/// 各厂商组件名来自社区逆向、版本间极不稳定,没有任何可靠的自动跳转路径,
/// 故已放弃跳转机制,统一改为文字引导用户手动设置。
object BackgroundPermissionState {

    /// 判定结论。故意不叫 granted/denied:后台豁免不是一个布尔权限,
    /// 而是多个独立开关的合成结果,中间态必须能表达。
    enum class Verdict {
        /// 三项检查都好:标准 API 层面没有任何已知限制。
        UNRESTRICTED,

        /// 不在 deviceidle 白名单,但也没被显式限制。这是**出厂默认状态**,
        /// 也是绝大多数用户会遇到的状态 —— 正是需要引导的场景。
        OPTIMIZED,

        /// 被显式限制(isBackgroundRestricted 或 RESTRICTED bucket)。
        /// 比 OPTIMIZED 更严重,引导文案应当更强硬。
        RESTRICTED,

        /// SDK 太低,拿不到足够信息做判断(API < 23 没有 Doze)。
        UNKNOWN,
    }

    /// framework 读数的纯数据载体。抽出来是为了让判定逻辑成为纯函数:
    /// 项目里只有 junit4、没有 Robolectric,且 testOptions
    /// isReturnDefaultValues=true 会让 framework 调用静默返回默认值而不是抛错,
    /// 若把读取和判定写在一起,单测跑的其实是 stub 的默认值,等于没测。
    data class Readings(
        val sdkInt: Int,
        val ignoringBatteryOptimizations: Boolean,
        val backgroundRestricted: Boolean,
        /// -1 表示不可用(API < 28 或读取失败)。
        val standbyBucket: Int,
    )

    // UsageStatsManager 的常量在 JVM stub 下不可靠,这里写死实际值。
    // 来源:AOSP core/java/android/app/usage/UsageStatsManager.java
    const val BUCKET_UNKNOWN = -1
    const val BUCKET_ACTIVE = 10
    const val BUCKET_WORKING_SET = 20
    const val BUCKET_FREQUENT = 30
    const val BUCKET_RARE = 40
    const val BUCKET_RESTRICTED = 45
    const val BUCKET_NEVER = 50

    /// 纯判定函数,单测直接覆盖这里。
    ///
    /// 判定顺序有意为之:显式限制优先于白名单缺失,因为前者是用户或系统主动
    /// 施加的强限制,引导话术不同。bucket 只在 RESTRICTED 这一档参与判定 ——
    /// 官方明确「Don't try to influence which bucket your app is assigned to」,
    /// 且充电时系统会无视 bucket 给予无限制访问,所以中间档位不可作为判据。
    fun evaluate(readings: Readings): Verdict {
        // Doze 从 API 23 引入,更低版本没有可判定的语义。
        if (readings.sdkInt < Build.VERSION_CODES.M) return Verdict.UNKNOWN

        if (readings.backgroundRestricted) return Verdict.RESTRICTED
        if (readings.standbyBucket == BUCKET_RESTRICTED ||
            readings.standbyBucket == BUCKET_NEVER
        ) {
            return Verdict.RESTRICTED
        }

        return if (readings.ignoringBatteryOptimizations) {
            Verdict.UNRESTRICTED
        } else {
            Verdict.OPTIMIZED
        }
    }

    /// 是否应当提示用户去开权限。UNKNOWN 不提示:拿不到信息时不要用一个
    /// 无法验证的弹窗骚扰用户。
    fun shouldPrompt(verdict: Verdict): Boolean =
        verdict == Verdict.OPTIMIZED || verdict == Verdict.RESTRICTED

    /// 读取 framework 状态。每一项都单独 try:某些 OEM 上个别 service
    /// 取不到会抛异常,不能让一项失败导致整个诊断不可用。
    fun read(context: Context): Readings {
        val app = context.applicationContext
        val sdkInt = Build.VERSION.SDK_INT

        val ignoring = try {
            if (sdkInt >= Build.VERSION_CODES.M) {
                val pm = app.getSystemService(Context.POWER_SERVICE) as? PowerManager
                pm?.isIgnoringBatteryOptimizations(app.packageName) ?: false
            } else {
                // API < 23 没有 Doze,视为不受该机制限制。
                true
            }
        } catch (_: Throwable) {
            false
        }

        val restricted = try {
            if (sdkInt >= Build.VERSION_CODES.P) {
                val am = app.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
                am?.isBackgroundRestricted ?: false
            } else {
                false
            }
        } catch (_: Throwable) {
            false
        }

        val bucket = try {
            if (sdkInt >= Build.VERSION_CODES.P) {
                val usm = app.getSystemService(Context.USAGE_STATS_SERVICE) as? UsageStatsManager
                usm?.appStandbyBucket ?: BUCKET_UNKNOWN
            } else {
                BUCKET_UNKNOWN
            }
        } catch (_: Throwable) {
            BUCKET_UNKNOWN
        }

        return Readings(
            sdkInt = sdkInt,
            ignoringBatteryOptimizations = ignoring,
            backgroundRestricted = restricted,
            standbyBucket = bucket,
        )
    }

    /// 供 MethodChannel 直接返回给 Dart 的快照。
    /// 一并带上厂商信息,因为引导文案与跳转目标都依赖它,
    /// 而 Dart 侧不该自己去猜 Build.MANUFACTURER。
    fun snapshot(context: Context): Map<String, Any> {
        val readings = read(context)
        val verdict = evaluate(readings)
        val vendor = OemVendor.detect()
        return mapOf(
            "verdict" to verdict.name,
            "shouldPrompt" to shouldPrompt(verdict),
            "sdkInt" to readings.sdkInt,
            "ignoringBatteryOptimizations" to readings.ignoringBatteryOptimizations,
            "backgroundRestricted" to readings.backgroundRestricted,
            "standbyBucket" to readings.standbyBucket,
            "manufacturer" to Build.MANUFACTURER,
            "vendor" to vendor.name,
            // 有没有厂商专属设置页可跳。Dart 侧据此决定是否显示
            // 「打开厂商设置」这个额外按钮。
            "hasVendorSettings" to (vendor != OemVendor.AOSP),
        )
    }
}
