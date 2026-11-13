import Foundation

/// 标的行情:按交易日取 O/H/L/C。
///
/// ★★ 这是这个 App **唯一**一处联网。起因是用户 2026-09-01 的要求:
///   「你需要接入外部数据…最好在用户输入之后就能自动显示价格,如果不对用户也可以自己修改」。
///   在此之前「收盘时标的价」是空的 —— 而它一空,**四条反事实一条也算不出来**,
///   整个 App 的存在理由在第一笔真实交易上就没兑现。
///
/// ★ 发出去的只有:**一个股票代码 + 一个日期区间**。
///   不上传任何成交、张数、盈亏、心理标签、设备标识 —— 一个字节都没有。
///   ⇒ 隐私政策与商店描述已同步改写,不再写「不向任何服务器发送请求」。
///     **承诺变了就要改文案,不能让文案替旧版本说话。**
///
/// ★ 只取**标的**价。期权的历史收盘价没有免费源
///   (实测 Yahoo 过期链取不到;Polygon 的期权数据 $79/月),
///   所以期权那格由模型给估算值、由用户覆盖 —— 见 `Leg.userClosePrice`。
enum QuoteService {

    struct Bar: Sendable, Equatable {
        var date: Date
        var open: Double, high: Double, low: Double, close: Double
    }

    enum Failure: LocalizedError, Equatable {
        case offline, notFound(String), badResponse, tooOld(days: Int)

        var errorDescription: String? {
            switch self {
            case .offline:        return Loc.t("连不上网。手动填也一样能算。")
            case .notFound(let s):
                return String(format: Loc.t("没查到 %@ 那天的行情。可能是非交易日,或者代码不对。"), s)
            case .badResponse:    return Loc.t("行情源返回了看不懂的内容。手动填也一样能算。")
            case .tooOld(let d):
                return String(format: Loc.t(
                    "这笔是 %1$@ 天前的 —— 免费的分钟数据只留 %2$@ 天,所以只能画示意 K 线。"),
                    "\(d)", "\(minuteLookbackDays)")
            }
        }
    }

    /// 取 `symbol` 在 `day`(交易所日历上的那一天)的日K。
    static func dailyBar(symbol: String, on day: Date) async throws -> Bar {
        let cal = Calendar(identifier: .gregorian)
        // 前后各放宽两天,免得被时区/非交易日切掉;再挑最接近的那根
        let from = cal.date(byAdding: .day, value: -4, to: day)!
        let to   = cal.date(byAdding: .day, value:  2, to: day)!
        var c = URLComponents(string:
            "https://query1.finance.yahoo.com/v8/finance/chart/"
            + symbol.uppercased().addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)!
        c.queryItems = [
            .init(name: "period1", value: String(Int(from.timeIntervalSince1970))),
            .init(name: "period2", value: String(Int(to.timeIntervalSince1970))),
            .init(name: "interval", value: "1d"),
        ]
        var req = URLRequest(url: c.url!, timeoutInterval: 12)
        // ★ 不带 cookie、不带任何身份 —— 这个请求认不出是谁发的
        req.httpShouldHandleCookies = false
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        let data: Data
        do { (data, _) = try await URLSession.shared.data(for: req) }
        catch { throw Self.transportError(error) }

        guard let bars = try? parse(data), !bars.isEmpty else { throw Failure.badResponse }
        // 挑与目标日同一天的;没有就取不晚于目标日的最后一根(处理非交易日)
        let want = cal.startOfDay(for: day)
        if let exact = bars.first(where: { cal.isDate($0.date, inSameDayAs: want) }) { return exact }
        guard let prior = bars.last(where: { $0.date <= day }) else {
            throw Failure.notFound(symbol.uppercased())
        }
        return prior
    }

    // ── 分钟 K ────────────────────────────────────────────────────────

    /// ★★ 实测确认(2026-09-01):Yahoo 的 1 分钟 K **免费、无 key、可用**,
    ///   股票/ETF 391 根、期货 1439 根、外汇 1280 根,而且**内置的 12 个期货合约全有**。
    ///   <b>但只回溯 29 天</b> —— 第 30 天起直接 HTTP 422,换 2m/5m/15m 也一样。
    ///   ⇒ 所以「示意 K 线」不能删掉:太早的交易只能画示意的。
    static let minuteLookbackDays = 29

    /// 这条腿在 Yahoo 上的代码。**期权返回 nil** —— 期权的历史价没有免费源,
    /// 那条路只能走 `tools/moomoo_enrich.py`。
    /// ★★ 任务取消**不是**「连不上网」。
    ///
    ///   2026-09-03 实测:从「记完 → 问原因 → 复盘页」这一串进来时,
    ///   sheet 内容是换掉的,`.task` 会被取消、URLSession 抛 `URLError.cancelled`,
    ///   而这里原来一律转成 `.offline` ⇒ 界面上写「连不上网」。
    ///   <b>用户会去检查 WiFi,而真实原因是这张页面被换掉了。</b>
    ///   诊断错了比没有诊断更糟 —— 取消就原样抛出去,让调用方知道该重试。
    static func transportError(_ error: Error) -> Error {
        Cancellation.isCancellation(error) ? CancellationError() : Failure.offline
    }

    static func yahooSymbol(for kind: LegKind, tradeSymbol: String) -> String? {
        switch kind {
        case .equity:                   return tradeSymbol.uppercased()
        case .futures(let c, _, _):     return c.uppercased() + "=F"
        case .forex:                    return tradeSymbol.uppercased() + "=X"
        case .option:                   return nil
        }
    }

    /// 取某天的 1 分钟 K(全天)。太久远(> 29 天)会抛 `.tooOld`。
    static func minuteBars(symbol: String, on day: Date) async throws -> [PriceBar] {
        let age = Calendar(identifier: .gregorian)
            .dateComponents([.day], from: day, to: Date()).day ?? 0
        guard age <= minuteLookbackDays else { throw Failure.tooOld(days: age) }

        let cal = Calendar(identifier: .gregorian)
        let start = cal.startOfDay(for: day)
        var c = URLComponents(string:
            "https://query1.finance.yahoo.com/v8/finance/chart/"
            + symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)!
        c.queryItems = [
            .init(name: "period1", value: String(Int(start.timeIntervalSince1970))),
            .init(name: "period2", value: String(Int(start.timeIntervalSince1970) + 86_400)),
            .init(name: "interval", value: "1m"),
        ]
        var req = URLRequest(url: c.url!, timeoutInterval: 20)
        req.httpShouldHandleCookies = false
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let data: Data
        do { (data, _) = try await URLSession.shared.data(for: req) }
        catch { throw Self.transportError(error) }
        guard let bars = try? parse(data), !bars.isEmpty else { throw Failure.notFound(symbol) }
        return bars.map { PriceBar(t: $0.date, h: $0.high, l: $0.low, c: $0.close) }
    }

    /// 解析 Yahoo chart 的返回。**任何一处对不上就抛错,不返回半个结果。**
    static func parse(_ data: Data) throws -> [Bar] {
        struct Root: Decodable {
            struct Chart: Decodable { let result: [Result]? }
            struct Result: Decodable {
                let timestamp: [Double]?
                let indicators: Indicators
            }
            struct Indicators: Decodable { let quote: [Quote] }
            struct Quote: Decodable {
                let open: [Double?]?, high: [Double?]?, low: [Double?]?, close: [Double?]?
            }
            let chart: Chart
        }
        let r = try JSONDecoder().decode(Root.self, from: data)
        guard let res = r.chart.result?.first, let ts = res.timestamp,
              let q = res.indicators.quote.first else { return [] }
        var out: [Bar] = []
        for (i, t) in ts.enumerated() {
            guard let o = q.open?[i] ?? nil, let h = q.high?[i] ?? nil,
                  let l = q.low?[i] ?? nil, let c = q.close?[i] ?? nil else { continue }
            out.append(Bar(date: Date(timeIntervalSince1970: t),
                           open: o, high: h, low: l, close: c))
        }
        return out
    }
}
