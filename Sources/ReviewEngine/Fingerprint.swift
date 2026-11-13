import Foundation

/// 「这是同一笔交易吗」—— **按内容判,不按我生成的 UUID 判。**
///
/// ★★ 2026-09-02 用户报「重新导入了,文件全部重复了」。原因是我的:
///   `tools/import_review_bundle.py` 每次运行都 `uuid4()` 生成新 id,
///   我为了加「开单原因」重新生成了一次文件,于是 5 笔变成了 10 笔。
///   导入去重只看 `Trade.id`,而 id 是**我造的**、每次都不一样。
///
///   ⇒ 病根不是脚本忘了固定种子,是**「同一笔」的判据选错了**:
///     <b>UUID 相等太弱。真正决定「是同一笔」的是成交内容。</b>
///     两笔交易若标的、腿、每一笔成交的时间/方向/数量/价格都一样,
///     那它<b>就是</b>同一笔 —— 不管 id 是什么。
public extension Trade {

    /// 内容指纹。**只取「客观发生了什么」**:标的 + 每条腿的合约 + 每笔成交。
    /// 不含备注、心理、原因、路径 —— 那些是**后来补的注解**,补了不该变成另一笔。
    var fingerprint: String {
        var parts: [String] = [symbol.uppercased()]
        for leg in legs.sorted(by: { $0.kind.fingerprint < $1.kind.fingerprint }) {
            parts.append(leg.kind.fingerprint)
        }
        // 价格按分、时间按分钟对齐 —— 券商截图的秒位常常对不上,但那不该算两笔
        for f in fills.sorted(by: { $0.time < $1.time }) {
            let minute = Int(f.time.timeIntervalSince1970 / 60)
            parts.append(String(format: "%@|%d|%.4f|%.4f",
                                f.side == .buy ? "B" : "S", minute, f.quantity, f.price))
        }
        return parts.joined(separator: "~")
    }
}

extension LegKind {
    /// 合约的稳定标识。
    var fingerprint: String {
        switch self {
        case .equity:
            return "EQ"
        case .option(let r, let k, let e):
            let day = Int(e.timeIntervalSince1970 / 86_400)     // 到期按天,不按秒
            return String(format: "OPT|%@|%.4f|%d", r == .call ? "C" : "P", k, day)
        case .futures(let c, let pv, _):
            return String(format: "FUT|%@|%.2f", c.uppercased(), pv)
        case .forex(let size):
            return String(format: "FX|%.0f", size)
        }
    }
}

/// 找出重复的交易。
public enum Deduper {

    public struct Duplicate: Sendable, Identifiable {
        public var id: String { keep.id.uuidString }
        /// 留下的那一笔(**注解最多的那个** —— 见 `richness`)。
        public var keep: Trade
        /// 要删掉的那些。
        public var drop: [Trade]
    }

    /// 「注解丰富度」—— 重复时留哪一笔。
    ///
    /// ★ 留**填得最多**的那笔,而不是最早或最晚的:
    ///   用户可能已经在其中一份上填了收盘价、心理、原因。删错了就白填一遍。
    static func richness(_ t: Trade) -> Int {
        var n = 0
        if t.finalUnderlying != nil { n += 1 }
        if t.peakUnderlying != nil { n += 1 }
        if t.psychology != nil { n += 2 }
        if t.entryReason != nil { n += 1 }
        if t.plannedStop != nil { n += 1 }
        if t.plannedTarget != nil { n += 1 }
        if t.exitReason != nil { n += 1 }
        if t.rawNoteAtEntry?.isEmpty == false { n += 1 }
        if t.rawNoteAtExit?.isEmpty == false { n += 1 }
        if t.underlyingPath?.isEmpty == false { n += 1 }
        n += t.legs.filter { $0.path?.isEmpty == false }.count
        n += t.legs.filter { $0.userClosePrice != nil }.count
        n += t.attachments.count
        return n
    }

    /// 按内容指纹分组,返回所有「同一笔被存了多份」的组。
    /// 示例数据不参与 —— 它本来就该是独立的一条。
    public static func find(in trades: [Trade]) -> [Duplicate] {
        var groups: [String: [Trade]] = [:]
        for t in trades where !t.isSample {
            groups[t.fingerprint, default: []].append(t)
        }
        return groups.values.filter { $0.count > 1 }.map { g in
            let sorted = g.sorted {
                (richness($0), $0.id.uuidString) > (richness($1), $1.id.uuidString)
            }
            return Duplicate(keep: sorted[0], drop: Array(sorted.dropFirst()))
        }
        .sorted { $0.keep.openTimeOrDistantPast < $1.keep.openTimeOrDistantPast }
    }

    /// 要删掉的 id 全集。
    public static func idsToDrop(in trades: [Trade]) -> Set<UUID> {
        Set(find(in: trades).flatMap { $0.drop.map(\.id) })
    }
}
