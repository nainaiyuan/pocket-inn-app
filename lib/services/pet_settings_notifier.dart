import 'package:flutter/foundation.dart';

/// 桌宠设置变更通知
///
/// 右页（角色设置侧栏）里改了小人显示开关后，
/// 陪伴页监听此通知并调用 world.syncVisible() 同步场景。
class PetSettingsNotifier extends ChangeNotifier {
  PetSettingsNotifier._();

  static final PetSettingsNotifier instance = PetSettingsNotifier._();

  /// 触发一次同步（右页设置保存后调用）
  void notifyChanged() => notifyListeners();
}
