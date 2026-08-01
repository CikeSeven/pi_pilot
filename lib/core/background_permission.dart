import 'package:flutter/foundation.dart';

/// 后台运行豁免的判定结论。与 Kotlin 侧 `BackgroundPermissionState.Verdict`
/// 一一对应,名称必须保持同步(通过 name 字符串传递)。
///
/// 故意不用单个 bool:后台豁免不是一个布尔权限,而是「AOSP 电池优化白名单 +
/// 用户是否显式限制 + standby bucket」三者的合成结果,中间态必须能表达。
enum BackgroundPermissionVerdict {
  /// 三项检查都好,标准 API 层面没有已知限制。
  unrestricted,

  /// 不在电池优化白名单,但也没被显式限制。这是**出厂默认状态**,
  /// 绝大多数用户会处于这一档,正是需要引导的场景。
  optimized,

  /// 被显式限制(用户选了「受限制」,或落入 RESTRICTED/NEVER bucket)。
  /// 比 optimized 更严重,文案应更强硬。
  restricted,

  /// 信息不足(SDK 过低或读取失败)。不提示用户 —— 不该用一个无法验证的
  /// 弹窗骚扰人。
  unknown;

  static BackgroundPermissionVerdict parse(String? raw) {
    switch (raw) {
      case 'UNRESTRICTED':
        return BackgroundPermissionVerdict.unrestricted;
      case 'OPTIMIZED':
        return BackgroundPermissionVerdict.optimized;
      case 'RESTRICTED':
        return BackgroundPermissionVerdict.restricted;
      default:
        return BackgroundPermissionVerdict.unknown;
    }
  }
}

/// 厂商标识。只用于决定引导文案与是否显示「厂商设置」按钮,
/// **不参与状态判定** —— 判定一律走公开 API。
enum BackgroundPermissionVendor {
  xiaomi,
  samsung,
  vivo,
  oppo,
  oneplus,
  huawei,
  honor,
  meizu,
  aosp;

  static BackgroundPermissionVendor parse(String? raw) {
    switch (raw) {
      case 'XIAOMI':
        return BackgroundPermissionVendor.xiaomi;
      case 'SAMSUNG':
        return BackgroundPermissionVendor.samsung;
      case 'VIVO':
        return BackgroundPermissionVendor.vivo;
      case 'OPPO':
        return BackgroundPermissionVendor.oppo;
      case 'ONEPLUS':
        return BackgroundPermissionVendor.oneplus;
      case 'HUAWEI':
        return BackgroundPermissionVendor.huawei;
      case 'HONOR':
        return BackgroundPermissionVendor.honor;
      case 'MEIZU':
        return BackgroundPermissionVendor.meizu;
      default:
        return BackgroundPermissionVendor.aosp;
    }
  }

  /// 各厂商后台开关的**具体位置**。用户最需要的是这句话,而不是
  /// 「请开启后台权限」这种无处下手的提示。
  ///
  /// 这些路径来自厂商文档与社区记录,可能随系统版本变化,所以文案里
  /// 不写死版本号,只给可辨认的层级名。
  String get settingsHint {
    switch (this) {
      case BackgroundPermissionVendor.xiaomi:
        // 小米有两个独立开关,缺一不可:省电策略必须设为「无限制」,
        // 自启动也要允许。实测省电策略设为无限制后包名会进 deviceidle 白名单。
        return '设置 → 应用设置 → 应用管理 → PiPilot：\n'
            '① 省电策略 → 选「无限制」\n'
            '② 权限 → 允许「自启动」';
      case BackgroundPermissionVendor.samsung:
        // 三星有明确阈值:未使用约 3 天进休眠、约 16 天进深度休眠,
        // 后者会完全停掉通知。加入「永不休眠」列表才能避免。
        return '设置 → 电池 → 后台使用限制 →\n'
            '将 PiPilot 加入「永不休眠的应用」';
      case BackgroundPermissionVendor.vivo:
        return '设置 → 电池 → 后台高耗电 → 允许 PiPilot\n'
            '另需：设置 → 更多设置 → 应用程序 → 自启动 → 允许 PiPilot';
      case BackgroundPermissionVendor.oppo:
        // ColorOS 需要多项同时生效,少一项就不工作。
        return '设置 → 电池 → 应用耗电管理 → PiPilot：\n'
            '允许「后台运行」与「自启动」\n'
            '另建议在最近任务里锁定 PiPilot';
      case BackgroundPermissionVendor.oneplus:
        return '设置 → 电池 → 电池优化 → PiPilot → 不优化\n'
            '另需关闭「深度优化」与「睡眠待机优化」';
      case BackgroundPermissionVendor.huawei:
        // PowerGenie 按厂商硬编码白名单杀进程,用户无法加入,
        // 所以这里必须诚实说明可能仍会被限制。
        return '设置 → 应用 → 应用启动管理 → PiPilot →\n'
            '关闭「自动管理」，手动全部允许\n'
            '注意：华为系统仍可能限制后台，无法完全避免';
      case BackgroundPermissionVendor.honor:
        return '设置 → 应用 → 应用启动管理 → PiPilot →\n'
            '关闭「自动管理」，手动全部允许';
      case BackgroundPermissionVendor.meizu:
        return '设置 → 应用管理 → PiPilot → 权限 →\n'
            '允许后台运行与自启动';
      case BackgroundPermissionVendor.aosp:
        return '设置 → 应用 → PiPilot → 电池 →\n'
            '选择「无限制」';
    }
  }
}

/// 一次引导跳转的落点。区分「跳到厂商页」与「只跳到通用列表页」很重要:
/// 后者用户还要自己在长列表里找到应用,提示语不同。
enum BackgroundPermissionOutcome {
  vendorSettings,
  batteryWhitelistList,
  appDetails,
  failed;

  static BackgroundPermissionOutcome parse(String? raw) {
    switch (raw) {
      case 'VENDOR_SETTINGS':
        return BackgroundPermissionOutcome.vendorSettings;
      case 'BATTERY_WHITELIST_LIST':
        return BackgroundPermissionOutcome.batteryWhitelistList;
      case 'APP_DETAILS':
        return BackgroundPermissionOutcome.appDetails;
      default:
        return BackgroundPermissionOutcome.failed;
    }
  }
}

/// 后台豁免状态快照。字段与 Kotlin 侧 `snapshot()` 返回的 Map 对应。
@immutable
class BackgroundPermissionStatus {
  const BackgroundPermissionStatus({
    required this.verdict,
    required this.shouldPrompt,
    required this.vendor,
    required this.manufacturer,
    required this.sdkInt,
    required this.ignoringBatteryOptimizations,
    required this.backgroundRestricted,
    required this.standbyBucket,
    required this.hasVendorSettings,
  });

  final BackgroundPermissionVerdict verdict;
  final bool shouldPrompt;
  final BackgroundPermissionVendor vendor;
  final String manufacturer;
  final int sdkInt;
  final bool ignoringBatteryOptimizations;
  final bool backgroundRestricted;

  /// -1 表示不可用。10=ACTIVE 20=WORKING_SET 30=FREQUENT
  /// 40=RARE 45=RESTRICTED 50=NEVER
  final int standbyBucket;

  final bool hasVendorSettings;

  /// 非 Android 平台或读取失败时的安全默认:unknown 且不提示。
  static const BackgroundPermissionStatus unavailable =
      BackgroundPermissionStatus(
        verdict: BackgroundPermissionVerdict.unknown,
        shouldPrompt: false,
        vendor: BackgroundPermissionVendor.aosp,
        manufacturer: '',
        sdkInt: 0,
        ignoringBatteryOptimizations: false,
        backgroundRestricted: false,
        standbyBucket: -1,
        hasVendorSettings: false,
      );

  static BackgroundPermissionStatus fromMap(Map<Object?, Object?> map) {
    return BackgroundPermissionStatus(
      verdict: BackgroundPermissionVerdict.parse(map['verdict'] as String?),
      shouldPrompt: map['shouldPrompt'] as bool? ?? false,
      vendor: BackgroundPermissionVendor.parse(map['vendor'] as String?),
      manufacturer: map['manufacturer'] as String? ?? '',
      sdkInt: map['sdkInt'] as int? ?? 0,
      ignoringBatteryOptimizations:
          map['ignoringBatteryOptimizations'] as bool? ?? false,
      backgroundRestricted: map['backgroundRestricted'] as bool? ?? false,
      standbyBucket: map['standbyBucket'] as int? ?? -1,
      hasVendorSettings: map['hasVendorSettings'] as bool? ?? false,
    );
  }

  /// 给用户看的一句话结论。
  String get summary {
    switch (verdict) {
      case BackgroundPermissionVerdict.unrestricted:
        return '已允许后台运行，后台通知可实时送达';
      case BackgroundPermissionVerdict.optimized:
        return '系统正在优化后台运行，通知可能延迟数分钟';
      case BackgroundPermissionVerdict.restricted:
        return '后台运行已被限制，通知只能在打开应用后补齐';
      case BackgroundPermissionVerdict.unknown:
        return '无法读取后台运行状态';
    }
  }

  /// 为什么要开这个权限。措辞基于真机实测,不夸大也不隐瞒。
  String get rationale {
    if (verdict == BackgroundPermissionVerdict.unrestricted) {
      return '实测在此状态下，后台任务完成提醒可在数十毫秒内送达。';
    }
    return '实测未授予时，应用退到后台约 1 分钟后会被系统冻结，'
        '任务完成提醒需等到系统解冻或你重新打开应用才会出现。'
        '事件不会丢失，但实时性无法保证。';
  }
}
