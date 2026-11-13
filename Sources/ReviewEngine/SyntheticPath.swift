import Foundation

/// 没有真实分钟数据时,按成交点造一条**示意 K 线**。
///
/// ★★ 铁律:**造出来的东西必须标成造的。**
///   这个 App 的整个立场是「算得对」,所以示意图只能用来<b>看形状</b>,
///   界面上必须写明「示意」,而且**任何数字都不许从它算**。
///   真实路径(`Leg.path`,来自 moomoo)一旦存在,就绝不用这个。
///
/// ★ 为什么还要做:一笔交易只有两三个成交点时,光看数字读不出「当时是怎么走的」。
///   把成交点摆在一条**确定性**的走势上,至少能一眼看出加仓在哪、出场在哪。
///
/// ★ 为什么必须确定性(用 trade id 做种子):
///   每次刷新都换一条形状的图 = 用户会以为数据在变。**假数据尤其不能乱动。**
public enum SyntheticPath {

    /// 一个最小的确定性伪随机数发生器(LCG)。不用系统随机源 —— 那会每次都不一样。
    private struct Seeded {
        var state: UInt64
        init(_ seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double((state >> 33) & 0xFFFFFF) / Double(0xFFFFFF)   // [0,1)
        }
        /// [-1, 1]
        mutating func signed() -> Double { next() * 2 - 1 }
    }

    /// 用成交点当锚,插出 `barsPerSegment` 根一段的示意 K 线。
    ///
    /// - Parameters:
    ///   - anchors: 按时间排好的 (时刻, 成交价)。少于 2 个返回空。
    ///   - seed: 用 `trade.id.hashValue` 之类的稳定值,保证每次画出来一样。
    public static func bars(anchors: [(t: Date, px: Double)],
                            seed: UInt64,
                            barsPerSegment: Int = 8) -> [PriceBar] {
        guard anchors.count >= 2, barsPerSegment >= 1 else { return [] }
        let pts = anchors.sorted { $0.t < $1.t }
        // 波动幅度按整段价格区间取,免得在 1.34→2.41 和 400→410 上画出同样夸张的影线
        let lo = pts.map(\.px).min()!, hi = pts.map(\.px).max()!
        let amp = max((hi - lo) * 0.18, hi * 0.004)
        var rng = Seeded(seed)
        var out: [PriceBar] = []

        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1]
            let dt = b.t.timeIntervalSince(a.t) / Double(barsPerSegment)
            var prevClose = a.px
            for k in 0..<barsPerSegment {
                let f = Double(k + 1) / Double(barsPerSegment)
                // 线性插值 + 中间鼓一点的噪声(两端收紧,保证穿过真实成交价)
                let taper = sin(f * .pi)
                let close = (k == barsPerSegment - 1)
                    ? b.px                                   // ★ 段尾必须**正好**落在成交价上
                    : a.px + (b.px - a.px) * f + rng.signed() * amp * taper
                let open = prevClose
                let wick = abs(rng.signed()) * amp * 0.6 * (taper + 0.2)
                out.append(PriceBar(t: a.t.addingTimeInterval(dt * Double(k + 1)),
                                    h: max(open, close) + wick,
                                    l: max(0, min(open, close) - wick),
                                    c: close))
                prevClose = close
            }
        }
        return out
    }

    /// 直接从一笔交易造。**只在这条腿没有真实路径时用。**
    public static func bars(for trade: Trade, leg: Leg, barsPerSegment: Int = 8) -> [PriceBar] {
        if let real = leg.path, !real.isEmpty { return real }
        let anchors = trade.fills(of: leg).map { (t: $0.time, px: $0.price) }
        var h = UInt64(bitPattern: Int64(leg.id.hashValue))
        h = h &+ UInt64(bitPattern: Int64(trade.id.hashValue))
        return bars(anchors: anchors, seed: h, barsPerSegment: barsPerSegment)
    }
}
