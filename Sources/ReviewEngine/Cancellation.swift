import Foundation

/// 「这个错误是**取消**吗?」
///
/// ★★ 2026-09-03 实测踩到的坑:`URLSession` 在任务被取消时抛的是
///   `URLError.cancelled`,而 App 里那一行 `catch { throw Failure.offline }`
///   把它一并当成了断网 ⇒ 界面上写「连不上网。手动填也一样能算。」
///   <b>用户会去检查 WiFi,而真实原因是这张页面被换掉了。</b>
///
///   「记完 → 问原因 → 复盘页」这一串里 sheet 内容是换掉的,
///   `.task` 会被取消 —— 这是**正常路径**,不是故障。
///   把它报成故障,等于给用户一个错的诊断;<b>错的诊断比没有诊断更糟</b>。
///
/// 放在引擎里的唯一理由:**这样它才有测试**。
/// 判断写在视图或网络层里,就又是一处没人测的分支。
public enum Cancellation {
    /// 取消(含 `URLError.cancelled`)返回 true。
    public static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let u = error as? URLError, u.code == .cancelled { return true }
        // NSError 形态的同一件事(跨模块传递时常见)
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }
}
