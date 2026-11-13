import Foundation

/// 一条反事实的判定。
///
/// ★ 规范 [C7]:反事实**不预设方向**。
/// 差额为负(替代方案更差)同样要呈现 —— 那是用户**做对了**的证据。
/// 只算一个方向的反事实计算器,会退化成后悔生成器。
public enum Verdict: String, Codable, Sendable {
    /// 替代方案更好 —— 你少赚了 / 多亏了。
    case alternativeWasBetter
    /// 你的做法更好 —— 换成那个方案会更差。**这一条必须和上一条同等显示。**
    case youWereBetter
    case effectivelyTied
}

/// 计算这条反事实需要哪些**外部输入**。
/// 存在的理由:v1 不联行情源(免费数据源普遍禁止再分发),缺什么必须说清楚,不许猜。
public enum DataRequirement: String, Codable, Sendable {
    case fillsOnly                 // 只靠成交明细,一定算得出
    case userProvidedPeak          // 需要用户填「峰值时的标的价」
    case userProvidedFinal         // 需要用户填「收盘/到期时的标的价」
    /// 需要分钟级路径。v1.8 起:股票/期货/外汇点「自动填」就有,
    /// **期权仍然没有**(没有免费源),只能走 tools/moomoo_enrich.py。
    case intradayPath
}

/// 反事实的身份。**用枚举而不是裸字符串。**
///
/// ★★ 2026-09-01 一晚上被同一个形状咬了**三次**:
///   短标签抄了 2 份、「收盘值多少」抄了 3 份、排序表抄了 2 份。
///   每次都是加了新反事实、只改了其中一份 —— <b>而且不会有任何报错</b>。
///
///   收敛成「唯一一份」只解决了当下,没解决**下一次**:
///   下次再加一张卡,我照样可能忘了登记短标签或排序。
///   ⇒ 改成枚举 + **穷尽 switch**:<b>忘了登记 = 编译不过</b>。
///     这才是「机制会自己失败」,而不是「我记得要去改」。
public enum CFID: String, CaseIterable, Sendable {
    case holdToClose    = "hold_to_close"
    case scaleOutHold   = "scale_out_hold"
    case scaleOutTrail  = "scale_out_trail"
    case trailingStop   = "trailing_stop"
    case noAddOn        = "no_add_on"
    /// ★ 唯一**不可执行**的一张(事后视角)。排序永远垫底,也不参与主角数字。
    case exitVsPeak     = "exit_vs_peak"

    /// 图上用的短标签。**穷尽 switch —— 加了 case 不写这里就编译不过。**
    public var shortLabel: String {
        switch self {
        case .holdToClose:   return L("拿到收盘")
        case .scaleOutHold:  return L("平一半")
        case .scaleOutTrail: return L("平一半+跟踪")
        case .trailingStop:  return L("移动止损")
        case .noAddOn:       return L("不加仓")
        case .exitVsPeak:    return L("峰值出场")
        }
    }

    /// 展示顺序:**可执行的在前,事后视角的最后**(规范 §3.1)。同样是穷尽 switch。
    public var rank: Int {
        switch self {
        case .holdToClose:   return 0
        case .scaleOutHold:  return 1
        case .scaleOutTrail: return 2
        case .trailingStop:  return 3
        case .noAddOn:       return 4
        case .exitVsPeak:    return 999      // 永远垫底
        }
    }

    /// 能不能照着做。峰值那张不能 —— 没人卖得在最高点。
    public var isExecutable: Bool { self != .exitVsPeak }
}

/// 展示顺序。**只留这一份。**
///
/// 规范 §3.1:**可执行的在前,事后视角的在最后。**
///
/// ★★ 2026-09-01 一晚上踩了**三次**同一个形状:短标签抄了两份、
///   「收盘值多少」抄了三份、这张排序表抄了两份
///   (`Counterfactuals` 里改了,`PortfolioStats` 里那份没改)。
///   <b>同一个映射有 N 份副本,就有 N−1 份迟早是过期的。</b>
///   ⇒ 凡是「id → 某个属性」的表,一律只留一份,放在这里。
public func counterfactualRank(_ id: String) -> Int {
    CFID(rawValue: id)?.rank ?? 500             // 认不出的排中间,绝不越过 999
}

/// 图上用的短标签。**只留这一份。**
///
/// ★ 2026-09-01 踩到:同一张对照表在 `ReviewView` 和 `HistoryView` 各抄了一遍。
///   加了两个新反事实后我只改了一处,分叉图上直接画出了 `scale_out_trail` 这串原始 id。
///   ⇒ 同一个映射有两份副本,就等于有一份迟早是过期的。
public func counterfactualShortLabel(_ id: String) -> String {
    CFID(rawValue: id)?.shortLabel ?? id
}

public struct Counterfactual: Codable, Sendable, Identifiable {
    public var id: String
    public var label: String
    /// 替代方案下的盈亏(美元)。
    public var alternativePnL: Double
    /// 实际盈亏(美元)。
    public var actualPnL: Double
    /// 差额 = 替代 − 实际。**正数表示替代方案更好。**
    public var delta: Double { alternativePnL - actualPnL }
    public var verdict: Verdict {
        if abs(delta) < 0.5 { return .effectivelyTied }
        return delta > 0 ? .alternativeWasBetter : .youWereBetter
    }
    public var requirement: DataRequirement
    /// 口径说明。任何用到模型定价的地方都必须写清 IV 与时间口径。
    public var note: String?

    public init(id: String, label: String, alternativePnL: Double, actualPnL: Double,
                requirement: DataRequirement, note: String? = nil) {
        self.id = id; self.label = label
        self.alternativePnL = alternativePnL; self.actualPnL = actualPnL
        self.requirement = requirement; self.note = note
    }
}

public enum CounterfactualEngine {

    // MARK: - 逐腿定价(多腿组合的地基)

    /// 单条腿在给定标的价与时刻下的**每单位报价**。
    /// 期权走 BS(用这条腿自己的到期日 —— 日历价差各腿到期日不同);其余线性。
    /// 缺 IV 时返回 nil,**不猜**。
    public static func legPrice(_ leg: Leg, underlying: Double, at time: Date,
                                sigma: Double?, basis: TimeBasis = .tradingTime) -> Double? {
        switch leg.kind {
        case .option(let right, let strike, let expiry):
            let h = TradingDay.hoursToExpiry(from: time, expiryDay: expiry)
            if h <= 0 { return max(right == .call ? underlying - strike : strike - underlying, 0) }
            guard let sig = sigma else { return nil }
            return BlackScholes.price(right: right, spot: underlying, strike: strike,
                                      years: basis.years(hoursToExpiry: h), sigma: sig)
        case .equity, .futures, .forex:
            return underlying          // 线性品种:报价即标的价
        }
    }

    /// 由某条腿**自己的最后一笔成交**反解 IV。不用外部行情、不用二手 IV(规范 [C1])。
    public static func impliedVol(of leg: Leg, in trade: Trade,
                                  basis: TimeBasis = .tradingTime) -> Double? {
        guard case .option(let right, let strike, let expiry) = leg.kind,
              let f = trade.fills(of: leg).last,
              let spot = trade.effectiveUnderlying(of: f) else { return nil }
        let h = TradingDay.hoursToExpiry(from: f.time, expiryDay: expiry)
        guard h > 0 else { return nil }
        return BlackScholes.impliedVolatility(right: right, spot: spot, strike: strike,
                                              years: basis.years(hoursToExpiry: h), price: f.price)
    }

    /// 全部腿的 IV 表。
    public static func impliedVols(of trade: Trade, basis: TimeBasis = .tradingTime) -> [UUID: Double] {
        var m: [UUID: Double] = [:]
        for leg in trade.legs where leg.kind.isOption {
            if let v = impliedVol(of: leg, in: trade, basis: basis) { m[leg.id] = v }
        }
        return m
    }

    /// 若在给定标的价/时刻把**开仓时建立的全部头寸**一次平掉,产生的现金流(有符号)。
    /// 多头平仓 = 正(收钱),空头平仓 = 负(付钱) —— 由 `openedQuantity` 的符号自动带出来。
    /// 任何一条腿定不出价就返回 nil,**不算个半成品出来**。
    public static func closingCashFlow(of trade: Trade, underlying: Double, at time: Date,
                                       vols: [UUID: Double], basis: TimeBasis = .tradingTime) -> Double? {
        var total = 0.0
        for leg in trade.legs {
            let q = trade.openedQuantity(of: leg)
            if abs(q) < 1e-12 { continue }
            guard let px = legPrice(leg, underlying: underlying, at: time,
                                    sigma: vols[leg.id], basis: basis) else { return nil }
            total += q * px * leg.kind.multiplier
        }
        return total
    }

    /// 反事实盈亏 = 开仓现金流 + 假想平仓现金流。**做多/做空/借记/贷记/期货一律成立。**
    public static func hypotheticalPnL(of trade: Trade, underlying: Double, at time: Date,
                                       vols: [UUID: Double], basis: TimeBasis = .tradingTime) -> Double? {
        closingCashFlow(of: trade, underlying: underlying, at: time, vols: vols, basis: basis)
            .map { trade.openingCashFlow + $0 }
    }

    // MARK: - 兼容旧接口(单腿)

    public static func impliedVolAtExit(trade: Trade, hoursToExpiryAtExit: Double,
                                        basis: TimeBasis = .tradingTime) -> Double? {
        guard let leg = trade.primaryLeg, case .option(let right, let strike, _) = leg.kind,
              let exit = trade.closingFills(of: leg).last ?? trade.fills(of: leg).last,
              let spot = trade.effectiveUnderlying(of: exit)
        else { return nil }
        return BlackScholes.impliedVolatility(
            right: right, spot: spot, strike: strike,
            years: basis.years(hoursToExpiry: hoursToExpiryAtExit), price: exit.price)
    }

    public static func positionValue(trade: Trade, quantity: Double,
                                     underlying: Double, hoursToExpiry: Double,
                                     sigma: Double, basis: TimeBasis) -> Double {
        guard let leg = trade.primaryLeg else { return 0 }
        if case .option(let right, let strike, _) = leg.kind {
            let px = BlackScholes.price(right: right, spot: underlying, strike: strike,
                                        years: basis.years(hoursToExpiry: hoursToExpiry), sigma: sigma)
            return px * quantity * leg.kind.multiplier
        }
        return underlying * quantity * leg.kind.multiplier
    }

    // MARK: - ① 出场 vs 峰值

    /// - Note: 规范 §3.1:`peak_value` **单独存在是误导性指标** —— 峰值是事后视角、不可执行。
    ///   UI 必须把可执行的规则放主位,本项放次位。
    public static func exitVsPeak(trade: Trade, peakUnderlying: Double,
                                  hoursToExpiryAtPeak: Double, sigma: Double,
                                  basis: TimeBasis = .tradingTime) -> Counterfactual {
        let leg = trade.primaryLeg
        let q = leg.map { trade.openedQuantity(of: $0) } ?? 0
        let atPeak = positionValue(trade: trade, quantity: abs(q), underlying: peakUnderlying,
                                   hoursToExpiry: hoursToExpiryAtPeak, sigma: sigma, basis: basis)
        let signed = q < 0 ? -atPeak : atPeak
        return Counterfactual(
            id: "exit_vs_peak", label: L("若在标的峰值处出场"),
            alternativePnL: trade.openingCashFlow + signed, actualPnL: trade.realizedPnL,
            requirement: .userProvidedPeak,
            note: (leg?.kind.isOption ?? false)
                ? String(format: L("BS 重定价 · IV %1$.2f%%(由出场成交反解)· %2$@ 口径"),
                         sigma * 100,
                         basis == .tradingTime ? L("交易时间") : L("日历时间"))
                : nil)
    }

    /// 多腿版本:各腿自己的到期日与 IV,时间驱动。
    public static func exitVsPeak(trade: Trade, peakUnderlying: Double, peakTime: Date,
                                  basis: TimeBasis = .tradingTime) -> Counterfactual? {
        let vols = impliedVols(of: trade, basis: basis)
        guard let pnl = hypotheticalPnL(of: trade, underlying: peakUnderlying,
                                        at: peakTime, vols: vols, basis: basis) else { return nil }
        return Counterfactual(id: "exit_vs_peak", label: L("若在标的峰值处出场"),
                              alternativePnL: pnl, actualPnL: trade.realizedPnL,
                              requirement: .userProvidedPeak,
                              note: vols.isEmpty ? nil
                                  : L("逐腿 BS 重定价 · 各腿 IV 由各自成交价反解 · 交易时间口径"))
    }

    // MARK: - ② 不加仓

    /// 只做首仓、完全不加仓会怎样。出场价沿用真实平均出场价 —— 这是**可执行**的对照。
    /// 无加仓时返回 nil,不制造一条恒等于 0 的假反事实。
    public static func noAddOn(trade: Trade) -> Counterfactual? {
        var altOpen = 0.0, altClose = 0.0, firstDesc = ""
        var hasAdd = false
        for leg in trade.legs {
            let opens = trade.openingFills(of: leg)
            guard let first = opens.first else { continue }
            if opens.count > 1 { hasAdd = true }
            let m = leg.kind.multiplier
            altOpen += first.cashFlow(multiplier: m)
            // 用这条腿的真实平均平仓价,把首仓那部分平掉
            let closes = trade.closingFills(of: leg)
            let closedQty = closes.reduce(0) { $0 + $1.quantity }
            guard closedQty > 0 else { continue }
            let avgClose = closes.reduce(0) { $0 + $1.price * $1.quantity } / closedQty
            let q = min(first.quantity, closedQty)
            altClose += (first.side == .buy ? 1 : -1) * avgClose * q * m
            if firstDesc.isEmpty {
                firstDesc = String(format: L("首仓 %1$@ 张 @ %2$.2f · 出场沿用真实均价 %3$.2f"),
                                   q.cleanNum, first.price, avgClose)
            }
        }
        guard hasAdd else { return nil }
        return Counterfactual(id: "no_add_on", label: L("若不加仓,只做首仓"),
                              alternativePnL: altOpen + altClose, actualPnL: trade.realizedPnL,
                              requirement: .fillsOnly, note: firstDesc)
    }

    // MARK: - ③ 持有到收盘/到期

    /// ★ 规范 §3.1:对 0DTE 这是**最重要**的一项 —— 归零是真实且常见的结局。
    /// 只算 `exitVsPeak` 会让用户学到「我应该拿久一点」这个**错误**结论。
    public static func holdToClose(trade: Trade, finalUnderlying: Double,
                                   hoursToExpiryAtClose: Double = 0,
                                   sigma: Double = 0, basis: TimeBasis = .tradingTime) -> Counterfactual {
        var closeCF = 0.0
        var note: String? = nil
        for leg in trade.legs {
            let q = trade.openedQuantity(of: leg)
            if abs(q) < 1e-12 { continue }
            let px: Double
            switch leg.kind {
            case .option(let right, let strike, _):
                // ★★ 优先用用户填的**收盘时真实市场价**。
                //   「持有到收盘」= 收盘时卖掉(拿市场价);「持有到到期」= 拿内在价值。
                //   对 0DTE 这两个数差的就是全部 —— 用户那张 708 call
                //   收盘市场价 0.25,而内在价值是 0。我们过去只算后者却写着前者。
                px = closePrice(of: leg, finalUnderlying: finalUnderlying)
                if note == nil {
                    if leg.userClosePrice != nil {
                        note = String(format: L("收盘时卖出 %.2f/张(你填的真实价)"), px)
                    } else {
                        note = px <= 0
                            ? String(format: L("标的收于 %1$.2f,行权价 %2$@ —— 这是**放到到期**的结果(归零)。若是收盘时卖掉,末日权还有几分钱时间价值,填进去这条才准"),
                                     finalUnderlying, strike.cleanNum)
                            : String(format: L("到期内在价值 %.2f/张(未填收盘市场价)"), px)
                    }
                }
            case .equity, .futures, .forex:
                px = finalUnderlying
            }
            closeCF += q * px * leg.kind.multiplier
        }
        return Counterfactual(id: "hold_to_close", label: L("若持有到收盘"),
                              alternativePnL: trade.openingCashFlow + closeCF,
                              actualPnL: trade.realizedPnL,
                              requirement: .userProvidedFinal, note: note)
    }

    /// 汇总。缺数据的项不编,直接不出现 —— 由 `missing` 告诉 UI 还差什么。
    public static func all(trade: Trade,
                           peakUnderlying: Double?, hoursToExpiryAtPeak: Double?,
                           finalUnderlying: Double?,
                           hoursToExpiryAtExit: Double?,
                           basis: TimeBasis = .tradingTime)
    -> (results: [Counterfactual], impliedVol: Double?, missing: [DataRequirement]) {
        var out: [Counterfactual] = []
        var missing: [DataRequirement] = []
        let hasOption = trade.legs.contains { $0.kind.isOption }

        var sigma: Double? = nil
        if hasOption, let h = hoursToExpiryAtExit {
            sigma = impliedVolAtExit(trade: trade, hoursToExpiryAtExit: h, basis: basis)
        }
        if let cf = noAddOn(trade: trade) { out.append(cf) }

        if let pk = peakUnderlying, let hp = hoursToExpiryAtPeak, (!hasOption || sigma != nil) {
            out.append(exitVsPeak(trade: trade, peakUnderlying: pk, hoursToExpiryAtPeak: hp,
                                  sigma: sigma ?? 0, basis: basis))
        } else { missing.append(.userProvidedPeak) }

        if let fin = finalUnderlying {
            out.append(holdToClose(trade: trade, finalUnderlying: fin, basis: basis))
        } else { missing.append(.userProvidedFinal) }

        missing.append(.intradayPath)
        return (out, sigma, missing)
    }
}

// MARK: - ④ 规则化分批出场(可算的那个版本)

public extension CounterfactualEngine {

    /// 「触及目标平一半 + 剩余持有到强平」。
    ///
    /// ★ 为什么这一条能算,而完整版不能:
    /// 用户的实际规则是「平 50% + **剩余移动止损**」,而移动止损**何时**触发需要分钟级路径,
    /// v1 拿不到。把后半段换成「持有到强平」之后,剩余部分的结局是已知的
    /// ⇒ 整条规则只用「成交明细 + 一个收盘价」就能算完。
    ///
    /// `note` 里必须写清是**简化版**,不许冒充完整版。
    /// 期权/期货按整数张切分;奇数张**向上取整**(平 50% 的意图是降风险,宁可多平)。
    static func scaleOutAndHold(trade: Trade, finalUnderlying: Double,
                                basis: TimeBasis = .tradingTime) -> Counterfactual? {
        var cf = trade.openingCashFlow
        var any = false, desc = ""
        for leg in trade.legs {
            let q = trade.openedQuantity(of: leg)          // 有符号
            if abs(q) < 1e-12 { continue }
            let mag = abs(q)
            let integral = !(leg.kind == .equity)          // 股票/加密允许小数,其余按整数张
            let closeNow = integral ? (mag / 2).rounded() : mag / 2
            let hold = mag - closeNow
            guard closeNow > 0, hold > 0 else { continue }
            any = true
            let sign: Double = q > 0 ? 1 : -1
            let m = leg.kind.multiplier

            // 前一半:按真实平均平仓价了结
            let closes = trade.closingFills(of: leg)
            let cq = closes.reduce(0) { $0 + $1.quantity }
            let avgClose = cq > 0 ? closes.reduce(0) { $0 + $1.price * $1.quantity } / cq : 0
            cf += sign * closeNow * avgClose * m

            // 后一半:持有到强平/到期。★ 走同一个 closePrice ——
            //   之前这里自己算内在价值,把用户填的真实价漏掉了,导致
            //   同一屏上两张卡对同一张期权给出两个收盘价。
            let px = closePrice(of: leg, finalUnderlying: finalUnderlying)
            cf += sign * hold * px * m

            if desc.isEmpty {
                desc = String(format: L("平 %1$@ @ %2$.2f,留 %3$@ 到强平 · ★这是你规则的简化版:去掉了「剩余移动止损」那条腿 —— 它要分钟级路径,而**期权的分钟价 App 内取不到**(股票/期货/外汇点「自动填」就有)"),
                              closeNow.cleanNum, avgClose, hold.cleanNum)
            }
        }
        guard any else { return nil }
        return Counterfactual(id: "scale_out_hold", label: L("若触及目标平一半、剩余持有到强平"),
                              alternativePnL: cf, actualPnL: trade.realizedPnL,
                              requirement: .userProvidedFinal, note: desc)
    }

    /// 观测到的**最大浮亏**(MAE 的下界)。
    /// 行业标准 MAE 需要分钟级路径;v1 只能从**成交点**观测,所以这是下界不是真值。
    /// `label` 必须写「≥」—— 把下界说成真值,和编数据没有区别。
    static func observedMAE(trade: Trade) -> (pct: Double, at: Date)? {
        trade.addsWhileUnderwater.min { $0.unrealizedPct < $1.unrealizedPct }
            .map { ($0.unrealizedPct, $0.fill.time) }
    }

    /// MFE 捕获率 —— `exitVsPeak` 的行业标准说法
    /// (「平均 MFE 3.4R vs 实际出场 1.7R ⇒ 只吃到 50%」)。
    /// 用标准术语能让用户和 App Store 搜索都看得懂。
    static func mfeCaptureRate(exitVsPeak cf: Counterfactual, costBasis: Double) -> Double? {
        let peakValue = cf.alternativePnL + costBasis
        let yourValue = cf.actualPnL + costBasis
        guard peakValue > 0 else { return nil }
        return yourValue / peakValue
    }
}

// MARK: - 多腿汇总(时间驱动,各腿用自己的到期日与 IV)

public extension CounterfactualEngine {

    /// 多腿版的汇总。与单腿版 `all(...)` 的区别:
    /// **按时刻**而不是按「剩余小时数」驱动 —— 因为各腿到期日可以不同(日历价差),
    /// 一个全局的「剩余小时」在多腿下是没有意义的。
    ///
    /// `peakTime` 影响时间价值:0DTE 差两小时和差两分钟不是一回事。
    /// 不给就退回到**最后一笔成交的时刻**,并在 note 里写明这是近似。
    static func allByTime(trade: Trade,
                          peakUnderlying: Double?, peakTime: Date?,
                          finalUnderlying: Double?,
                          trailingStopPct: Double = 25,
                          basis: TimeBasis = .tradingTime)
    -> (results: [Counterfactual], vols: [UUID: Double], missing: [DataRequirement]) {
        var out: [Counterfactual] = []
        var missing: [DataRequirement] = []
        let vols = impliedVols(of: trade, basis: basis)
        let lastFillTime = trade.fills.map(\.time).max()

        if let fin = finalUnderlying {
            out.append(holdToClose(trade: trade, finalUnderlying: fin, basis: basis))
            if let sc = scaleOutAndHold(trade: trade, finalUnderlying: fin, basis: basis) {
                out.append(sc)
            }
        } else { missing.append(.userProvidedFinal) }

        if let cf = noAddOn(trade: trade) { out.append(cf) }

        // ★ 有真实分钟路径才出现 —— 没有就不编,由「算不了的」那栏说明原因。
        if let cf = trailingStop(trade: trade, trailPct: trailingStopPct) { out.append(cf) }
        if let full = scaleOutAndTrail(trade: trade, trailPct: trailingStopPct,
                                       finalUnderlying: finalUnderlying) {
            // ★ 完整版能算了,就**把简化版撤掉** —— 同一件事摆两张卡只会让人对不上账,
            //   而且简化版那句「v1 拿不到分钟路径」在这时候已经是**假话**了。
            out.removeAll { $0.id == "scale_out_hold" }
            out.append(full)
        }

        if let pk = peakUnderlying, let t = peakTime ?? lastFillTime,
           let pnl = hypotheticalPnL(of: trade, underlying: pk, at: t, vols: vols, basis: basis) {
            let approx = (peakTime == nil)
            out.append(Counterfactual(
                id: "exit_vs_peak", label: L("若在标的峰值处出场"),
                alternativePnL: pnl, actualPnL: trade.realizedPnL,
                requirement: .userProvidedPeak,
                note: vols.isEmpty ? nil
                    : (approx
                       ? L("逐腿 BS 重定价 · 各腿 IV 由各自成交价反解 · **峰值时刻按出场时刻近似**")
                       : L("逐腿 BS 重定价 · 各腿 IV 由各自成交价反解 · 交易时间口径"))))
        } else { missing.append(.userProvidedPeak) }

        // ★ 有真实价就顶掉模型估的那张 —— 实测模型高估 $48(4.45 vs 真实 4.29)。
        if let real = exitVsPeakFromPath(trade: trade) {
            out.removeAll { $0.id == "exit_vs_peak" }
            out.append(real)
            missing.removeAll { $0 == .userProvidedPeak }
        }

        // ★ 有真实路径就不该再说「缺分钟路径」—— 那条清单要跟着能力走。
        if !trade.legs.contains(where: { !($0.path?.isEmpty ?? true) }) {
            missing.append(.intradayPath)
        }
        // 排序:可执行的在前,事后视角的在后(规范 §3.1)
        out.sort { counterfactualRank($0.id) < counterfactualRank($1.id) }
        return (out, vols, missing)
    }
}

public extension CounterfactualEngine {

    /// **这条腿在收盘/强平时值多少 —— 全 App 只有这一个答案。**
    ///
    /// ★★ 2026-09-01 用户在真机截图里逮到的 bug:同一屏上,
    ///   「若持有到收盘」用了他填的真实价 **0.25**(那样 −$327),
    ///   「若平一半、剩余持有到强平」却还在用模型的 **0**(那样 $80)。
    ///   <b>同一笔、同一个「持有到收盘」的问题,两张卡给出两个价。</b>
    ///   这正是这个 App 立身的那件事(「算得对」)最不该出的错。
    ///
    ///   根因不是某一处写错,是**这段逻辑被抄了三份**
    ///   (holdToClose / scaleOutAndHold / scaleOutAndTrail),我只更新了第一份。
    ///   ⇒ 和短标签那次一样:<b>同一个映射有多份副本,就等于有几份迟早是过期的。</b>
    ///
    /// 优先级:**用户填的真实价 > 到期内在价值**。
    static func closePrice(of leg: Leg, finalUnderlying: Double) -> Double {
        if let up = leg.userClosePrice { return up }
        switch leg.kind {
        case .option(let right, let strike, _):
            return max(right == .call ? finalUnderlying - strike : strike - finalUnderlying, 0)
        case .equity, .futures, .forex:
            return finalUnderlying
        }
    }
}

// MARK: - ⑤ 移动止损(需要真实分钟路径)

public extension CounterfactualEngine {

    /// **若开仓后就挂移动止损,会怎样。**
    ///
    /// ★★ 这条原本躺在「这一版算不了的」清单里 —— 因为移动止损<b>何时触发</b>
    ///   要看价格出现的**顺序**,光有最高最低价算不出来。
    ///   现在路径由 `tools/moomoo_enrich.py` 从 moomoo 取回来存进腿里,可以算了。
    ///
    /// ★ 百分比取用户自己在规则里声明的那个数,**不挑事后最优** ——
    ///   挑最好的参数是数据挖掘,那样得出的「本来能赚更多」是假的。
    ///
    /// 全程没被打掉时:按**实际出场价**成交(这时移动止损没起作用,两边应当同值)。
    static func trailingStop(trade: Trade, trailPct: Double) -> Counterfactual? {
        var alt = trade.openingCashFlow
        var any = false
        var note: String? = nil
        for leg in trade.legs {
            let q = trade.openedQuantity(of: leg)
            guard abs(q) > 1e-12, let path = leg.path, !path.isEmpty else { continue }
            guard let entry = trade.openingFills(of: leg).first?.price else { continue }
            let isLong = q > 0
            any = true
            let stopped = PathAnalysis.trailingStopExit(path: path, entry: entry,
                                                        trailPct: trailPct, isLong: isLong)
            let exitPx = stopped ?? trade.closingFills(of: leg).last?.price ?? entry
            // 平仓现金流 = **有符号持仓量 × 价格**:
            // 多头(q>0)平掉是收钱,空头(q<0)平掉是付钱 —— 一个式子两边都对。
            // (第一版写成 `-q * …`,把 +321 算成了 −829.5,被测试当场抓住。)
            alt += q * exitPx * leg.kind.multiplier
            if note == nil {
                note = stopped == nil
                    ? String(format: L("全程没被打掉(回撤没到 %g%%),所以和你的实际出场同价"), trailPct)
                    : String(format: L("从最高点回撤 %1$g%% 触发,成交在 %2$.2f"), trailPct, exitPx)
            }
        }
        guard any else { return nil }
        return Counterfactual(id: "trailing_stop",
                              label: String(format: L("若挂 %g%% 移动止损"), trailPct),
                              alternativePnL: alt, actualPnL: trade.realizedPnL,
                              requirement: .userProvidedFinal, note: note)
    }
}

// MARK: - ⑥ 平一半 + 剩余移动止损(完整版,需要真实路径)

public extension CounterfactualEngine {

    /// **「触及目标平一半、剩余挂移动止损」的完整版。**
    ///
    /// ★★ 这条一直挂在「这一版算不了的」清单最上面 —— 因为「剩余那一半何时被移动止损打掉」
    ///   要看你走之后价格怎么走,而 v1 拿不到分钟路径。现在拿得到了。
    ///
    /// 做法:① 一半按你**实际的出场价**平掉(这就是「触及目标」)
    ///      ② 剩下的一半从出场那一刻起挂 `trailPct` 移动止损
    ///      ③ 一直没被打掉就按收盘价了结(优先用你填的真实价)
    static func scaleOutAndTrail(trade: Trade, trailPct: Double,
                                 finalUnderlying: Double?) -> Counterfactual? {
        var alt = trade.openingCashFlow
        var any = false
        var note: String? = nil
        for leg in trade.legs {
            let q = trade.openedQuantity(of: leg)
            guard abs(q) > 1e-12, let path = leg.path, !path.isEmpty else { continue }
            guard let exitFill = trade.closingFills(of: leg).last else { continue }
            let mag = abs(q)
            let integral = !(leg.kind == .equity)
            let half = integral ? (mag / 2).rounded() : mag / 2
            let rest = mag - half
            guard half > 0, rest > 0 else { continue }
            any = true
            let sign: Double = q > 0 ? 1 : -1
            // ① 一半在实际出场价了结
            alt += sign * half * exitFill.price * leg.kind.multiplier

            // ② 剩下的从出场那一刻起跟踪
            let after = path.filter { $0.t >= exitFill.time }
            let trailed = PathAnalysis.trailingStopExit(path: after.isEmpty ? path : after,
                                                        entry: exitFill.price,
                                                        trailPct: trailPct, isLong: q > 0)
            let restPx: Double
            if let stop = trailed {
                restPx = stop
                note = note ?? String(format: L("平 %1$@ @ %2$.2f;剩下的在 %3$.2f 被 %4$g%% 移动止损打掉"),
                                      half.cleanNum, exitFill.price, stop, trailPct)
            } else if let fin = finalUnderlying {
                restPx = closePrice(of: leg, finalUnderlying: fin)
                note = note ?? String(format: L("平 %1$@ @ %2$.2f;剩下的没被打掉,收盘 %3$.2f 了结"),
                                      half.cleanNum, exitFill.price, restPx)
            } else { return nil }
            alt += sign * rest * restPx * leg.kind.multiplier
        }
        guard any else { return nil }
        return Counterfactual(id: "scale_out_trail",
                              label: String(format: L("若平一半、剩余挂 %g%% 移动止损"), trailPct),
                              alternativePnL: alt, actualPnL: trade.realizedPnL,
                              requirement: .userProvidedFinal, note: note)
    }
}

// MARK: - ⑦ 峰值出场:有真实路径时,别再用模型估

public extension CounterfactualEngine {

    /// 标的最有利的那一刻是几点。从 `underlyingPath` 里读 —— 不用用户手填。
    static func peakMoment(of trade: Trade) -> (t: Date, px: Double)? {
        guard let path = trade.underlyingPath ?? trade.legs.first(where: {
            if case .option = $0.kind { return false } else { return true }
        })?.path, !path.isEmpty else { return nil }
        let long = trade.legs.first.flatMap { trade.openingSide(of: $0) } != .sell
        let best = long ? path.max { $0.h < $1.h } : path.min { $0.l < $1.l }
        return best.map { (t: $0.t, px: long ? $0.h : $0.l) }
    }

    /// **若在标的峰值处出场 —— 用那一刻这条腿的真实成交价,不用 Black–Scholes 估。**
    ///
    /// ★★ 2026-09-01 复查发现的偏差:模型给 4.45/张(那样 +$933),
    ///   而 moomoo 的分钟 K 显示 QQQ 在 11:49 触及 712.30 时,
    ///   这张 708C **实际是 4.29**(那样 +$885)。<b>模型高估了 $48。</b>
    ///   原因是 BS 用一个从成交价反解出来的常数 IV,而真实的时间价值一直在变。
    ///   ⇒ **有真实价就别用模型。** 模型只在没有路径时兜底。
    static func exitVsPeakFromPath(trade: Trade) -> Counterfactual? {
        guard let peak = peakMoment(of: trade) else { return nil }
        var alt = trade.openingCashFlow
        var any = false
        var note: String? = nil
        for leg in trade.legs {
            let q = trade.openedQuantity(of: leg)
            guard abs(q) > 1e-12, let path = leg.path, !path.isEmpty else { return nil }
            // 取峰值那一刻(或最接近的一根)这条腿的价
            guard let bar = path.min(by: {
                abs($0.t.timeIntervalSince(peak.t)) < abs($1.t.timeIntervalSince(peak.t))
            }) else { return nil }
            any = true
            alt += q * bar.c * leg.kind.multiplier
            if note == nil {
                let f = DateFormatter()
                f.dateFormat = "HH:mm"; f.timeZone = TradingDay.exchangeTimeZone
                note = String(format: L("标的 %1$@ 在 %2$@ 触及 %3$.2f,这条腿**当时的真实价** %4$.2f/张 —— 不是模型估的"),
                              trade.symbol, f.string(from: bar.t), peak.px, bar.c)
            }
        }
        guard any else { return nil }
        return Counterfactual(id: "exit_vs_peak", label: L("若在标的峰值处出场"),
                              alternativePnL: alt, actualPnL: trade.realizedPnL,
                              requirement: .userProvidedPeak, note: note)
    }
}
