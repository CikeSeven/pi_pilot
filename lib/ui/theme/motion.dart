import 'package:flutter/material.dart';

/// Material 3 动效 token。
/// 注意:SDK 里没有 `Easing.emphasized`,只有 Accelerate/Decelerate 这一对。
abstract final class PiMotion {
  static const press = Durations.short2; // 100ms
  static const quick = Durations.short3; // 150ms
  static const standard = Durations.medium2; // 300ms
  static const entrance = Durations.medium1; // 250ms
  static const sheetIn = Durations.medium4; // 400ms
  static const sheetOut = Durations.short4; // 200ms

  static const enter = Easing.emphasizedDecelerate;
  static const exit = Easing.emphasizedAccelerate;
  static const std = Easing.standard;
}
