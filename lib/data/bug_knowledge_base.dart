/// 🐛 Bug 知识库（8-06 01:03 用户：男主查日志发现问题 → 匹配知识库 → 辅助用户）
///
/// 男主调 report_bug 时，把 bug 描述 + 相关日志喂进来匹配，
/// 命中的解法会显示在 bug 报告弹窗里（用户可复制发给开发者）。
class BugKnowledgeBase {
  static const List<BugEntry> entries = [
    BugEntry(
      keywords: ['ImageCache', '图片不刷新', '旧图', '缓存不刷新', 'image.file'],
      solution: '图片缓存问题：同路径换图后 Flutter 返回旧图。'
          '修法：给 Image 加 key: ValueKey("路径_最后修改时间")。'
          '可以先把 APP 整个重启再试，不行就让开发者加 ValueKey。',
    ),
    BugEntry(
      keywords: ['FilePicker', '指针', '手势', '死锁', '点不动', '卡住'],
      solution: '文件选择器会吃掉 PointerUp，导致手势状态机死锁（界面点不动）。'
          '修法：所有 FilePicker 路径后复位手势状态（_pointerId = -1）。'
          '临时办法：重启 APP 即可恢复。',
    ),
    BugEntry(
      keywords: ['notifyListeners', '刷新延迟', '不刷新'],
      solution: '状态刷新问题：notifyListeners 用 Future.microtask 包了会延迟。'
          '修法：直接调用 notifyListeners()。重启可临时恢复。',
    ),
    BugEntry(
      keywords: ['头像', '背景', '污染', 'Persona', '串了'],
      solution: '角色头像/背景串了（Persona 污染）：头像/背景操作不走 state 中转，'
          '直接改传入的 Persona 对象并持久化。临时办法：重启 APP。',
    ),
    BugEntry(
      keywords: ['侧边栏', '点不到', 'IgnorePointer', '左右滑', '滑不动'],
      solution: '左右页打开时中间页被 IgnorePointer 挡住是正常的（防误触）；'
          '如果关掉后还点不到，重启 APP 试试。',
    ),
    BugEntry(
      keywords: ['网络', '000', '超时', '连不上', 'HTTP'],
      solution: '网络抽风（HTTP 000/超时）：一般是网络问题，重试几次即可。'
          '如果是推送/编译失败，重试或稍后再试。',
    ),
    BugEntry(
      keywords: ['闪退', '崩溃', 'crash', '重启'],
      solution: '闪退：先让用户把 bug 报告弹窗里的日志复制给开发者，'
          '开发者看日志定位。临时办法：重启 APP。',
    ),
    BugEntry(
      keywords: ['没反应', '点了没反应', '不响应', '无响应'],
      solution: '界面无响应：先看 DebugLogger 日志（男主可查），'
          '常见原因是手势状态机死锁或异步没回调。重启 APP 临时恢复。',
    ),
  ];

  /// 匹配：文本命中任一关键词 → 返回解法（没命中返回 null）
  static String? match(String text) {
    if (text.isEmpty) return null;
    final t = text.toLowerCase();
    for (final e in entries) {
      for (final k in e.keywords) {
        if (t.contains(k.toLowerCase())) return e.solution;
      }
    }
    return null;
  }
}

class BugEntry {
  final List<String> keywords;
  final String solution;
  const BugEntry({required this.keywords, required this.solution});
}
