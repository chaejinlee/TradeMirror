import SwiftUI

/// 历史分析。
///
/// ★ 第一版做成了六段统计表 —— 用户的原话是「跟 Excel 一样」。他说得对:
/// **统计表读不出结论。** 这一页要回答的问题只有一个 ——
/// **「我该不该改我的出场规则」** —— 所以只留一个主角数字 + 一张图,其余全部降级。
///
/// 极简不是少放东西,是**让一个东西大到无法忽略**。
struct HistoryView: View {
    @Environment(\.dismiss) private var dismiss
    let trades: [Trade]
    /// ★ 对账要用:没记进来的次数、以及你填的券商笔数。
    var failures: [ImportFailure] = []
    var recons: [Reconciliation] = []
    var discipline = DisciplineBook()
    var onSetBrokerCount: ((Int, String) -> Void)? = nil

    private var s: PortfolioStats { PortfolioStats.compute(trades) }
    private var rs: ReasonStats { ReasonStats.compute(trades) }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                HeroVerdict(s: s)

                if !s.counterfactuals.isEmpty {
                    // 复用复盘页同一套视觉语言:实线是你,虚线是你没走的。
                    // 区别只是这里画的是**累计**。
                    VStack(spacing: 6) {
                        ForkChart(actualPnL: s.totalPnL,
                                  branches: s.counterfactuals.map {
                                      (shortLabel($0.id), s.totalPnL + $0.totalDelta,
                                       $0.totalDelta > 0)
                                  })
                        Text("累计:如果每一笔都换成那个做法 ·「峰值出场」不算数(没人卖得在最高点)")
                            .font(.caption2).foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 4)
                }

                // ★★ 对账紧跟在主角后面 —— 「这些数可不可信」要在「这些数说什么」之前回答。
                //   (注释里一直这么写,代码却把它放在倒数第二;2026-09-24 美化时对齐。)
                ReconcileCard(monthKey: ReconciliationPrompt.next(trades: trades,
                                                                  records: recons)?.monthKey
                                        ?? ReconciliationEngine.currentMonthKey(),
                              trades: trades, failures: failures, recons: recons,
                              onSet: onSetBrokerCount)

                // ★★ 2026-09-02 用户要求:「开单原因汇总整理,止损,出场原因」。
                //   他自己的 CSV 里一直有这三列 —— 说明他早就在按原因思考。
                // ★★ 2026-09-24 查出来的:这张卡原来被包在 `if !s.neverHappened.isEmpty` 里 ——
                //   也就是说等「还没发生过」那几件事都做过了,<b>这张卡会连带消失</b>。
                //   一个会自己消失的功能,和一个坏掉的功能,从用户那边看没有区别。
                ReasonCard(rs: rs)
                if !s.neverHappened.isEmpty { NeverCard(items: s.neverHappened) }

                if !s.patterns.isEmpty || !s.stateOutcomes.isEmpty {
                    PatternsCard(s: s)
                }

                // ★ 纪律:这张表的用处不在「勾了几条」,而在
                //   <b>「哪一条最常破、破了那些单亏了多少」</b>。
                DisciplineCard(stats: DisciplineEngine.compute(trades, book: discipline))

                MoreStats(s: s)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("历史分析")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
    }

    private func shortLabel(_ id: String) -> String { counterfactualShortLabel(id) }
}

/// 主角:一个巨大的数 + 一句人话。
struct HeroVerdict: View {
    let s: PortfolioStats

    private var youWin: Bool { (s.vsBestAlternative ?? 0) <= 0 }

    var body: some View {
        VStack(spacing: 10) {
            if let v = s.vsBestAlternative {
                Text(youWin ? "你的出场规则" : "有一条做法长期赢你")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text(verbatim: Money.plain(abs(v)))
                    .font(.system(size: 64, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    // ★ 替代做法赢你 = 机会成本,用「你没走的路」的琥珀,不用亏损的红
                    .foregroundStyle(youWin ? Theme.profit : Theme.alt)
                    .minimumScaleFactor(0.5).lineLimit(1)
                Text(youWin
                     ? "比最好的替代方案还多赚这么多"
                     : "「\(s.bestAlternativeLabel ?? "")」累计比你多赚这么多")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                // ★★ 2026-09-24:原来这里是一句「还没有能比较的交易」——
                //   <b>整页最显眼的位置,放了一个「没有」</b>。而累计盈亏、胜率明明都算得出来。
                //   ⇒ 先说已知的,「填收盘价能看到更多」降成一行。
                Text("累计盈亏").font(.subheadline).foregroundStyle(.secondary)
                Text(verbatim: Money.signed(s.totalPnL))
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.pnl(s.totalPnL))
                    .minimumScaleFactor(0.5).lineLimit(1)
                if s.nClosed > 0 {
                    Text(verbatim: String(format: Loc.t("胜率 %1$lld%% · 赢 %2$lld / %3$lld 笔"),
                                          Int((Double(s.wins) / Double(s.nClosed) * 100).rounded()),
                                          s.wins, s.nClosed))
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                Label("复盘页填上收盘价,这里还会告诉你「没走的那些路」谁赢了",
                      systemImage: "arrow.triangle.branch")
                    .font(.caption).foregroundStyle(Theme.alt)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }

            HStack(spacing: 6) {
                Text("\(s.nClosed) 笔")
                if s.nWithCounterfactuals < s.nClosed {
                    Text("· 其中 \(s.nWithCounterfactuals) 笔能比较")
                }
                if s.confidence != .usable {
                    Text("· 样本太少,别当结论").foregroundStyle(Theme.warn)
                }
            }
            .font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 22))
    }
}

/// ★ 什么还没发生过 —— 规范说它通常比已发生的统计更重要。
struct NeverCard: View {
    let items: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("还没发生过")
                .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(items, id: \.self) { t in
                HStack(alignment: .top, spacing: 9) {
                    // ★ 原来点和字都是橙色,三条下来就是一整面橙墙 —— 可它们是「还没做过」,不是警报。
                    Circle().strokeBorder(Color.secondary, style: .init(lineWidth: 1.5, dash: [2.5, 2.5]))
                        .frame(width: 9, height: 9).padding(.top, 5)
                    Text(md: t).font(.subheadline).foregroundStyle(.primary)
                }
            }
            Text("「止损从未被触发」= 风控从未经检验。这类事实比任何胜率都重要。")
                .font(.caption2).foregroundStyle(.tertiary).padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 18))
    }
}

/// 纪律记分牌 + 心理状态,合成一张卡。
struct PatternsCard: View {
    let s: PortfolioStats
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("记分牌")
                .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(s.patterns) { p in
                HStack {
                    Text(verbatim: p.label).font(.subheadline)
                    Spacer()
                    Text(p.of == 0 ? "—" : "\(p.hit)/\(p.of)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(p.hit == 0 ? Color.secondary : Theme.warn)
                }
            }
            if !s.stateOutcomes.isEmpty {
                Divider().padding(.vertical, 2)
                Text("开仓前记下的状态 × 结果")
                    .font(.caption2).foregroundStyle(.tertiary)
                ForEach(s.stateOutcomes) { o in
                    HStack {
                        if o.isRedFlag {
                            Image(systemName: "flame.fill").font(.caption2)
                                .foregroundStyle(Theme.warn)
                        }
                        Text(LocalizedStringKey(o.id)).font(.subheadline)
                            .foregroundStyle(o.isRedFlag ? Theme.warn : Color.primary)
                        Spacer()
                        Text(verbatim: Money.signed(o.totalPnL))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(Theme.pnl(o.totalPnL))
                    }
                }
            }
            if s.warnedCount > 0 {
                Divider().padding(.vertical, 2)
                HStack {
                    Image(systemName: "hand.raised.fill").font(.caption2)
                        .foregroundStyle(Theme.warn)
                    Text("警告过还是做了").font(.subheadline).foregroundStyle(Theme.warn)
                    Spacer()
                    Text("\(s.proceededAnywayCount)/\(s.warnedCount)")
                        .font(.subheadline.monospacedDigit()).foregroundStyle(Theme.warn)
                }
                if s.proceededAnywayCount > 0 {
                    HStack {
                        Text("那几笔合计").font(.caption2).foregroundStyle(.tertiary)
                        Spacer()
                        Text(verbatim: Money.signed(s.proceededAnywayPnL))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.pnl(s.proceededAnywayPnL))
                    }
                }
            }
            if s.afterTheFactPsychology > 0 {
                Text("另有 \(s.afterTheFactPsychology) 笔是事后补记的,没有计入。")
                    .font(.caption2).foregroundStyle(Theme.warn)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 18))
    }
}

/// 常规统计折叠起来 —— 它们所有竞品都有,不该占主位。
struct MoreStats: View {
    let s: PortfolioStats
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { withAnimation(.snappy) { open.toggle() } } label: {
                HStack {
                    Text("更多统计").font(.footnote.weight(.semibold))
                    Spacer()
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.caption)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                row("累计盈亏", Money.signed(s.totalPnL), Theme.pnl(s.totalPnL))
                row("盈 / 亏", "\(s.wins) / \(s.losses)", .primary)
                if let c = s.mfeCapture { row("平均吃到峰值", "\((c * 100).f1)%", .primary) }
                if s.confidence == .tooFew {
                    Text(md: "样本 < 10,**这里不显示胜率** —— n 太小时胜率是有害的伪精确。")
                        .font(.caption2).foregroundStyle(.tertiary)
                } else {
                    row("胜率", "\((Double(s.wins) / Double(max(s.nClosed, 1)) * 100).f1)%  (n=\(s.nClosed))", .primary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 18))
    }

    private func row(_ k: LocalizedStringKey, _ v: String, _ c: Color) -> some View {
        HStack {
            Text(k).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Text(verbatim: v).font(.subheadline.monospacedDigit()).foregroundStyle(c)
        }
    }
}


/// 按**原因**汇总 + 止损体检。
///
/// ★ 为什么按原因分组比看胜率有用:胜率告诉你「赢了几次」,
///   按原因分组告诉你**哪一类判断值钱** —— 后者才改得动行为。
/// ★ 每组都写着 n。**样本少就明说,不给结论。**
struct ReasonCard: View {
    let rs: ReasonStats

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !rs.byEntryReason.isEmpty {
                group("按开单原因", rs.byEntryReason,
                      foot: Loc.t("「持有到收盘会更好」的次数越多,说明这一类单**你走得太早**。"))
            }
            if !rs.byExitReason.isEmpty {
                group("按出场原因", rs.byExitReason,
                      foot: Loc.t("「提前手动平」这一行如果盈亏明显低于「触及目标」,那是纪律问题,不是运气。"))
            }
            stopSection
            if rs.byEntryReason.isEmpty && rs.byExitReason.isEmpty {
                Text(md: "还没有填过开单原因 —— 下次截图导入开仓时,App 会**当场问你**为什么开、止损止盈在哪。填了这里才有东西看。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 22))
    }

    /// ★★ 2026-09-02 用户报「里面好多中文还是」时挖出的**第二类**:
    ///   `title` / `b.reason` 是**函数参数和存档值**,进了 `Text(String)` 就永不本地化。
    ///   我上一轮只查了「返回 String 的属性」,漏掉了「参数传进来的 String」——
    ///   <b>同一个病,换了个入口。</b>
    @ViewBuilder private func group(_ title: LocalizedStringKey, _ buckets: [ReasonBucket],
                                    foot: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(buckets) { b in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        // ★ 开单/出场原因是**存档值**:存中文、显示译文
                        Text(LocalizedStringKey(b.reason)).font(.subheadline.weight(.medium))
                        Text(b.holdWouldBeBetter > 0
                             ? String(format: Loc.t("%1$lld 笔 · 赢 %2$lld · 其中 %3$lld 笔拿到收盘会更好"),
                                      b.n, b.wins, b.holdWouldBeBetter)
                             : String(format: Loc.t("%1$lld 笔 · 赢 %2$lld"), b.n, b.wins))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text(verbatim: Money.signed(b.totalPnL))
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Theme.pnl(b.totalPnL))
                }
            }
            Text(md: foot).font(.caption2).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private var stopSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("止损").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            HStack {
                Text("事前填了止损").font(.subheadline)
                Spacer()
                Text("\(rs.withStop) / \(rs.closedCount) 笔")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(rs.withStop == 0 ? Theme.warn : Color.primary)   // 计数不是亏损,不用红
            }
            if let touched = rs.stopTouched {
                HStack {
                    Text("其中真的被碰到过").font(.subheadline)
                    Spacer()
                    Text("\(touched) / \(rs.stopCheckable) 笔")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(touched == 0 ? Theme.warn : Color.primary)
                }
                if touched == 0, rs.stopCheckable > 0 {
                    Text(md: "★ **止损一次都没被触发** —— 风控从未经检验。这不是「风控好」,是「还没遇到过」。")
                        .font(.caption2).foregroundStyle(Theme.warn)
                } else if rs.stopTouchedButHeld > 0 {
                    // ★★ 这一条比「从未被触发」严重得多,而且解释了为什么
                    //   上面那张卡说「止损从未被检验」——两句话说的不是一件事:
                    //   价格碰到了你的止损位,但你**没有按它出场**,最后还赚了钱。
                    //   这次赚了,会让这个习惯被强化。
                    Text(md: String(format: Loc.t("★★ 其中 **%lld 笔碰到了止损位、你却没有按它出场**,而且最后还赚了钱。\n「这次扛过来了」会强化这个习惯 —— 而止损存在的意义,正是替你决定不许扛。"),
                                    rs.stopTouchedButHeld))
                        .font(.caption2).foregroundStyle(Theme.loss)
                }
            } else if rs.withStop > 0 {
                Text(md: "要判断止损有没有被碰到,需要**真实分钟路径** —— 点复盘页的「自动填标的价」,或用 moomoo 补全备份。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            if let rr = rs.medianPlannedRR {
                HStack {
                    Text("计划 R:R 中位数").font(.subheadline)
                    Spacer()
                    Text(String(format: "%.2f", rr))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(rr >= 1.5 ? Theme.profit : Theme.warn)
                }
            }
        }
    }
}


/// **对账**:券商上这个月做了几笔,App 里记了几笔。
///
/// ★★ 2026-09-03 的事实:App 里 4 胜 0 负、100% 胜率,
///   而当天那笔 −$140 的亏损<b>正好就是导入失败的那一张</b>。
///   光看 App 内部的数永远看不出漏了什么 —— 漏掉的按定义就不在里面。
///   <b>只能拿一个外部的数来对。</b>
struct ReconcileCard: View {
    let monthKey: String
    let trades: [Trade]
    let failures: [ImportFailure]
    let recons: [Reconciliation]
    var onSet: ((Int, String) -> Void)?

    @State private var text = ""
    @FocusState private var focused: Bool

    private var r: ReconciliationResult {
        ReconciliationEngine.result(monthKey: monthKey, trades: trades,
                                    failures: failures, records: recons)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("对账 · \(monthKey)")
                .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)

            row("App 里记了", "\(r.recorded)")
            if r.importFailures > 0 {
                row("没认出来的截图", "\(r.importFailures)", Theme.warn)
            }

            HStack {
                Text("券商上做了").font(.subheadline)
                Spacer()
                // ★★ 实测(2026-09-03):数字键盘**没有 Return 键**,`onSubmit` 永远不触发;
                //   而这张卡在 ScrollView 里,点空白处也不会失焦 ——
                //   结果是<b>数字打进去了,却什么都没发生</b>。
                //   ⇒ 边打边存,再给键盘一个「完成」按钮收起来。
                TextField("填个数", text: $text)
                    .keyboardType(.numberPad).focused($focused)
                    .multilineTextAlignment(.trailing).frame(width: 74)
                    .padding(.vertical, 6).padding(.horizontal, 8)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    .onChange(of: text) { _, _ in commit() }
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("完成") { focused = false }
                        }
                    }
            }

            if let gap = r.gap {
                Divider()
                if gap == 0 {
                    Label("对上了 —— 这个月的统计是完整的", systemImage: "checkmark.seal.fill")
                        .font(.subheadline).foregroundStyle(Theme.profit)
                } else if gap > 0 {
                    Text(md: String(format: Loc.t(
                        "**差 %lld 笔没进来。**\n漏掉的**不是随机样本** —— 亏损单更烦、更不想记,技术上也更容易出岔子。两边叠加,统计会**系统性偏乐观**。"), gap))
                        .font(.footnote).foregroundStyle(Theme.warn)
                    if r.explainedByFailures > 0 {
                        Text(md: String(format: Loc.t("其中 %lld 笔能对上「没认出来的截图」—— 那几张在下面「数据与备份」里看得到原文。"),
                                        r.explainedByFailures))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                } else {
                    Text(md: String(format: Loc.t("**App 里比券商多 %lld 笔。**多半是重复导入了 —— 「数据与备份」里有「清理重复」。"),
                                    -gap))
                        .font(.footnote).foregroundStyle(Theme.warn)
                }
            } else {
                Text(md: "★ 填上券商那个数,才知道这个月的统计**完不完整**。App 里的数字自己证明不了自己。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 18))
        .onAppear { text = r.broker.map(String.init) ?? "" }
        .onChange(of: focused) { _, f in if !f { commit() } }
    }

    private func commit() {
        let t = text.trimmingCharacters(in: .whitespaces)
        // 清空 ⇒ 当成「没填」,而不是 0 —— 0 会显示成「对上了」,那是撒谎
        if t.isEmpty { onSet?(0, monthKey); return }
        guard let n = Int(t) else { return }
        onSet?(n, monthKey)
    }

    private func row(_ k: LocalizedStringKey, _ v: String, _ c: Color = .primary) -> some View {
        HStack {
            Text(k).font(.subheadline)
            Spacer()
            Text(verbatim: v).font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(c)
        }
    }
}


/// 纪律统计。
///
/// ★★ 这张卡片存在的**唯一理由**:让「勾选清单」变成一个能改变行为的数字。
///   一张只会记录「你勾了几条」的表,和一本没人翻的笔记本没有区别。
///   要回答的是:<b>哪一条最常破?破了的那些单,比守规矩的单少赚多少?</b>
struct DisciplineCard: View {
    let stats: DisciplineStats

    var body: some View {
        if stats.checkedTrades > 0 {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("纪律").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text(verbatim: String(format: Loc.t("%lld 笔答过"), stats.checkedTrades))
                        .font(.caption2).foregroundStyle(.tertiary)
                }

                // ★ 两边都有样本才敢给差额 —— 只有一边就是一句假话
                if let cost = stats.costOfBreaking {
                    Text(md: cost < 0
                         ? String(format: Loc.t("破了纪律的那些单,**平均每笔少赚 %@**。"),
                                  abs(cost).usd)
                         : String(format: Loc.t("破了纪律的那些单,平均每笔反而**多赚 %@** —— 样本还太少,别当结论。"),
                                  cost.usd))
                        .font(.subheadline)
                        .foregroundStyle(cost < 0 ? Theme.warn : Color.secondary)
                } else {
                    Text(md: "还比不出来 —— **守规矩的单和破戒的单,得两边都有**才谈得上差额。")
                        .font(.caption2).foregroundStyle(.tertiary)
                }

                ForEach(stats.tallies.filter { $0.broken > 0 }.prefix(5)) { t in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(LocalizedStringKey(t.text)).font(.subheadline)
                            Text(verbatim: String(format: Loc.t("破 %1$lld 次 · 守 %2$lld 次"),
                                                  t.broken, t.followed))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Text(verbatim: Money.signed(t.brokenPnL))
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                            .foregroundStyle(Theme.pnl(t.brokenPnL))
                    }
                }

                if stats.tallies.allSatisfy({ $0.broken == 0 }) {
                    Label("到目前为止,一条都没破", systemImage: "checkmark.seal.fill")
                        .font(.subheadline).foregroundStyle(Theme.profit)
                }

                Text(md: "右边那个数 = **破这一条的那些单,盈亏合计**。\n★ 没勾的不算「做到了」—— 所以这里的次数只会少算,不会多算。")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 18))
        }
    }
}
