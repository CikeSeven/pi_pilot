package com.pipilot.pi_pilot

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings

/// 后台豁免的引导跳转。
///
/// ## 为什么不用 ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS
///
/// 那个 action 会直接弹系统对话框、体验最好,但需要声明
/// REQUEST_IGNORE_BATTERY_OPTIMIZATIONS 权限,而 Google Play 的
/// Device and Network Abuse 政策把「not eligible for allowlisting and attempt
/// to bypass system power management」列为违规示例,已有应用因此被拒审。
/// Google 官方「可接受用例」表里,「能用 FCM 高优先级消息的即时通讯类」
/// 明确是 Not Acceptable,而 PiPilot 的定位介于「外设伴侣应用维持持久连接」
/// (Acceptable)与前者之间,存在被判定违规的实际风险。
///
/// 所以这里只用**不需要任何权限**的 ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS
/// 跳列表页。代价是用户要自己在列表里找到 PiPilot,必须配套文案指引。
/// 这是政策安全与体验之间的自觉取舍,不是遗漏。
///
/// ## 为什么厂商组件名要逐个 try 而不能先 resolveActivity
///
/// Android 11+ 的包可见性(package visibility)会让 resolveActivity() 对确实
/// 存在的组件返回 null,所以它不能作为判据。同时这些私有组件在新系统上会
/// 变更或消失:已记录 MIUI 12 上标准 REQUEST intent 无法跳转、Android 13 +
/// MIUI 直接 setClassName 打 HiddenAppsConfigActivity 抛 ActivityNotFoundException
/// (未 export 时抛的是 SecurityException)。
///
/// 因此唯一可靠的做法是:按候选列表逐个 startActivity,catch 所有异常继续下一个,
/// 全部失败再退回标准页。降级链的最后一环 ACTION_APPLICATION_DETAILS_SETTINGS
/// 永远存在,保证用户至少能到达本应用的设置页。
///
/// ## 组件名来源与可靠性
///
/// 三星那条是**唯一有官方文档**的 deeplink(Samsung Application Management)。
/// 其余来自社区维护列表与厂商逆向,属于 best-effort:能跳就省用户几步,
/// 跳不了不影响功能。所以任何一条都不能成为必要路径。
object BackgroundPermissionIntents {

    /// 一次跳转尝试的结果,回给 Dart 用于文案与埋点。
    /// 区分「跳到了厂商页」与「只跳到了通用页」很重要:后者用户还需要
    /// 自己在列表里找应用,提示语不同。
    enum class Outcome {
        VENDOR_SETTINGS,
        BATTERY_WHITELIST_LIST,
        APP_DETAILS,
        FAILED,
    }

    /// 标准电池优化白名单列表页。不需要权限,政策安全。
    /// 注意它不接受 package: data,无法定位到具体应用。
    private fun batteryWhitelistIntent(): Intent =
        Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)

    /// 永远存在的兜底:本应用详情页,用户可从这里进电池设置。
    private fun appDetailsIntent(packageName: String): Intent =
        Intent(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.fromParts("package", packageName, null),
        )

    /// 各厂商的候选入口,按「越精确越靠前」排列。
    /// 同一厂商给多个候选是因为不同系统版本组件名不同,
    /// 逐个尝试比做版本判断更健壮(版本号与组件名并非严格对应)。
    private fun vendorIntents(vendor: OemVendor, packageName: String): List<Intent> =
        when (vendor) {
            OemVendor.XIAOMI -> listOf(
                // 省电策略(本应用),能直接定位到 PiPilot,最精确。
                // 实测这台 HyperOS V816 上用户设为「无限制」后
                // 包名会进 deviceidle 白名单,所以这一页就是决定性开关。
                Intent().setComponent(
                    ComponentName(
                        "com.miui.powerkeeper",
                        "com.miui.powerkeeper.ui.HiddenAppsConfigActivity",
                    ),
                ).putExtra("package_name", packageName)
                    .putExtra("package_label", "PiPilot"),
                // 省电策略列表页。
                Intent().setComponent(
                    ComponentName(
                        "com.miui.powerkeeper",
                        "com.miui.powerkeeper.ui.HiddenAppsContainerManagementActivity",
                    ),
                ),
                // 自启动管理:与省电策略是**独立**开关,两者都需要开。
                Intent().setComponent(
                    ComponentName(
                        "com.miui.securitycenter",
                        "com.miui.permcenter.autostart.AutoStartManagementActivity",
                    ),
                ),
            )

            OemVendor.SAMSUNG -> listOf(
                // 官方 deeplink(Samsung Application Management 文档):
                // activity_type 2 = never sleeping apps,正是要让用户加入的列表。
                // 三星的休眠机制有明确阈值:未使用约 3 天进 sleeping、
                // 约 16 天进 deep sleeping,后者「can't perform any activities,
                // including notifications」。
                Intent("com.samsung.android.sm.ACTION_OPEN_CHECKABLE_LISTACTIVITY")
                    .setPackage("com.samsung.android.lool")
                    .putExtra("activity_type", 2),
                Intent().setComponent(
                    ComponentName(
                        "com.samsung.android.lool",
                        "com.samsung.android.sm.ui.battery.BatteryActivity",
                    ),
                ),
            )

            OemVendor.VIVO -> listOf(
                // vivo 的限制机制社区尚未完全摸清(dontkillmyapp 自述
                // 「not fully uncovered yet」),所以这里给多个候选。
                Intent().setComponent(
                    ComponentName(
                        "com.vivo.permissionmanager",
                        "com.vivo.permissionmanager.activity.BgStartUpManagerActivity",
                    ),
                ),
                Intent().setComponent(
                    ComponentName(
                        "com.iqoo.secure",
                        "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity",
                    ),
                ),
                Intent().setComponent(
                    ComponentName(
                        "com.iqoo.secure",
                        "com.iqoo.secure.ui.phoneoptimize.BgStartUpManager",
                    ),
                ),
            )

            OemVendor.OPPO -> listOf(
                // ColorOS 的启动管理。社区记录 OPPO 需要多项同时生效
                // (锁最近任务 + 启动管理 + 关电池优化 + 常驻通知),
                // 少一项就不工作,所以文案要提醒用户不止一处。
                Intent().setComponent(
                    ComponentName(
                        "com.coloros.safecenter",
                        "com.coloros.safecenter.permission.startup.StartupAppListActivity",
                    ),
                ),
                Intent().setComponent(
                    ComponentName(
                        "com.coloros.safecenter",
                        "com.coloros.safecenter.startupapp.StartupAppListActivity",
                    ),
                ),
                // 旧版 ColorOS / 部分 realme。
                Intent().setComponent(
                    ComponentName(
                        "com.oppo.safe",
                        "com.oppo.safe.permission.startup.StartupAppListActivity",
                    ),
                ),
                Intent().setComponent(
                    ComponentName(
                        "com.coloros.oppoguardelf",
                        "com.coloros.powermanager.fuelgaue.PowerSaverModeActivity",
                    ),
                ),
            )

            OemVendor.ONEPLUS -> listOf(
                Intent().setComponent(
                    ComponentName(
                        "com.oneplus.security",
                        "com.oneplus.security.chainlaunch.view.ChainLaunchAppListActivity",
                    ),
                ),
                // 一加较新机型已并入 ColorOS,复用 OPPO 的组件名。
                Intent().setComponent(
                    ComponentName(
                        "com.coloros.safecenter",
                        "com.coloros.safecenter.permission.startup.StartupAppListActivity",
                    ),
                ),
            )

            OemVendor.HUAWEI -> listOf(
                // 华为 PowerGenie(EMUI 9+)按自家硬编码白名单杀进程,
                // 用户**无法**把自己的应用加进去,所以这里能做的只是
                // 打开「启动管理」让用户手动允许,不保证解决冻结。
                Intent().setComponent(
                    ComponentName(
                        "com.huawei.systemmanager",
                        "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
                    ),
                ),
                Intent().setComponent(
                    ComponentName(
                        "com.huawei.systemmanager",
                        "com.huawei.systemmanager.appcontrol.activity.StartupAppControlActivity",
                    ),
                ),
                Intent().setComponent(
                    ComponentName(
                        "com.huawei.systemmanager",
                        "com.huawei.systemmanager.optimize.process.ProtectActivity",
                    ),
                ),
            )

            OemVendor.HONOR -> listOf(
                // 荣耀分家后缺少一手资料(dontkillmyapp 无独立页面),
                // 先按 EMUI 系处理:新包名 com.hihonor.* 优先,失败退回华为组件。
                Intent().setComponent(
                    ComponentName(
                        "com.hihonor.systemmanager",
                        "com.hihonor.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
                    ),
                ),
                Intent().setComponent(
                    ComponentName(
                        "com.huawei.systemmanager",
                        "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
                    ),
                ),
            )

            OemVendor.MEIZU -> listOf(
                Intent("com.meizu.safe.security.SHOW_APPSEC")
                    .addCategory(Intent.CATEGORY_DEFAULT)
                    .putExtra("packageName", packageName),
            )

            OemVendor.AOSP -> emptyList()
        }

    /// 执行跳转。必须从 Activity context 调用(startActivity 需要),
    /// 所以 MainActivity 直接调这里而不是委派给 applicationContext。
    ///
    /// preferVendor=false 时跳过厂商页直接走标准页,给「我只想看白名单」
    /// 这种场景用,也便于用户在厂商页跳失败后手动重试通用路径。
    fun open(context: Context, preferVendor: Boolean = true): Outcome {
        val packageName = context.packageName
        val vendor = OemVendor.detect()

        if (preferVendor) {
            for (intent in vendorIntents(vendor, packageName)) {
                if (tryStart(context, intent)) return Outcome.VENDOR_SETTINGS
            }
        }

        // 标准白名单列表页:API 23+ 才有。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            tryStart(context, batteryWhitelistIntent())
        ) {
            return Outcome.BATTERY_WHITELIST_LIST
        }

        if (tryStart(context, appDetailsIntent(packageName))) return Outcome.APP_DETAILS

        return Outcome.FAILED
    }

    /// catch Throwable 而不是具体异常类型:未 export 组件抛 SecurityException、
    /// 不存在抛 ActivityNotFoundException,部分 OEM 还会抛自定义异常。
    /// 引导跳转失败绝不能让应用崩溃 —— 它只是个便利功能。
    private fun tryStart(context: Context, intent: Intent): Boolean = try {
        // 从非 Activity context 启动时必须带 NEW_TASK;从 Activity 启动时
        // 带上也无害,所以统一加,避免调用方传错 context 就崩。
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
        true
    } catch (_: Throwable) {
        false
    }
}
