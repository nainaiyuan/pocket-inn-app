import 'package:flutter/foundation.dart';

/// 关系记录变更通知（8-07 01:13）
///
/// chat_page 男主用 record_relation 记了新关系 → notify()
/// butler_page 关系图订阅 → 自动刷新。
/// 跨页面解耦，不互相 import。
class RelationChangeNotifier extends ChangeNotifier {
  RelationChangeNotifier._();

  static final RelationChangeNotifier instance = RelationChangeNotifier._();

  void notify() => notifyListeners();
}
