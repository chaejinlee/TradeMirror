import SwiftUI

/// 截图导入之后立刻问原因。两种情形:
///
/// ① **还没平** → 问三件事:为什么开、止损在哪、止盈在哪(事前信息,只有现在问才算数)
/// ② **已经平了** → 问两件事:为什么开、为什么走
///
/// ★★ 2026-09-03 用户报:「完整的一笔完成的订单 ≥2 张截图放入软件之后
///   **不能填写交易入场以及出场原因**」。查下来是真的漏了一整条路:
///   `afterSave` 只在**未平仓**时弹这一页(`t.isClosed ? .review : .openPlan`),
///   而批量导入(`BatchImportView`)连 `afterSave` 都没调 ——
///   <b>一笔进来就是平的,于是永远没人问过原因</b>。
///   而「按开单原因/出场原因分组」正是历史页最有用的两块。
///
/// ★ 已平仓时**不问止损止盈**:那是事前信息,平仓后填等于**伪造当时的计划**,
///   风控统计(「止损到底有没有被碰到过」)会因此变成假的。没填就是没填。
///
/// ★★ 用户 2026-09-02:「当前开仓状态应该在我上传截图之后自动问我,
///   以及询问为什么开这单,止损止盈在哪」。
///
/// ★ 为什么必须**在这一刻**问:这三件事只有**事前**写下来才有意义。
///   等到复盘时再填,填的是「我事后觉得当时的理由」——
///   那和「当时真的这么想」是两回事,而且必然被结果带着走(规范 [C5])。
///   所以这一页在**保存开仓的下一秒**弹出来,而不是等你想起来。
///
/// ★ 可以跳过。**跳过会被如实记下来(留空)**,不会伪造一个理由。
struct OpenPlanView: View {
    @Environment(\.dismiss) private var dismiss
    let trade: Trade
    /// 填完的那一笔;**跳过时是 `nil`** —— 跳过不伪造理由,但流程要照样往下走。
    let onDone: (Trade?) -> Void

    @State private var reason: String
    @State private var customReason = ""
    @State private var exitReason: String
    @State private var customExit = ""
    @State private var stopText = ""
    @State private var targetText = ""

    init(trade: Trade, onDone: @escaping (Trade?) -> Void) {
        self.trade = trade; self.onDone = onDone
        _reason = State(initialValue: trade.entryReason ?? "")
        _exitReason = State(initialValue: trade.exitReason ?? "")
        _stopText = State(initialValue: trade.plannedStop.map { String(format: "%g", $0) } ?? "")
        _targetText = State(initialValue: trade.plannedTarget.map { String(format: "%g", $0) } ?? "")
    }

    /// 已经平掉的那一笔:问的东西不一样,文案也不一样。
    private var closed: Bool { trade.isClosed }

    private var entry: Double { trade.averageEntry }
    private var isLong: Bool { trade.legs.first.flatMap { trade.openingSide(of: $0) } != .sell }

    /// 实时算 R:R,让你在填的时候就看见这单值不值得做。
    private var rr: Double? {
        guard let s = Double(stopText), let t = Double(targetText), entry > 0 else { return nil }
        let risk = isLong ? entry - s : s - entry
        let reward = isLong ? t - entry : entry - t
        guard risk > 1e-9, reward > 0 else { return nil }
        return reward / risk
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("刚记下的") {
                        Text("\(trade.symbol) \(trade.legs.first?.kind.shortLabel ?? "")")
                            .fontWeight(.semibold)
                    }
                    LabeledContent("开仓均价", value: String(format: "%g", entry))
                    if closed, let p = trade.displayablePnL {
                        LabeledContent("盈亏") {
                            Text(verbatim: Money.signed(p))
                                .fontWeight(.semibold)
                                .foregroundStyle(Theme.pnl(p))
                        }
                        if let r = trade.returnOnDebit {
                            LabeledContent("收益率") {
                                Text(verbatim: r.signedPercent)
                                    .fontWeight(.semibold).monospacedDigit()
                                    .foregroundStyle(Theme.pnl(r))
                            }
                        }
                    } else {
                        LabeledContent("在手") {
                            Text("\(trade.openQuantity.cleanNum) "
                                 + (trade.legs.first?.kind.localizedUnit ?? ""))
                        }
                    }
                } header: {
                    Text(closed ? "这一笔已经平了" : "当前开仓状态")
                }

                Section {
                    ForEach(EntryReason.presets, id: \.self) { r in
                        Button {
                            reason = (reason == r) ? "" : r
                        } label: {
                            HStack {
                                Text(LocalizedStringKey(r)).foregroundStyle(Color.primary)
                                Spacer()
                                if reason == r {
                                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                    TextField("或者自己写(会覆盖上面的选择)", text: $customReason)
                } header: {
                    Text("为什么开这单")
                } footer: {
                    Text(md: "历史分析里会**按这个分组** —— 「哪一类理由的单更常赢」比「胜率多少」有用得多。")
                }

                if closed {
                    Section {
                        ForEach(ExitReason.presets, id: \.self) { r in
                            Button {
                                exitReason = (exitReason == r) ? "" : r
                            } label: {
                                HStack {
                                    Text(LocalizedStringKey(r)).foregroundStyle(Color.primary)
                                    Spacer()
                                    if exitReason == r {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                        }
                        TextField("或者自己写(会覆盖上面的选择)", text: $customExit)
                    } header: {
                        Text("为什么走")
                    } footer: {
                        Text(md: "历史页会拿它和「触及目标」对照 —— **「提前手动平」的盈亏明显更低,那是纪律问题,不是运气**。")
                    }
                }

                if !closed {
                Section {
                    LabeledContent("止损") {
                        TextField("这条腿的价格,不是标的", text: $stopText)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    LabeledContent("止盈") {
                        TextField("同上", text: $targetText)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    if let rr {
                        LabeledContent("计划 R:R") {
                            Text(String(format: "%.2f", rr))
                                .fontWeight(.semibold)
                                .foregroundStyle(rr >= 1.5 ? Theme.profit : Theme.warn)   // 比率不是亏损,不用红
                        }
                    }
                } header: {
                    Text("止损 / 止盈")
                } footer: {
                    if let rr, rr < 1.5 {
                        Text(md: String(format: Loc.t(
                            "R:R %@ **低于你自己定的 1.5** —— 现在还来得及不做。"),
                            String(format: "%.2f", rr)))
                    } else {
                        Text(md: "填了止损,以后才能算出「**止损到底有没有被碰到过**」。\n★ 你 8 月那 4 笔 **一次都没被触发** —— 风控从未经检验。")
                    }
                }
                }   // if !closed

                if closed {
                    Section {
                        Text(md: "★ 这一笔已经平了,所以**开单原因是事后回忆** —— 结果已知,回忆必然被结果带着走。它会被如实标成「事后补的」,历史页里单独计数。\n★ 止损止盈这里**不问**:平仓后填等于伪造当时的计划,风控统计会因此变成假的。")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            .navigationTitle(closed ? "这单的原因" : "这单的计划")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // ★ 可以跳过,但**跳过就是留空**,不会替你编一个理由
                    Button("跳过") { onDone(nil); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("记下") {
                        var t = trade
                        let custom = customReason.trimmingCharacters(in: .whitespacesAndNewlines)
                        t.entryReason = custom.isEmpty ? (reason.isEmpty ? nil : reason) : custom
                        if closed {
                            let cx = customExit.trimmingCharacters(in: .whitespacesAndNewlines)
                            t.exitReason = cx.isEmpty ? (exitReason.isEmpty ? nil : exitReason) : cx
                            // ★ 如实标记:结果已知之后填的原因,不能和事前填的混在一起算
                            if t.entryReason != nil { t.reasonsRecordedAfterOutcome = true }
                        } else {
                            t.plannedStop = Double(stopText)
                            t.plannedTarget = Double(targetText)
                        }
                        onDone(t)
                        dismiss()
                    }
                }
            }
        }
    }
}
