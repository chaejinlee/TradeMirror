import XCTest
@testable import ReviewEngine

/// 心理标签。整个设计围绕规范 [C5]:
/// **禁止凭盈亏结果反推心理状态** —— 所以「是不是事前记的」是最重要的字段。
final class PsychologyTests: XCTestCase {

    private func t(_ hh: Int, _ mm: Int, day: Int = 1) -> Date {
        var c = DateComponents(); c.year = 2026; c.month = 9; c.day = day
        c.hour = hh; c.minute = mm; c.timeZone = TradingDay.exchangeTimeZone
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    private func trade(day: Int, pnlPositive: Bool, psy: Psychology?) -> Trade {
        let leg = Leg(kind: .equity)
        return Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: t(10, 0, day: day), side: .buy,  quantity: 10, price: 100),
            Fill(legID: leg.id, time: t(11, 0, day: day), side: .sell, quantity: 10,
                 price: pnlPositive ? 110 : 90),
        ], psychology: psy)
    }

    /// ★★ 事后补记的心理标签**不许进统计** —— 它必然被结果污染。
    func testAfterTheFactPsychologyIsExcludedFromStats() {
        let before = Psychology(states: ["上头了"], confidence: 3,
                                recordedAt: t(9, 0), beforeOutcome: true)
        let after  = Psychology(states: ["按计划,没情绪"], confidence: 5,
                                recordedAt: t(16, 0), beforeOutcome: false)
        let s = PortfolioStats.compute([
            trade(day: 1, pnlPositive: false, psy: before),
            trade(day: 2, pnlPositive: true,  psy: after),
        ])
        XCTAssertEqual(s.afterTheFactPsychology, 1, "事后补的要单独计数")
        XCTAssertEqual(s.stateOutcomes.count, 1, "只有事前那条进统计")
        XCTAssertEqual(s.stateOutcomes.first?.id, "上头了")
        XCTAssertFalse(s.stateOutcomes.contains { $0.id == "按计划,没情绪" },
                       "★ 事后补的绝不能出现在关联统计里")
    }

    /// 红旗状态要排在最前面(它们是用户自述死亡模式的成分)。
    func testRedFlagStatesSortFirst() {
        let calm = Psychology(states: ["按计划,没情绪"], confidence: 5,
                              recordedAt: t(9, 0), beforeOutcome: true)
        let tilt = Psychology(states: ["想把之前的亏补回来"], confidence: 2,
                              recordedAt: t(9, 0, day: 2), beforeOutcome: true)
        let s = PortfolioStats.compute([
            trade(day: 1, pnlPositive: true, psy: calm),
            trade(day: 1, pnlPositive: true, psy: calm),
            trade(day: 2, pnlPositive: false, psy: tilt),
        ])
        XCTAssertEqual(s.stateOutcomes.first?.id, "想把之前的亏补回来",
                       "红旗要排最前,哪怕样本更少")
        XCTAssertTrue(s.stateOutcomes.first?.isRedFlag ?? false)
    }

    /// 词表里全是**当下能观察到的状态**,不该出现「损失厌恶」这类事后诊断。
    func testVocabularyContainsNoPostHocDiagnoses() {
        let diagnoses = ["损失厌恶", "锚定效应", "确认偏误", "过度自信"]
        for d in diagnoses {
            XCTAssertFalse(Psychology.vocabulary.contains(d),
                           "「\(d)」是结论不是状态,不该让用户在开仓时勾")
        }
        XCTAssertTrue(Psychology.vocabulary.contains("按计划,没情绪"))
        XCTAssertTrue(Psychology.hasRedFlagVocabulary)
    }

    /// 计划只能匹配到**在它之后**发生的成交 —— 记在成交之后的不算「事前」。
    func testPlanOnlyMatchesLaterFills() {
        let leg = Leg(kind: .equity)
        let tr = Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: t(10, 0), side: .buy, quantity: 10, price: 100)])

        let earlier = PendingPlan(symbol: "QQQ", psychology:
            .init(states: ["有把握"], confidence: 4, recordedAt: t(9, 30), beforeOutcome: true))
        let later = PendingPlan(symbol: "QQQ", psychology:
            .init(states: ["上头了"], confidence: 2, recordedAt: t(10, 30), beforeOutcome: true))
        XCTAssertEqual(PlanMatcher.find(for: tr, in: [earlier, later])?.id, earlier.id,
                       "★ 记在成交之后的不算事前")

        let tooOld = PendingPlan(symbol: "QQQ", psychology:
            .init(states: ["有把握"], confidence: 4, recordedAt: t(10, 0, day: -1),
                  beforeOutcome: true))
        XCTAssertNil(PlanMatcher.find(for: tr, in: [tooOld]), "超出时间窗的不匹配")

        let otherSym = PendingPlan(symbol: "SPY", psychology:
            .init(states: ["有把握"], confidence: 4, recordedAt: t(9, 30), beforeOutcome: true))
        XCTAssertNil(PlanMatcher.find(for: tr, in: [otherSym]))
    }

    /// 没记心理状态的笔数要进 never_happened,并说明「只有事前记的才算数」。
    func testMissingPsychologyIsSurfaced() {
        let s = PortfolioStats.compute([trade(day: 1, pnlPositive: true, psy: nil)])
        XCTAssertTrue(s.neverHappened.contains { $0.contains("心理状态") && $0.contains("开仓前") })
    }
}

extension Psychology {
    /// 测试辅助:词表里确实标了红旗项。
    static var hasRedFlagVocabulary: Bool {
        !vocabulary.filter { redFlags.contains($0) }.isEmpty
    }
}
