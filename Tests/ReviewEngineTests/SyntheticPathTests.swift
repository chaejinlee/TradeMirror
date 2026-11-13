import XCTest
@testable import ReviewEngine

/// 示意 K 线。★ 造出来的东西的底线:**确定性** + **穿过真实成交价** + **绝不冒充真实路径**。
final class SyntheticPathTests: XCTestCase {

    private let t0 = ISO8601DateFormatter().date(from: "2026-09-01T14:13:00Z")!

    private var anchors: [(t: Date, px: Double)] {
        [(t0, 1.34), (t0.addingTimeInterval(1320), 2.41)]
    }

    func testDeterministicAcrossCalls() {
        // ★ 每次刷新换一条形状 = 用户会以为数据在变。**假数据尤其不能乱动。**
        let a = SyntheticPath.bars(anchors: anchors, seed: 42)
        let b = SyntheticPath.bars(anchors: anchors, seed: 42)
        XCTAssertEqual(a.map(\.c), b.map(\.c))
        XCTAssertEqual(a.map(\.h), b.map(\.h))
    }

    func testDifferentSeedsGiveDifferentShapes() {
        XCTAssertNotEqual(SyntheticPath.bars(anchors: anchors, seed: 1).map(\.c),
                          SyntheticPath.bars(anchors: anchors, seed: 2).map(\.c))
    }

    func testPassesThroughEveryRealFillPrice() {
        // ★ 形状可以是编的,**成交价不能**。段尾必须正好落在真实成交价上。
        let three = [(t0, 1.34), (t0.addingTimeInterval(600), 1.10),
                     (t0.addingTimeInterval(1320), 2.41)]
        let bars = SyntheticPath.bars(anchors: three, seed: 7, barsPerSegment: 5)
        XCTAssertEqual(bars.count, 10)
        XCTAssertEqual(bars[4].c, 1.10, accuracy: 1e-9)
        XCTAssertEqual(bars[9].c, 2.41, accuracy: 1e-9)
    }

    func testHighLowAlwaysBracketOpenAndClose() {
        for bar in SyntheticPath.bars(anchors: anchors, seed: 99) {
            XCTAssertGreaterThanOrEqual(bar.h, bar.c)
            XCTAssertLessThanOrEqual(bar.l, bar.c)
            XCTAssertGreaterThanOrEqual(bar.h, bar.l)
        }
    }

    func testNeverGoesNegative() {
        // 期权价可以很小;影线不能把它拉到负数
        for bar in SyntheticPath.bars(anchors: [(t0, 0.05), (t0.addingTimeInterval(600), 0.02)],
                                      seed: 3) {
            XCTAssertGreaterThanOrEqual(bar.l, 0)
        }
    }

    func testTimeIsMonotonic() {
        let bars = SyntheticPath.bars(anchors: anchors, seed: 5)
        XCTAssertEqual(bars.map(\.t), bars.map(\.t).sorted())
    }

    func testOneAnchorGivesNothingRatherThanAFakeChart() {
        XCTAssertTrue(SyntheticPath.bars(anchors: [(t0, 1.34)], seed: 1).isEmpty)
        XCTAssertTrue(SyntheticPath.bars(anchors: [], seed: 1).isEmpty)
    }

    func testRealPathAlwaysWins() {
        // ★ 有真实路径就**绝不**用示意的
        var leg = Leg(kind: .equity)
        let real = [PriceBar(t: t0, h: 2, l: 1, c: 1.5)]
        leg.path = real
        let t = Trade(symbol: "QQQ", strategy: .single, legs: [leg], fills: [
            Fill(legID: leg.id, time: t0, side: .buy, quantity: 1, price: 1.34),
            Fill(legID: leg.id, time: t0.addingTimeInterval(600), side: .sell,
                 quantity: 1, price: 2.41),
        ])
        XCTAssertEqual(SyntheticPath.bars(for: t, leg: leg), real)
    }

    func testWorksForEveryInstrumentKind() {
        // 股票 / 期权 / 期货 / 外汇 —— 都只是价格序列,不该有品种特判
        let kinds: [LegKind] = [
            .equity,
            .option(right: .call, strike: 708, expiry: Date()),
            .futures(contract: "MNQ", pointValue: 2, tickSize: 0.25),
            .forex(contractSize: 100_000),
        ]
        for kind in kinds {
            let leg = Leg(kind: kind)
            let t = Trade(symbol: "X", strategy: .single, legs: [leg], fills: [
                Fill(legID: leg.id, time: t0, side: .buy, quantity: 1, price: 100),
                Fill(legID: leg.id, time: t0.addingTimeInterval(600), side: .sell,
                     quantity: 1, price: 110),
            ])
            XCTAssertFalse(SyntheticPath.bars(for: t, leg: leg).isEmpty,
                           "\(kind) 应该也能画出示意 K 线")
        }
    }
}
