import Foundation

/// 开仓时的心理状态。
///
/// ★★ 整个设计围绕规范 [C5] 那一条:
/// **「行为诊断必须锚定可观测证据,禁止凭盈亏结果反推心理状态。」**
///
/// 事后录入交易时,你**已经知道结果了** —— 那时候选的心情必然被污染
/// (赚了选「冷静」,亏了选「冲动」)。这不是数据,是事后叙事。
/// ⇒ 所以 `beforeOutcome` 是这个结构里**最重要的字段**:
///   统计时**只用它为 true 的那些**;false 的单独列出但不参与任何结论。
public struct Psychology: Codable, Sendable, Equatable {
    public var states: [String]
    /// 1–5。规范 profile 里的硬规则是「信心度 < 4 不开单」。
    public var confidence: Int
    /// 原话。规范 §2.7:关键发现常常来自措辞,不是枚举字段。
    public var plan: String?
    public var recordedAt: Date
    /// ★ 这条是不是在**知道结果之前**记的。
    public var beforeOutcome: Bool
    /// ★★ 开仓那一刻的纪律检查**冻结快照**。规范 §2.3:绝对不要事后重算。
    public var ruleSnapshot: RuleSnapshot?

    public init(states: [String], confidence: Int, plan: String? = nil,
                recordedAt: Date = Date(), beforeOutcome: Bool,
                ruleSnapshot: RuleSnapshot? = nil) {
        self.states = states; self.confidence = confidence; self.plan = plan
        self.recordedAt = recordedAt; self.beforeOutcome = beforeOutcome
        self.ruleSnapshot = ruleSnapshot
    }

    /// 可选的状态词表。
    ///
    /// ★ 刻意都是**当下能观察到的状态**,不是事后才能下的诊断。
    /// 「损失厌恶」「锚定效应」这类是**结论**,不该让用户在开仓时勾 ——
    /// 那等于让他先给自己贴标签,再去找证据。
    public static let vocabulary: [String] = [
        "按计划,没情绪",
        "有把握",
        "犹豫,不确定",
        "怕错过",
        "想把之前的亏补回来",
        "手痒,闲不住",
        "上头了",
        "累,注意力不集中",
        "被别人的观点带着走",
    ]

    /// 这些状态在用户自述的死亡模式里出现过 —— 勾中时界面要提醒。
    public static let redFlags: Set<String> = [
        "想把之前的亏补回来", "上头了", "手痒,闲不住",
    ]
    public var hasRedFlag: Bool { states.contains { Psychology.redFlags.contains($0) } }
}

/// 开仓前记下的计划,还没对应到具体成交。
///
/// 存在的理由:用户是**事后**从截图录交易的,而心理状态必须**事前**记 ——
/// 这两个时刻对不上,所以需要一个中间对象把它们接起来。
public struct PendingPlan: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var symbol: String
    public var psychology: Psychology
    public init(id: UUID = UUID(), symbol: String, psychology: Psychology) {
        self.id = id; self.symbol = symbol; self.psychology = psychology
    }
}

public enum PlanMatcher {
    /// 找出这笔交易可能对应的开仓前计划:同标的,且计划记录时间在**首笔成交之前**、
    /// 且不超过 `window` 小时。
    /// **计划记在成交之后的一律不匹配** —— 那就不是「事前」了。
    public static func find(for trade: Trade, in plans: [PendingPlan],
                            window: TimeInterval = 6 * 3600) -> PendingPlan? {
        guard let entry = trade.fills.map(\.time).min() else { return nil }
        return plans
            .filter { $0.symbol.uppercased() == trade.symbol.uppercased() }
            .filter { $0.psychology.recordedAt <= entry
                      && entry.timeIntervalSince($0.psychology.recordedAt) <= window }
            .max { $0.psychology.recordedAt < $1.psychology.recordedAt }   // 取最近的那条
    }
}
