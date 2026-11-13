import Foundation

/// **纪律手册** —— 用户自己那本笔记本上的规矩,搬进 App 里。
///
/// ★ 用户 2026-09-03 发来两页手写笔记:「整理好添加到复盘软件里,作为纪律手册。
///   并且完成每单就按照里面的问我遵守了哪些,没遵守哪些」。
///
/// ★★ 两条设计约束,都来自这个 App 一直在守的东西:
///   ① <b>内容必须可改。</b>种子清单是我**认手写字**认出来的 ——
///      认错一条,它就会在每一笔交易后面板着脸问一个他从没写过的规矩。
///      所以增删改全开,而且界面上写明「这是从你笔记本认出来的,请核对」。
///   ② <b>没勾 ≠ 遵守了。</b>三态:做到 / 没做到 / 没勾。
///      没勾就是没勾 —— 不许悄悄算成「做到了」去凑一个好看的守纪率。
public struct DisciplineRule: Codable, Sendable, Equatable, Identifiable {

    public enum Kind: String, Codable, Sendable {
        /// 要做到的
        case follow
        /// 要避开的
        case avoid
    }

    public var id: UUID
    public var text: String
    public var kind: Kind
    /// 关掉的不进检查表(留着但不问)。
    public var enabled: Bool
    public var order: Int

    public init(id: UUID = UUID(), text: String, kind: Kind,
                enabled: Bool = true, order: Int = 0) {
        self.id = id; self.text = text; self.kind = kind
        self.enabled = enabled; self.order = order
    }
}

public struct DisciplineBook: Codable, Sendable, Equatable {
    public var rules: [DisciplineRule]

    public init(rules: [DisciplineRule] = []) { self.rules = rules }

    public var isEmpty: Bool { rules.isEmpty }

    /// 要问的那些(启用的),按分类和顺序排好。
    public func active(_ kind: DisciplineRule.Kind) -> [DisciplineRule] {
        rules.filter { $0.kind == kind && $0.enabled }.sorted { $0.order < $1.order }
    }

    public var activeCount: Int { rules.filter(\.enabled).count }

    public func rule(_ id: UUID) -> DisciplineRule? { rules.first { $0.id == id } }
}

/// 一笔交易的纪律自检。
public struct DisciplineCheck: Codable, Sendable, Equatable {
    public var checkedAt: Date
    /// 做到了的规则 id。
    public var followed: [UUID]
    /// 没做到的。
    public var broken: [UUID]

    public init(checkedAt: Date = Date(), followed: [UUID] = [], broken: [UUID] = []) {
        self.checkedAt = checkedAt; self.followed = followed; self.broken = broken
    }

    /// ★★ 没勾的**不算遵守**。
    ///   把「没勾」算成「做到了」会让守纪率永远好看 ——
    ///   那是这个 App 最不该做的事:拿一个假数字让人安心。
    public var answered: Int { followed.count + broken.count }
    public var isEmpty: Bool { answered == 0 }

    /// 答过的里面做到了多少。**一条都没答时返回 nil,不返回 0 或 1。**
    public var followRate: Double? {
        answered > 0 ? Double(followed.count) / Double(answered) : nil
    }
}

// MARK: - 汇总

public struct DisciplineStats: Sendable, Equatable {
    public struct RuleTally: Sendable, Equatable, Identifiable {
        public var id: UUID { ruleID }
        public var ruleID: UUID
        public var text: String
        public var followed: Int
        public var broken: Int
        /// 破这条戒的那些交易,盈亏合计。
        public var brokenPnL: Double
        /// 守这条戒的那些交易,盈亏合计。
        public var followedPnL: Double

        public var total: Int { followed + broken }
        public var breakRate: Double? {
            total > 0 ? Double(broken) / Double(total) : nil
        }
    }

    /// 答过纪律自检的交易数。
    public var checkedTrades: Int
    /// 破戒的交易里,平均每笔盈亏。**一笔都没有时是 nil。**
    public var avgPnLWhenBroken: Double?
    /// 一条都没破的交易里,平均每笔盈亏。
    public var avgPnLWhenClean: Double?
    /// 按「破得最多」排。
    public var tallies: [RuleTally]

    /// 破戒那些单比守规矩的单**少赚多少**。任一边没有样本就返回 nil ——
    /// ★ 拿一个只有一边有样本的差额去下结论,是这个项目里最常见的那类假话。
    public var costOfBreaking: Double? {
        guard let b = avgPnLWhenBroken, let c = avgPnLWhenClean else { return nil }
        return b - c
    }
}

public enum DisciplineEngine {

    /// 汇总。★ 只算**已平仓且答过**的交易 ——
    ///   未平仓没有盈亏可比,没答过的更不能算「守了」。
    public static func compute(_ trades: [Trade], book: DisciplineBook) -> DisciplineStats {
        let checked = trades.filter {
            !$0.isSample && $0.isClosed && !($0.discipline?.isEmpty ?? true)
        }
        var tally: [UUID: DisciplineStats.RuleTally] = [:]
        var brokenPnLs: [Double] = []
        var cleanPnLs: [Double] = []

        for t in checked {
            guard let d = t.discipline else { continue }
            let pnl = t.realizedPnL
            if d.broken.isEmpty { cleanPnLs.append(pnl) } else { brokenPnLs.append(pnl) }

            for id in d.followed {
                var e = tally[id] ?? .init(ruleID: id, text: book.rule(id)?.text ?? "",
                                           followed: 0, broken: 0,
                                           brokenPnL: 0, followedPnL: 0)
                e.followed += 1; e.followedPnL += pnl
                e.text = book.rule(id)?.text ?? e.text
                tally[id] = e
            }
            for id in d.broken {
                var e = tally[id] ?? .init(ruleID: id, text: book.rule(id)?.text ?? "",
                                           followed: 0, broken: 0,
                                           brokenPnL: 0, followedPnL: 0)
                e.broken += 1; e.brokenPnL += pnl
                e.text = book.rule(id)?.text ?? e.text
                tally[id] = e
            }
        }

        func avg(_ xs: [Double]) -> Double? {
            xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
        }

        return DisciplineStats(
            checkedTrades: checked.count,
            avgPnLWhenBroken: avg(brokenPnLs),
            avgPnLWhenClean: avg(cleanPnLs),
            // 破得最多的排前面;一样多时按名字稳定排序,免得每次刷新顺序都变
            tallies: tally.values.sorted {
                $0.broken == $1.broken ? $0.text < $1.text : $0.broken > $1.broken
            })
    }
}
