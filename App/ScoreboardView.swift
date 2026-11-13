import SwiftUI

/// 主页顶上的战绩:**日 / 周 / 月 / 年**。
///
/// ★★ 这一栏是「记账」——而这个 App 的立场是「不只是记账」。
///   所以它必须**同时**给两个数,而且第二个不许被折叠掉:
///   ① 这个周期你赚了多少(你要的战绩)
///   ② **最好的可执行替代做法比你多赚/少赚多少**(这个 App 的增量)
///   只给 ① 就退化成竞品;只给 ② 又答不上用户真正问的问题。
///
/// ★ 口径写在图脚,不藏在文档里 —— 「按兑现日归期」这种事,
///   用户第一次看到数字对不上时就会怀疑整个 App。
struct ScoreboardView: View {
    let trades: [Trade]
    /// 点热力图里某一天时回调 —— 弹那天的清单。
    var onPickDay: ((HeatmapCell) -> Void)? = nil
    /// 记住上次选的周期。★ 每次打开都跳回「日」会很烦。
    @AppStorage("scoreboardPeriod") private var raw = StatsPeriod.day.rawValue
    /// 分类默认收起 —— 主页顶上是给「一眼看战绩」用的,不是给报表用的。
    @AppStorage("scoreboardKindsOpen") private var kindsOpen = false
    /// 分类看的是「上面那一格」还是全部历史。★ 默认跟随周期,
    /// 但一格里只有一两笔时,分类没意义 —— 给个开关而不是给一片空白。
    @AppStorage("scoreboardKindScopeAll") private var kindScopeAll = false

    private var period: StatsPeriod { StatsPeriod(rawValue: raw) ?? .day }
    private var s: PeriodStats { PeriodStats.compute(trades, period: period) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $raw) {
                ForEach(StatsPeriod.allCases) { p in
                    Text(p.localizedLabel).tag(p.rawValue)
                }
            }
            .pickerStyle(.segmented)

            let c = s.displayed
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if c.n == 0 {
                    Text(c.openCount > 0 ? "还没平仓" : "还没交易")
                        .font(.title2.weight(.semibold)).foregroundStyle(.secondary)
                } else {
                    // ★ 原来「+」和金额是两个 Text,中间隔着空格、字号还不一样,
                    //   而金额走 `.currency(code:)` 在中文区域下写成 `US$42`。
                    //   ⇒ 一个 Text、真正的减号、不带 US —— 见 `Money`。
                    Text(verbatim: Money.signed(c.pnl))
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.pnl(c.pnl))
                        .minimumScaleFactor(0.6).lineLimit(1)
                        .contentTransition(.numericText())
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: c.label).font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                        // ★★ 所有「口径说明」收进这一个 ⓘ。原来卡片里常驻四行灰字,
                        //   其中一行是「只有一个取值的维度不占整块 —— 降成上面那一行」——
                        //   <b>那是我写给自己的设计理由,不是给用户看的信息。</b>
                        Button { showInfo = true } label: {
                            Image(systemName: "info.circle").font(.footnote)
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showInfo) { infoCard }
                    }
                    // ★ 换了一格就必须说 —— 不许悄悄换还假装是当前那格。
                    //   但它是**信息**不是警告:原来 9pt 橙字,像在报错。
                    if s.showingFallback {
                        Text(noTradeYet).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }

            // 笔数 / 胜 / 在手
            HStack(spacing: 10) {
                if c.n > 0 { Text("\(c.n) 笔 · 赢 \(c.wins)") }
                if c.openCount > 0 {
                    // ★ 「在手 N 笔」必须说 —— 否则「$0」会被读成「今天没交易」
                    Text("· 在手 \(c.openCount) 笔未平")
                        .foregroundStyle(Theme.open)
                }
            }
            .font(.caption).foregroundStyle(.secondary)

            // ★★ 这一行才是这个 App 的增量,不许折叠
            if let d = c.bestAlternativeDelta, let name = c.bestAlternativeLabel {
                HStack(spacing: 5) {
                    Image(systemName: d > 0 ? "arrow.turn.up.right" : "checkmark.seal.fill")
                        .font(.caption2)
                    Text(md: d > 0
                         ? String(format: Loc.t("「%1$@」比你**多赚** %2$@"), name, abs(d).usdShort)
                         : String(format: Loc.t("你比最好的替代做法**多赚** %@"), abs(d).usdShort))
                        .font(.caption)
                }
                // ★ 「你没走的那条路」用图标的琥珀 —— 和复盘页那条虚线同一个颜色。
                //   你赢过了替代做法就用赚的绿。
                .foregroundStyle(d > 0 ? Theme.alt : Theme.profit)
            }

            // ★★ 用户 2026-09-03:「主页历史战绩能做到像是那种一个个小方格,
            //   点进去能查看具体信息」。
            //   ★ 只在「日」周期画格子 —— 选着「月」还给你一天一格,那是两个口径。
            // ★ 用户 2026-09-03:「把周月年也能做成小格子」。
            //   日 = 日历网格;周/月/年 = 带标签的一排排方块(它们本来就是一维的)。
            if period == .day {
                HeatmapView(trades: trades) { onPickDay?($0) }
            } else {
                PeriodSquaresView(trades: trades, period: period) { onPickDay?($0) }
            }

            // ★★ 按种类分类:分的是**上面那一格**的交易,不是全部历史。
            //   否则主页上两个数会打架(上面写「8 月 705」、
            //   下面按品种加起来却是全年的)。
            //   ★ 只有一个取值的维度自动不显示 —— 见 KindStats.groups。
            //   ★ 这一栏**永远出现**(只要有交易)。2026-09-02 用户问
            //     「我手机上怎么没有按种类看」—— 因为他停在「日」、那天只有一笔,
            //     所有维度都只有一个取值,于是整栏连入口一起消失了。
            //     <b>一个自动隐藏的功能,和一个坏掉的功能,从用户那边看没有区别。</b>
            let scoped = PeriodStats.trades(trades, in: s.displayed, period: period)
            let bd = KindStats.breakdown(kindScopeAll ? trades.filter { !$0.isSample } : scoped)
            if !bd.isEmpty { kindSection(bd) }
        }
        .padding(.vertical, 4)
    }

    @State private var showInfo = false

    /// 口径说明。★ 原来是卡片底部常驻的两三行 9pt 灰字 —— 每次打开 App 都在,
    ///   而它回答的问题(「这个数按哪天算」)一个人一辈子只问一次。
    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("怎么算的", systemImage: "info.circle").font(.subheadline.weight(.semibold))
            Text(footnote).font(.footnote)
            Divider()
            Text(md: "**格子怎么读**\n· 空格 = 那天没交易,**不是持平**\n· 琥珀色 = 那天开了仓、还没平\n· 有框的那一格 = 今天\n· 点有颜色的格子 = 看那天的交易")
                .font(.footnote)
        }
        .padding()
        .frame(width: 290)
        .presentationCompactAdaptation(.popover)
    }

    /// 往前几格的小条 —— 周/月/年时用它(一天一格在那些口径下没意义)。
    @ViewBuilder private var stripView: some View {
        let past = Array(s.strip.prefix(7))
        if !past.isEmpty {
            let peak = max(past.map { abs($0.pnl) }.max() ?? 1, 1)
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(past.reversed()) { b in
                    VStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Theme.pnl(b.pnl).opacity(0.7))
                            .frame(height: max(CGFloat(abs(b.pnl) / peak) * 26, 2))
                        Text(verbatim: b.shortLabel)
                            .font(.system(size: 8)).foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 40, alignment: .bottom)
        }
    }

    /// 种类分类。折叠起来 —— 主页顶上不该被它占满。
    @ViewBuilder private func kindSection(_ bd: KindStats.Breakdown) -> some View {
        DisclosureGroup(isExpanded: $kindsOpen) {
            VStack(alignment: .leading, spacing: 14) {
                // ★ 这一格交易太少时,给个开关去看全部历史 ——
                //   一笔交易的「分类」没有任何意义,但直接空着又像坏了。
                if bd.n < 2 || bd.groups.isEmpty {
                    Toggle(isOn: $kindScopeAll) {
                        Text(md: kindScopeAll
                             ? Loc.t("正在看**全部历史**(不是上面那一格)")
                             : String(format: scopeHint, bd.n))
                            .font(.caption)
                    }
                    .toggleStyle(.switch)
                }
                ForEach(bd.groups) { g in
                    VStack(alignment: .leading, spacing: 6) {
                        // ★ 引擎给的是运行时 String —— `Text(String)` 不本地化,
                        //   包成 LocalizedStringKey 才会查表。
                        Text(LocalizedStringKey(g.title)).font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                        ForEach(g.buckets) { b in
                            HStack(spacing: 8) {
                                Text(LocalizedStringKey(b.label)).font(.caption)
                                Text(b.n > 0 ? "\(b.n) 笔 · 赢 \(b.wins)"
                                             : "\(b.openCount) 笔未平")
                                    .font(.caption2).foregroundStyle(.tertiary)
                                Spacer()
                                if b.n > 0 {
                                    // ★ 亏红盈绿,和全 App 一致
                                    Text(verbatim: Money.signed(b.pnl))
                                        .font(.caption.monospacedDigit().weight(.medium))
                                        .foregroundStyle(Theme.pnl(b.pnl))
                                } else {
                                    Text("—").font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
                // ★ 单值维度:降级成一行,**不消失**
                if !bd.singles.isEmpty {
                    Text(verbatim: bd.singles.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                // ★ 删掉了「只有一个取值的维度不占整块 —— 降成上面那一行」:
                //   那是设计理由,写在代码注释里就够了。
                //   「现在统计的是全部历史」留着 —— 那是会让人读错数字的事,必须说。
                if kindScopeAll {
                    Text(md: "★ 现在统计的是**全部历史**,和上面的周期数字不是一回事。")
                        .font(.caption2).foregroundStyle(Theme.warn)
                }
            }
            .padding(.top, 6)
        } label: {
            Text(bd.groups.isEmpty ? "按种类看"
                                   : "按种类看(\(bd.groups.count) 个维度)")
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }
        .tint(.secondary)
    }

    /// ★★ 这里以前返回纯 `String`,而 `Text(String)` **永远不本地化** ——
    ///   守卫报 100%,屏幕上却是中文。改成 `LocalizedStringKey`。
    ///   <b>「能不能翻」取决于类型,不取决于它长得像不像一句话。</b>
    private var footnote: LocalizedStringKey {
        switch period {
        case .day:   return "按盈亏兑现那天归期(不是开仓那天)· 交易所时区"
        case .week:  return "周一到周日 · 按盈亏兑现那天归期 · 交易所时区"
        case .month: return "自然月 · 按盈亏兑现那天归期 · 交易所时区"
        case .year:  return "自然年 · 按盈亏兑现那天归期 · 交易所时区"
        }
    }

    /// 周期名(给句子里用)。★ `StatsPeriod.label` 是引擎的纯 String,不会翻。
    // ★★ 2026-09-02 装完英文版**看屏幕**才发现的:
    //    「日/周/月/年」在分段控件上要短(D/W/M/Y),塞进句子里却要是个词
    //    (「No trades this D yet」根本不是英文)。同一个 key 两种用法 ⇒ 必然有一边错。
    //    <b>守卫只数「翻没翻」,数不出「翻得对不对」—— 这一类只能自己看。</b>
    //    ⇒ 句子各给各的 key,不再拿短标签去拼。
    private var noTradeYet: LocalizedStringKey {
        switch period {
        case .day:   return "今天还没有交易"
        case .week:  return "本周还没有交易"
        case .month: return "本月还没有交易"
        case .year:  return "今年还没有交易"
        }
    }
    private var scopeHint: String {
        switch period {
        case .day:   return Loc.t("这一天只有 %lld 笔 —— 打开看**全部历史**")
        case .week:  return Loc.t("这一周只有 %lld 笔 —— 打开看**全部历史**")
        case .month: return Loc.t("这一个月只有 %lld 笔 —— 打开看**全部历史**")
        case .year:  return Loc.t("这一年只有 %lld 笔 —— 打开看**全部历史**")
        }
    }
}
