package com.pipilot.pi_pilot

import android.os.Build

/// 厂商识别。只用于挑选引导跳转目标与文案,**绝不用于状态判定** ——
/// 状态判定一律走 BackgroundPermissionState 里的公开 API,
/// 因为除小米在文档里给出映射关系外,其余厂商都没有可查询私有策略的公开 API。
///
/// 为什么按厂商分支:各家的后台限制是**独立于 AOSP 的私有机制**,开关藏在
/// 各自的安全中心/电池管理里,名字和路径都不一样(小米叫「省电策略/自启动」、
/// 三星叫「休眠应用」、vivo 叫「后台高耗电/自启动」、OPPO 叫「启动管理」)。
/// 只跳 AOSP 的电池优化页,在这些机型上往往解决不了真正的限制。
///
/// 识别用 Build.MANUFACTURER 而不是 BRAND:同一厂商多品牌时(如 OPPO 与
/// 一加、华为与荣耀分家前)MANUFACTURER 更稳定;同时并查 ro.build 相关属性
/// 由调用方决定,这里保持无副作用。
enum class OemVendor {
    XIAOMI,
    SAMSUNG,
    VIVO,
    OPPO,
    ONEPLUS,
    HUAWEI,
    HONOR,
    MEIZU,
    /// 原生或未识别厂商。Pixel/AOSP 是唯一「检测 API 与实际行为基本一致」的平台,
    /// 也是所有未知厂商的安全默认:只走标准 Intent。
    AOSP,
    ;

    companion object {
        fun detect(manufacturer: String = Build.MANUFACTURER): OemVendor {
            val m = manufacturer.lowercase()
            return when {
                m.contains("xiaomi") || m.contains("redmi") || m.contains("poco") -> XIAOMI
                m.contains("samsung") -> SAMSUNG
                m.contains("vivo") -> VIVO
                // 一加要在 oppo 之前判:OnePlus 设备的 MANUFACTURER 是 OnePlus,
                // 但两家共用 ColorOS 后部分机型属性会混,显式区分以便用各自的组件名。
                m.contains("oneplus") -> ONEPLUS
                m.contains("oppo") || m.contains("realme") -> OPPO
                m.contains("huawei") -> HUAWEI
                m.contains("honor") -> HONOR
                m.contains("meizu") || m.contains("blackshark") -> MEIZU
                else -> AOSP
            }
        }
    }
}
