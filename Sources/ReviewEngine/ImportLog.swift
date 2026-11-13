import Foundation

/// **没记进来的那些**。
///
/// ★★ 2026-09-03 的发现:App 里 4 胜 0 负、100% 胜率、+$705,
///   而当天真实发生的那笔 **−$140 亏损,正好就是导入失败的那一张**
///   (OCR 把 `$0.12` 认成 `SO.12`)。
///   而失败之前<b>不留任何痕迹</b> —— 弹一句「没认出文字」就没了,
///   没有计数、没有日志。
///
/// ★★ 为什么这件事比它看起来严重:<b>漏掉的不是随机样本。</b>
///   亏损单更烦、更不想记,技术上也更容易出岔子(那张恰好就是卖出那张)。
///   两边叠加 ⇒ 统计会**系统性偏乐观**。
///   而这个 App 全部的价值就在那些统计上 ——
///   <b>一个只记得住盈利单的复盘工具,比没有复盘工具更糟。</b>
///
/// ⇒ 所以:失败要留痕,而且要**显示出来**。看不见的漏记等于不存在。
public struct ImportFailure: Codable, Sendable, Equatable, Identifiable {

    public enum Reason: String, Codable, Sendable {
        /// OCR 一个字都没认出来(糊了、截歪了、深色模式等)
        case ocrEmpty
        /// 认出了字,但关键字段凑不齐,而且那张图被丢掉了(批量导入那条路)
        case unusable
        /// 从截图进了录入页,用户没保存就退出了 —— 「嫌烦不记了」正是偏差的来源
        case abandoned
    }

    public var id: UUID
    public var at: Date
    public var reason: Reason
    /// OCR 出来的前几行。★ 留着有两个用处:让用户认出是哪一张;
    ///   我照着它就能加一条夹具。**只存本机**,和别的数据一样从不上传。
    public var lines: [String]

    public init(id: UUID = UUID(), at: Date = Date(), reason: Reason, lines: [String] = []) {
        self.id = id; self.at = at; self.reason = reason
        self.lines = Array(lines.prefix(6))
    }
}

public extension Array where Element == ImportFailure {
    /// 某个交易日所属月份的失败次数。★ 按**交易所时区**分月 —— 和别处一致。
    func count(inMonthOf date: Date) -> Int {
        let key = ImportFailure.monthKey(of: date)
        return filter { ImportFailure.monthKey(of: $0.at) == key }.count
    }
}

public extension ImportFailure {
    static func monthKey(of date: Date) -> String {
        let c = TradingDay.day(of: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }
}
