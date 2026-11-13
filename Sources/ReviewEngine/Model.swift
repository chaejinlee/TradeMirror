import Foundation

/// 旧的单品种枚举。**保留只为读得懂 v1 存档**,新代码一律用 `Leg` / `LegKind`。
public enum Instrument: Codable, Sendable, Equatable {
    case stock, etf, leveragedETF
    case option(right: OptionRight, strike: Double, expiry: Date)

    public var isOption: Bool { if case .option = self { return true }; return false }
    public var multiplier: Double { isOption ? 100 : 1 }
    public var legKind: LegKind {
        if case .option(let r, let k, let e) = self { return .option(right: r, strike: k, expiry: e) }
        return .equity
    }
}

public enum Side: String, Codable, Sendable { case buy, sell }

/// 单笔成交。
///
/// ★ 为什么必须存到 fill 级(规范坑 #6 + 竞品 1 星差评):
/// 只存均价的话「浮亏 27.6% 时加仓」在数据里彻底消失;
/// 而竞品连「同一标的多次入场」都录不进去(「you can't include add-on buys」)。
public struct Fill: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    /// 属于哪条腿。`nil` = 第一条腿(单腿交易的省略写法,兼容 v1 存档)。
    public var legID: UUID?
    public var time: Date
    public var side: Side
    public var quantity: Double
    /// 成交价。期权是每股权利金,期货是点数,股票是股价。
    public var price: Double
    /// 成交当刻的**标的**价格。**可留空。**
    ///
    /// ★ 2026-09-01 用户实测反馈「填数字好烦,每次都得去查」。
    /// 查证后发现:这个字段在整个引擎里**只被用在两处,都是反解 IV,且都只用出场那一笔**。
    ///   · 线性品种(股票/ETF/期货/外汇):标的价 == 成交价,**根本不该问**
    ///   · 期权的开仓成交:完全用不到,**也不该问**
    ///   · 只有期权的**平仓**成交用得上,而且只影响「若在峰值出场」这一条反事实
    /// ⇒ 改成可选。**我原来在逼用户查一堆基本用不上的数。**
    public var underlying: Double?

    /// 这个时间是**App 填的默认值**,不是用户或截图给的。v13 新增。
    ///
    /// ★★ 2026-09-03 用户报:「今天我添加的几笔全都是 11 点的时间点,但实际上不是」。
    ///   录入页的时间默认是「最近一个交易日的 11:00」—— 一个**占位值**。
    ///   在不显示时间的年代它只影响排序,看不见;
    ///   而 v3.2 开始把时刻显示出来之后,<b>这个占位值就变成了一条假记录</b>。
    ///
    ///   ⇒ 规矩和这个 App 里其他地方一样:<b>不知道就说不知道,不许拿默认值冒充事实。</b>
    ///   (同 `displayablePnL` 未平仓返回 nil、`returnOnDebit` 贷记开仓返回 nil。)
    ///   时间本身还是要有一个 —— 排序、归日、路径切片都得用它 ——
    ///   但**显示层看到这个标记就不显示时刻**。
    public var timeIsEstimated: Bool = false

    public init(id: UUID = UUID(), legID: UUID? = nil, time: Date, side: Side,
                quantity: Double, price: Double, underlying: Double? = nil,
                timeIsEstimated: Bool = false) {
        self.id = id; self.legID = legID; self.time = time; self.side = side
        self.quantity = quantity; self.price = price; self.underlying = underlying
        self.timeIsEstimated = timeIsEstimated
    }

    // ★★ 必须手写解码。Swift 合成的 `init(from:)` **不会**用属性默认值,
    //   缺字段就抛 —— 旧存档(v12 及以前)没有 `timeIsEstimated`,
    //   合成版会让**整份存档读不出来**。v8 加 `trailingStopPct` 时已经栽过一次。
    private enum CodingKeys: String, CodingKey {
        case id, legID, time, side, quantity, price, underlying
        case timeIsEstimated                     // v13 才有
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id       = try c.decode(UUID.self, forKey: .id)
        legID    = try c.decodeIfPresent(UUID.self, forKey: .legID)
        time     = try c.decode(Date.self, forKey: .time)
        side     = try c.decode(Side.self, forKey: .side)
        quantity = try c.decode(Double.self, forKey: .quantity)
        price    = try c.decode(Double.self, forKey: .price)
        underlying = try c.decodeIfPresent(Double.self, forKey: .underlying)
        timeIsEstimated = try c.decodeIfPresent(Bool.self, forKey: .timeIsEstimated) ?? false
    }

    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(legID, forKey: .legID)
        try c.encode(time, forKey: .time)
        try c.encode(side, forKey: .side)
        try c.encode(quantity, forKey: .quantity)
        try c.encode(price, forKey: .price)
        try c.encodeIfPresent(underlying, forKey: .underlying)
        if timeIsEstimated { try c.encode(true, forKey: .timeIsEstimated) }
    }

    /// 有符号张数:买 +,卖 −。
    public var signedQuantity: Double { side == .buy ? quantity : -quantity }
    /// 有符号现金流:买 = 流出(负),卖 = 流入(正)。
    ///
    /// ★ 整个模型的地基。用它之后**做多/做空/借记价差/贷记价差/期货全都是同一个公式**,
    /// 不需要按方向分情况 —— 而分情况正是「做空的均价显示成平仓价」这类 bug 的来源。
    public func cashFlow(multiplier: Double) -> Double {
        (side == .sell ? 1 : -1) * price * quantity * multiplier
    }
}

/// 一笔交易(可含多条腿、多次加仓、分批出场)。
public struct Trade: Codable, Sendable, Identifiable {
    public var id: UUID
    public var symbol: String
    public var strategy: StrategyKind
    public var legs: [Leg]
    public var fills: [Fill]
    public var exitReason: String?
    /// 用户原话 —— ★ 规范坑 #5:结构化后丢弃会让心理线索全部消失。
    public var rawNoteAtEntry: String?
    public var rawNoteAtExit: String?
    /// 贴在这笔上的图(开仓时看到的图表等)。v3 新增。
    public var attachments: [Attachment] = []

    // ── v4:反事实的输入必须**存下来** ──
    // ★ 之前它们只是复盘页的 @State,关掉页面就没了 ⇒ **跨笔汇总根本做不了**。
    //   而「历史分析」的主角恰恰是反事实的累计,不是盈亏(盈亏券商 App 已经告诉你了)。
    /// 峰值时的标的价(用户填)。
    public var peakUnderlying: Double?
    /// 峰值出现的时刻(可选,不填按出场时刻近似)。
    public var peakTime: Date?
    /// 收盘/强平时的标的价(用户填)。
    public var finalUnderlying: Double?
    /// 是不是「看个例子」载入的示例交易。v8 新增。
    ///
    /// ★ 这个字段来自竞品的一句 1 星差评:
    /// 「it has an entire made up person that it shows you the app with…
    ///  **even after you delete the information it just continues to re-download**」
    /// ⇒ 示例数据必须:① 界面上明确标为示例 ② 一键删掉 ③ **删了绝不自己回来**。
    /// 而且它**不进任何统计** —— 否则用户的「历史分析」会被我编的数污染。
    public var isSample: Bool = false

    /// 开仓时的心理状态。v5 新增。
    /// **`beforeOutcome == false` 的不参与任何统计** —— 见 Psychology 的注释。
    public var psychology: Psychology?

    /// 开单原因。v12 新增。★ 汇总时按它分组 ——
    /// 「哪一类理由的单更常赢」比「胜率多少」有用得多。
    public var entryReason: String?
    /// 事前定的止损价(这条腿的价格,不是标的)。v12 新增。
    public var plannedStop: Double?
    /// 事前定的止盈价。v12 新增。
    public var plannedTarget: Double?

    /// 原因是**平仓之后**补填的(≥2 张截图拼出来的整笔、或事后想起来才填)。
    /// v13 新增。★ 和 `Psychology.beforeOutcome` 是同一件事:
    ///   结果已知之后回忆出来的理由,**必然被结果带着走**。
    ///   所以不删不改,但要**如实标出来**,汇总时能分开看。
    public var reasonsRecordedAfterOutcome: Bool = false

    /// 这一笔的**纪律自检**(照用户自己那本笔记本上的规矩逐条问)。v15 新增。
    /// ★ 没答过 = nil。**不许把「没答」当成「都做到了」。**
    public var discipline: DisciplineCheck?

    /// 计划 R:R = (目标−入场)/(入场−止损)。任一缺失就返回 nil,**不猜**。
    public var plannedRR: Double? {
        guard let stop = plannedStop, let target = plannedTarget else { return nil }
        let entry = averageEntry
        guard entry > 0 else { return nil }
        // 方向由首笔成交决定:多头腿止损在下,空头腿止损在上
        let long = legs.first.flatMap { openingSide(of: $0) } != .sell
        let risk = long ? entry - stop : stop - entry
        let reward = long ? target - entry : entry - target
        guard risk > 1e-9, reward > 0 else { return nil }
        return reward / risk
    }

    /// 止损**在你持仓期间**有没有被真的碰到过。需要真实分钟路径。
    ///
    /// ★★ 第一版没切窗口 —— 路径存到当天收盘,于是「你走之后价格跌到止损位」
    ///   也被算成「止损被触及」。那不是你的止损被检验,你早就出场了。
    ///   <b>这是同一个窗口错误的第三次</b>(前两次:真 MAE、moomoo 工具的终端打印)。
    ///   ⇒ 只看 **入场 → 出场** 这一段。
    ///
    /// ★ 「止损被触及过、而你没按它出场」比「止损从未被触发」更值得看 ——
    ///   前者是纪律问题,后者只是还没遇到。
    public func stopWasTouched() -> Bool? {
        guard let stop = plannedStop, let leg = legs.first,
              let raw = leg.path, !raw.isEmpty,
              let side = openingSide(of: leg),
              let entryAt = openingFills(of: leg).first?.time else { return nil }
        let exitAt = closingFills(of: leg).last?.time
        let held = PathAnalysis.slice(raw, from: entryAt, to: exitAt)
        guard !held.isEmpty else { return nil }
        return side == .buy ? held.contains { $0.l <= stop }
                            : held.contains { $0.h >= stop }
    }

    /// **标的**在这一天的真实分钟 K。v11 新增。
    ///
    /// ★ 期权腿拿不到自己的历史价(没有免费源),但**标的的分钟 K 是免费的**。
    ///   看不到那张期权怎么走,至少能看到 QQQ 当时是趋势还是来回磨 —— 那也是复盘要看的。
    ///   ⚠️ 它**不是**这条腿的价格,界面上必须写清楚,任何数字都不许从它算。
    public var underlyingPath: [PriceBar]?

    public init(id: UUID = UUID(), symbol: String, strategy: StrategyKind = .single,
                legs: [Leg], fills: [Fill], exitReason: String? = nil,
                rawNoteAtEntry: String? = nil, rawNoteAtExit: String? = nil,
                attachments: [Attachment] = [],
                peakUnderlying: Double? = nil, peakTime: Date? = nil,
                finalUnderlying: Double? = nil, psychology: Psychology? = nil,
                isSample: Bool = false) {
        self.id = id; self.symbol = symbol; self.strategy = strategy
        self.legs = legs; self.fills = fills; self.exitReason = exitReason
        self.rawNoteAtEntry = rawNoteAtEntry; self.rawNoteAtExit = rawNoteAtExit
        self.attachments = attachments
        self.peakUnderlying = peakUnderlying; self.peakTime = peakTime
        self.finalUnderlying = finalUnderlying; self.psychology = psychology
        self.isSample = isSample
    }

    /// 兼容旧调用方(单腿)。`isLong` 不再需要 —— 方向由**首笔成交是买还是卖**决定,
    /// 那是数据里真实存在的事实,比一个可以填错的布尔值可靠。
    public init(id: UUID = UUID(), symbol: String, instrument: Instrument, isLong: Bool = true,
                fills: [Fill], exitReason: String? = nil,
                rawNoteAtEntry: String? = nil, rawNoteAtExit: String? = nil) {
        let leg = Leg(kind: instrument.legKind)
        self.init(id: id, symbol: symbol, strategy: .single, legs: [leg], fills: fills,
                  exitReason: exitReason, rawNoteAtEntry: rawNoteAtEntry, rawNoteAtExit: rawNoteAtExit)
    }
}

// MARK: - 由 legs + fills 推导的一切(全部代码算,不交给任何模型)

public extension Trade {

    var primaryLeg: Leg? { legs.first }

    /// 这笔成交的有效标的价。
    /// **线性品种直接用成交价**(它们本来就相等),期权则只有用户填了才有。
    func effectiveUnderlying(of fill: Fill) -> Double? {
        if let u = fill.underlying, u > 0 { return u }
        guard let leg = leg(for: fill) else { return nil }
        return leg.kind.isOption ? nil : fill.price
    }

    /// 出场那一笔缺标的价 ⇒ 反解不出 IV ⇒ 「若在峰值出场」算不了。
    /// 界面据此明确告诉用户少了哪一条,而不是默默不显示。
    var missingExitUnderlying: Bool {
        guard let leg = legs.first(where: { $0.kind.isOption }) else { return false }
        guard let exit = closingFills(of: leg).last else { return false }
        return effectiveUnderlying(of: exit) == nil
    }
    var isMultiLeg: Bool { legs.count > 1 }

    /// 这条腿的乘数;找不到腿时退回第一条腿(兼容 legID == nil 的 v1 数据)。
    func multiplier(for fill: Fill) -> Double {
        (leg(for: fill) ?? primaryLeg)?.kind.multiplier ?? 1
    }
    func leg(for fill: Fill) -> Leg? {
        guard let lid = fill.legID else { return primaryLeg }
        return legs.first { $0.id == lid }
    }
    func fills(of leg: Leg) -> [Fill] {
        fills.filter { $0.legID == leg.id || ($0.legID == nil && leg.id == primaryLeg?.id) }
            .sorted { $0.time < $1.time }
    }

    /// 这条腿的开仓方向:**由首笔成交决定**。买在前 = 多头腿,卖在前 = 空头腿。
    func openingSide(of leg: Leg) -> Side? { fills(of: leg).first?.side }

    /// 开仓成交(与首笔同向的那些,含加仓)。
    func openingFills(of leg: Leg) -> [Fill] {
        guard let s = openingSide(of: leg) else { return [] }
        return fills(of: leg).filter { $0.side == s }
    }
    /// 平仓成交(与首笔反向的那些)。
    func closingFills(of leg: Leg) -> [Fill] {
        guard let s = openingSide(of: leg) else { return [] }
        return fills(of: leg).filter { $0.side != s }
    }

    /// 开完仓时这条腿的有符号持仓量(多头 +,空头 −)。反事实重定价要用它。
    func openedQuantity(of leg: Leg) -> Double {
        openingFills(of: leg).reduce(0) { $0 + $1.signedQuantity }
    }
    /// 当前净持仓(有符号)。0 = 已平。
    func netQuantity(of leg: Leg) -> Double {
        fills(of: leg).reduce(0) { $0 + $1.signedQuantity }
    }

    /// 开仓的净现金流。**负 = 净借记(你付钱),正 = 净贷记(你收钱)。**
    var openingCashFlow: Double {
        legs.reduce(0) { acc, leg in
            acc + openingFills(of: leg).reduce(0) { $0 + $1.cashFlow(multiplier: leg.kind.multiplier) }
        }
    }
    var closingCashFlow: Double {
        legs.reduce(0) { acc, leg in
            acc + closingFills(of: leg).reduce(0) { $0 + $1.cashFlow(multiplier: leg.kind.multiplier) }
        }
    }
    /// 净借记(付出去的钱)。贷记开仓时为 0。
    var netDebit: Double { max(-openingCashFlow, 0) }
    /// 净贷记(收进来的钱)。借记开仓时为 0。
    var netCredit: Double { max(openingCashFlow, 0) }

    /// 全部腿都平掉了才算平仓。
    var isClosed: Bool { !legs.isEmpty && legs.allSatisfy { abs(netQuantity(of: $0)) < 1e-9 }
                         && !fills.isEmpty }
    /// 未平仓的腿数与在手张数(展示用)。
    var openQuantity: Double { legs.reduce(0) { $0 + abs(netQuantity(of: $1)) } }

    /// 已实现盈亏 = 全部成交的有符号现金流之和。**对做多/做空/价差/期货一律成立。**
    var realizedPnL: Double { openingCashFlow + closingCashFlow }

    /// 这一笔的收益率。**分母是净借记 —— 你真正付出去的钱。**
    ///
    /// ★★ 贷记开仓(先收权利金:卖 put、卖价差)一律返回 `nil`。
    ///   收到的钱**不是本金**,真正的分母是占用的保证金或最大风险,
    ///   而这两个数 App 都没有。<b>宁可不给,也不给一个分母不对的百分比</b> ——
    ///   「$50 赚 $50 = 100%」和「押 $2,000 保证金赚 $50 = 2.5%」差 40 倍。
    ///
    /// ★ 未平仓同样是 `nil`(跟 `displayablePnL` 一致:持仓成本不是亏损)。
    var returnOnDebit: Double? {
        guard let p = displayablePnL, netDebit > 1e-9 else { return nil }
        return p / netDebit
    }

    /// 可以展示给用户的盈亏。**未平仓返回 nil,不返回一个看起来像亏损的数。**
    ///
    /// ★ 来自 2026-08-31 的实测 bug:只录了买入的一笔在列表里显示成红色 −$434。
    /// 那正是竞品 1 星差评里的「distorting P/L」。**未平仓的持仓成本不是亏损。**
    var displayablePnL: Double? { isClosed ? realizedPnL : nil }

    // ── 兼容旧接口(单腿时语义不变)──
    var buys:  [Fill] { fills.filter { $0.side == .buy  } }
    var sells: [Fill] { fills.filter { $0.side == .sell } }
    var totalBought: Double { buys.reduce(0)  { $0 + $1.quantity } }
    var totalSold:   Double { sells.reduce(0) { $0 + $1.quantity } }
    var costBasis: Double { buys.reduce(0) { $0 + $1.price * $1.quantity * multiplier(for: $1) } }
    var proceeds:  Double { sells.reduce(0) { $0 + $1.price * $1.quantity * multiplier(for: $1) } }

    /// 开仓均价(**按开仓方向算,不是按买入算**)。
    /// ★ 修了一个做空的真 bug:旧实现只看买入,做空时会把**平仓价**显示成入场价。
    var averageEntry: Double {
        let f = legs.flatMap { openingFills(of: $0) }
        let q = f.reduce(0) { $0 + $1.quantity }
        return q > 0 ? f.reduce(0) { $0 + $1.price * $1.quantity } / q : 0
    }
    var averageExit: Double {
        let f = legs.flatMap { closingFills(of: $0) }
        let q = f.reduce(0) { $0 + $1.quantity }
        return q > 0 ? f.reduce(0) { $0 + $1.price * $1.quantity } / q : 0
    }

    /// 逆势加仓:**与开仓同向、且此刻已浮亏**的那些成交。
    /// 做多时是「浮亏加买」,做空时是「涨上去了继续加卖」—— 同一个行为,两个方向。
    var addsWhileUnderwater: [(fill: Fill, unrealizedPct: Double)] {
        var out: [(Fill, Double)] = []
        for leg in legs {
            let opens = openingFills(of: leg)
            guard let first = opens.first else { continue }
            let sign: Double = first.side == .buy ? 1 : -1     // 多头腿 +1,空头腿 −1
            var qty = 0.0, cost = 0.0
            for f in opens {
                if qty > 0 {
                    let avg = cost / qty
                    let pct = sign * (f.price - avg) / avg * 100
                    if pct < 0 { out.append((f, pct)) }
                }
                qty += f.quantity; cost += f.price * f.quantity
            }
        }
        return out
    }
}

// MARK: - v1 → v2 存档迁移

extension Trade {
    private enum CodingKeys: String, CodingKey {
        case id, symbol, strategy, legs, fills, exitReason, rawNoteAtEntry, rawNoteAtExit
        case attachments                 // v3 才有
        case peakUnderlying, peakTime, finalUnderlying   // v4 才有
        case psychology                                  // v5 才有
        case isSample                                    // v8 才有
        case underlyingPath                              // v11 才有
        case entryReason, plannedStop, plannedTarget     // v12 才有
        case reasonsRecordedAfterOutcome                 // v13 才有
        case discipline                                  // v15 才有
        case instrument, isLong          // v1 才有
    }

    /// 宽容解码:v2 直接读 `legs`;**v1 没有 `legs`,就从 `instrument` 建一条腿**。
    ///
    /// ★ 这个 init 存在的唯一理由是竞品那句 1 星差评:「Update reset my results」。
    /// 升级后打开 App 发现数据没了,几乎总是因为**新版本读不动旧格式,然后当成空的存了回去**。
    /// 所以这里宁可多写几行,也不让旧数据解不出来。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id       = try c.decode(UUID.self, forKey: .id)
        symbol   = try c.decode(String.self, forKey: .symbol)
        fills    = try c.decode([Fill].self, forKey: .fills)
        exitReason     = try c.decodeIfPresent(String.self, forKey: .exitReason)
        rawNoteAtEntry = try c.decodeIfPresent(String.self, forKey: .rawNoteAtEntry)
        rawNoteAtExit  = try c.decodeIfPresent(String.self, forKey: .rawNoteAtExit)
        // v1/v2 存档没有这个字段 —— decodeIfPresent 让旧数据照样读得出来
        attachments    = try c.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        peakUnderlying  = try c.decodeIfPresent(Double.self, forKey: .peakUnderlying)
        peakTime        = try c.decodeIfPresent(Date.self,   forKey: .peakTime)
        finalUnderlying = try c.decodeIfPresent(Double.self, forKey: .finalUnderlying)
        psychology      = try c.decodeIfPresent(Psychology.self, forKey: .psychology)
        isSample        = try c.decodeIfPresent(Bool.self, forKey: .isSample) ?? false
        underlyingPath  = try c.decodeIfPresent([PriceBar].self, forKey: .underlyingPath)
        entryReason     = try c.decodeIfPresent(String.self, forKey: .entryReason)
        plannedStop     = try c.decodeIfPresent(Double.self, forKey: .plannedStop)
        plannedTarget   = try c.decodeIfPresent(Double.self, forKey: .plannedTarget)
        reasonsRecordedAfterOutcome =
            try c.decodeIfPresent(Bool.self, forKey: .reasonsRecordedAfterOutcome) ?? false
        discipline = try c.decodeIfPresent(DisciplineCheck.self, forKey: .discipline)

        if let ls = try c.decodeIfPresent([Leg].self, forKey: .legs), !ls.isEmpty {
            legs = ls
            strategy = try c.decodeIfPresent(StrategyKind.self, forKey: .strategy) ?? .single
        } else {
            // v1 存档:单品种 + isLong。方向不再需要 —— 首笔成交的买卖方向就是方向。
            let inst = try c.decode(Instrument.self, forKey: .instrument)
            legs = [Leg(kind: inst.legKind)]
            strategy = .single
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(symbol, forKey: .symbol)
        try c.encode(strategy, forKey: .strategy)
        try c.encode(legs, forKey: .legs)
        try c.encode(fills, forKey: .fills)
        try c.encodeIfPresent(exitReason, forKey: .exitReason)
        try c.encodeIfPresent(rawNoteAtEntry, forKey: .rawNoteAtEntry)
        try c.encodeIfPresent(rawNoteAtExit, forKey: .rawNoteAtExit)
        if !attachments.isEmpty { try c.encode(attachments, forKey: .attachments) }
        try c.encodeIfPresent(peakUnderlying,  forKey: .peakUnderlying)
        try c.encodeIfPresent(peakTime,        forKey: .peakTime)
        try c.encodeIfPresent(finalUnderlying, forKey: .finalUnderlying)
        try c.encodeIfPresent(psychology,      forKey: .psychology)
        if isSample { try c.encode(true, forKey: .isSample) }
        if let up = underlyingPath, !up.isEmpty { try c.encode(up, forKey: .underlyingPath) }
        try c.encodeIfPresent(entryReason,   forKey: .entryReason)
        try c.encodeIfPresent(plannedStop,   forKey: .plannedStop)
        try c.encodeIfPresent(plannedTarget, forKey: .plannedTarget)
        if reasonsRecordedAfterOutcome {
            try c.encode(true, forKey: .reasonsRecordedAfterOutcome)
        }
        try c.encodeIfPresent(discipline, forKey: .discipline)
    }
}

// MARK: - 逐腿明细(多腿组合要看得见每条腿贡献了多少)

public extension Trade {
    /// 这条腿的已实现盈亏 = 该腿全部成交的有符号现金流。
    func legPnL(_ leg: Leg) -> Double {
        fills(of: leg).reduce(0) { $0 + $1.cashFlow(multiplier: leg.kind.multiplier) }
    }
    /// 这条腿的开仓均价(按开仓方向,不是按买入)。
    func legEntry(_ leg: Leg) -> Double {
        let f = openingFills(of: leg); let q = f.reduce(0) { $0 + $1.quantity }
        return q > 0 ? f.reduce(0) { $0 + $1.price * $1.quantity } / q : 0
    }
    func legExit(_ leg: Leg) -> Double? {
        let f = closingFills(of: leg); let q = f.reduce(0) { $0 + $1.quantity }
        return q > 0 ? f.reduce(0) { $0 + $1.price * $1.quantity } / q : nil
    }
    /// 这条腿是否已平。
    func legIsClosed(_ leg: Leg) -> Bool { abs(netQuantity(of: leg)) < 1e-9 }
}
