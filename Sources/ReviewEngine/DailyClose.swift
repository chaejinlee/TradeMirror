import Foundation

/// 每日收盘价簿。
///
/// ★ 来自 2026-09-01 用户的一句话:「不该一遍又一遍查找然后输入」。
/// 查证后发现最典型的例子就是收盘价 —— **同一天、同一标的,它是同一个数**。
/// 一天做 5 笔 QQQ,我却让用户查了 5 遍。
///
/// ⇒ 填一次,那天该标的的**所有**交易都能算反事实;
///   以后再补录那天的交易,也自动带出来。
/// **这是「录入越用越快」的机制,不是缓存优化。**
public struct DailyCloseBook: Codable, Sendable, Equatable {
    /// key = "QQQ|2026-09-01"
    public private(set) var closes: [String: Double]

    public init(closes: [String: Double] = [:]) { self.closes = closes }

    public var isEmpty: Bool { closes.isEmpty }

    public static func key(symbol: String, day: String) -> String {
        "\(symbol.uppercased())|\(day)"
    }
    public static func key(for trade: Trade) -> String? {
        trade.tradingDayKey.map { key(symbol: trade.symbol, day: $0) }
    }

    public func close(for trade: Trade) -> Double? {
        Self.key(for: trade).flatMap { closes[$0] }
    }

    public mutating func set(_ price: Double?, for trade: Trade) {
        guard let k = Self.key(for: trade) else { return }
        if let p = price, p > 0 { closes[k] = p } else { closes.removeValue(forKey: k) }
    }

    /// 这个收盘价会影响哪些交易(用来告诉用户「填一次,N 笔都算得出来了」)。
    public func affectedTrades(_ trades: [Trade], symbol: String, day: String) -> [Trade] {
        trades.filter { $0.symbol.uppercased() == symbol.uppercased() && $0.tradingDayKey == day }
    }
}

public extension Trade {
    /// 有效的收盘价:**本笔自己填的优先,没有就用当天该标的的公共收盘价。**
    func effectiveFinalUnderlying(_ book: DailyCloseBook) -> Double? {
        finalUnderlying ?? book.close(for: self)
    }
}
