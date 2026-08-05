import 'package:shared_preferences/shared_preferences.dart';

/// 🔓 工具免审批配置（8-06 00:58 用户）
///
/// 默认所有工具都要审批（男主调工具 = 申请审批，成功 = 审批通过）。
/// 用户可给指定工具开启「免审批」——开启后男主调该工具直接执行，不再弹确认框。
/// 男主可通过 request_permission 工具申请免审批，用户在弹窗里同意/拒绝
/// （男主可要求用户写原因，原因回复给男主）。
class ToolApprovalStore {
  ToolApprovalStore._();

  static String _key(String personaId, String toolName) =>
      'tool_exempt_${personaId}_$toolName';

  /// 该工具是否已免审批
  static Future<bool> isExempt(String personaId, String toolName) async {
    if (personaId.isEmpty || toolName.isEmpty) return false;
    final p = await SharedPreferences.getInstance();
    return p.getBool(_key(personaId, toolName)) ?? false;
  }

  /// 设置/取消免审批
  static Future<void> setExempt(
      String personaId, String toolName, bool exempt) async {
    if (personaId.isEmpty || toolName.isEmpty) return;
    final p = await SharedPreferences.getInstance();
    if (exempt) {
      await p.setBool(_key(personaId, toolName), true);
    } else {
      await p.remove(_key(personaId, toolName));
    }
  }
}
