import Foundation

/// 一笔记完之后**接下来弹哪一页**。
///
/// ★★ 为什么这个判断要放在引擎里、而且要有测试:
///   用户 2026-09-03 报「完整的一笔完成的订单 ≥2 张截图放入软件之后
///   **不能填写交易入场以及出场原因**」。
///   原因是 App 侧一行 `t.isClosed ? .review : .openPlan` ——
///   已平仓的直接跳复盘页,而复盘页没有填原因的地方。
///
///   <b>这类「接下来去哪」的判断以前一直只写在视图里,而视图层没有测试。</b>
///   同一个坑今年已经踩过一次:`askMerge` 的旗子从 v1.0 就在设,
///   但**从来没接过 UI**,而提交信息里写着「已生效」。
///   ⇒ 判断本身是纯函数,搬进引擎、写上测试;视图只负责按结果换页面。
public enum ImportFlow {

    public enum Step: Equatable {
        /// 先问原因(未平仓问「为什么开 + 止损止盈」,已平仓问「为什么开 + 为什么走」)
        case askReasons
        /// 照纪律手册逐条问:哪些做到了、哪些没做到
        case askDiscipline
        /// 直接进复盘页
        case review
        /// 什么都不弹(未平仓、而且原因已经有了)
        case none
    }

    /// 还缺原因吗?
    ///
    /// ★ 未平仓只看开单原因 —— 那一刻还没有「为什么走」。
    /// ★ 已平仓两个都要:少一个,历史页的两块汇总就有一块是空的。
    public static func needsReasons(_ t: Trade) -> Bool {
        t.isClosed ? (t.entryReason == nil || t.exitReason == nil)
                   : (t.entryReason == nil)
    }

    /// 还没做纪律自检吗。
    ///
    /// ★ 只问**已平仓**的:一笔还没走完,「这单守没守规矩」问不出结论。
    /// ★ 手册是空的就不问 —— 没有规矩可对照时,问了也只是一个空表。
    public static func needsDiscipline(_ t: Trade, book: DisciplineBook) -> Bool {
        t.isClosed && book.activeCount > 0 && (t.discipline?.isEmpty ?? true)
    }

    /// 保存之后走哪一步。
    public static func next(after t: Trade, book: DisciplineBook = .init()) -> Step {
        if needsReasons(t) { return .askReasons }
        if needsDiscipline(t, book: book) { return .askDiscipline }
        return t.isClosed ? .review : .none
    }

    /// 填完/跳过原因之后走哪一步。★ 跳过也要往下走 ——
    /// 否则批量导入里跳过一笔,后面几笔就再也问不到了。
    public static func afterReasons(_ t: Trade, book: DisciplineBook = .init()) -> Step {
        if needsDiscipline(t, book: book) { return .askDiscipline }
        return t.isClosed ? .review : .none
    }

    /// 做完/跳过纪律自检之后。
    public static func afterDiscipline(_ t: Trade) -> Step {
        t.isClosed ? .review : .none
    }
}
