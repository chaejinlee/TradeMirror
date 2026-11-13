import Foundation

/// 批量导入:一次选多张截图 → 自动配对成交易 → 一次确认。
///
/// ★ 来自用户 2026-09-01 的反馈:「不该一遍又一遍查找然后输入」。
/// 一笔完整交易在 Wealthsimple 是**两个详情页 = 两张截图**,
/// 一天做 5 笔就是 10 张 —— 原来要走 10 遍流程。
///
/// 这里做两件事:
/// 1. **批内配对**:同一合约的买/卖自动归到同一笔
/// 2. **与已有交易配对**:能并进 App 里未平的仓就并进去
public enum BatchImporter {

    /// 一个待确认的结果。
    public struct Draft: Identifiable, Sendable {
        public var id = UUID()
        /// 并进这笔已有交易(nil = 新建)。
        public var mergeInto: Trade?
        /// 组成这一笔的截图解析结果,按时间排序。
        public var parts: [ParsedTrade]
        /// 说明为什么这么归组,给用户核对。
        public var reason: String
    }

    /// - Parameters:
    ///   - parsed: 每张截图的解析结果
    ///   - existing: App 里已有的交易
    public static func group(_ parsed: [ParsedTrade], existing: [Trade]) -> [Draft] {
        // 按时间排序:先开仓后平仓,顺序错了会把方向判反
        let items = parsed.sorted {
            (minutes($0) ?? .greatestFiniteMagnitude) < (minutes($1) ?? .greatestFiniteMagnitude)
        }
        var drafts: [Draft] = []

        for p in items {
            // ① 能并进已有的未平仓位?
            if let m = TradeMatcher.find(for: p, in: existing),
               !drafts.contains(where: { $0.mergeInto?.id == m.trade.id }) {
                drafts.append(Draft(mergeInto: m.trade, parts: [p], reason: m.reason))
                continue
            }
            // ② 能并进这一批里已经建好的组?
            if let i = drafts.firstIndex(where: {
                guard let head = $0.parts.first else { return false }
                return sameContract(head, p) && !isFlat($0)
            }) {
                drafts[i].parts.append(p)
                drafts[i].reason = String(format: L("同一合约的开仓与平仓,来自 %d 张截图"),
                                          drafts[i].parts.count)
                continue
            }
            // ③ 新建
            drafts.append(Draft(mergeInto: nil, parts: [p], reason: L("新的一笔")))
        }

        // ★★ 2026-09-23 用户报「这两张放进去记录不进去」。
        //
        //   他导的是 BEX 买 130 股 + 隔天卖 130 股 —— <b>一笔完整的来回</b>,
        //   券商自己在卖出那张上印着 `+$41.69 return`。
        //   而他库里还有一笔 8 月开的、467 股的 BEX 波段仓。
        //   ①「同一标的就并」把这来回<b>吞进了那个老仓位</b>:
        //   净量 467+130−130 = 467 没变、日期还是 8/5、还是「未平仓」、没有盈亏
        //   ⇒ <b>屏幕上前后一模一样。数据进去了,他什么也看不到。</b>
        //
        // ★★ 判据:<b>这一组自己就已经平了</b>(买卖数量相抵)⇒ 它是独立的一笔,
        //   不该并进任何别的仓位。并进去等于把一笔可复盘的交易溶掉。
        //   ★ 这也是券商月结单的口径 —— 它按**成交来回**列,不按持仓。
        for i in drafts.indices where drafts[i].mergeInto != nil && isFlat(drafts[i]) {
            drafts[i].mergeInto = nil
            drafts[i].reason = String(format: L("自成一笔的来回(%d 张截图)—— 不并进已有仓位"),
                                      drafts[i].parts.count)
        }
        return drafts
    }

    /// 这一组的买卖数量是否已经平掉 —— 平掉了就不再往里加。
    static func isFlat(_ d: Draft) -> Bool {
        let net = d.parts.reduce(0.0) { acc, p in
            guard let q = p.quantity?.value, let s = p.side?.value else { return acc }
            return acc + (s == .buy ? q : -q)
        }
        return abs(net) < 1e-9 && d.parts.count >= 2
    }

    /// 同一个合约?期权要 Call/Put + 行权价都一致;线性品种同标的即可。
    static func sameContract(_ a: ParsedTrade, _ b: ParsedTrade) -> Bool {
        guard let sa = a.symbol?.value.uppercased(), let sb = b.symbol?.value.uppercased(),
              sa == sb else { return false }
        switch (a.right?.value, b.right?.value) {
        case (nil, nil): return true
        case let (ra?, rb?):
            guard ra == rb else { return false }
            guard let ka = a.strike?.value, let kb = b.strike?.value else { return false }
            return abs(ka - kb) < 1e-6
        default: return false     // 一个是期权一个不是
        }
    }

    private static func minutes(_ p: ParsedTrade) -> Double? {
        guard let t = p.time?.value, let h = t.hour else { return nil }
        return Double(h) * 60 + Double(t.minute ?? 0)
    }
}
