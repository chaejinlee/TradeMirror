import SwiftUI

/// 交易规则(熔断器)的设置页。
///
/// ★★ 2026-09-22 复盘搬出来的:这几个数原来只长在「开仓前」那一屏的第三层里 ——
///   包括**净值**,而没有净值日亏上限根本判不了。
///   <b>一个「填一次就长期有效」的设置,不该藏在一个每次交易才走一遍的流程里。</b>
///   用户 23 笔已平仓里只有 6 笔填过心理状态 ⇒ 那一屏他四次里最多开一次。
///
/// ★ 同一份表单给两个地方用(这里 + 开仓前那一屏)——
///   规则只能有一处定义,界面也一样。
struct RulesView: View {
    @Environment(\.dismiss) private var dismiss
    @State var rules: TradingRules
    /// 今天已平仓的那些 —— 用来现场演示这几条规则此刻判成什么。
    var closedToday: [Trade] = []
    var onSave: (TradingRules) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("开启熔断器", isOn: $rules.enabled)
                } footer: {
                    Text(md: "关掉之后主页那条横幅也不再出现。★ **它只提醒,不会阻止你下单** —— 单是在券商下的,这里只是让你在下单前先看见。")
                }

                Section {
                    RulesEditor(rules: $rules)
                } header: {
                    Text("规则")
                }

                // ★★ 净值单独成段 —— 它是日亏上限的**分母**,没有它那条判不了。
                Section {
                    HStack {
                        Text("账户净值")
                        Spacer()
                        TextField(Loc.t("填一次,长期有效"), value: $rules.equity, format: .number)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("账户净值")
                } footer: {
                    if rules.equity == nil || (rules.equity ?? 0) <= 0 {
                        Text(md: "★★ **不填这个数,日亏上限那条就判不了** —— 它会显示「判不了」,而不是「通过」。\n填了之后,主页会在你今天已经亏到上限时直接挂一条出来。")
                            .foregroundStyle(Theme.warn)
                    } else {
                        let lim = (rules.equity ?? 0) * rules.dailyLossLimitPct / 100
                        Text(verbatim: String(format: Loc.t("今日亏到 %@ 就会挂提醒。"),
                                              (-lim).usdShort))
                    }
                }

                // 现在这几条判成什么 —— 设置页上就能看见效果,不用回主页猜
                Section {
                    let v = RuleEngine.standing(rules, .init(closedToday: closedToday))
                    if v.isEmpty {
                        Text("熔断器关着。").foregroundStyle(.secondary)
                    } else {
                        ForEach(v) { RuleRow(v: $0) }
                    }
                } header: {
                    Text("此刻判成什么")
                }
            }
            .navigationTitle("交易规则")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { onSave(rules); dismiss() }
                }
                ToolbarItem(placement: .keyboard) {
                    HStack { Spacer(); Button("完成") { hideKeyboard() } }
                }
            }
        }
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }
}

/// 规则的那几个 Stepper。★ 抽出来给两个地方共用。
struct RulesEditor: View {
    @Binding var rules: TradingRules
    var body: some View {
        Stepper("信心度门槛 \(rules.minConfidence)", value: $rules.minConfidence, in: 1...5)
        Stepper("连亏 \(rules.maxConsecutiveLosses) 笔当日停",
                value: $rules.maxConsecutiveLosses, in: 1...10)
        Stepper("亏损后冷静 \(rules.coolDownMinutesAfterLoss) 分钟",
                value: $rules.coolDownMinutesAfterLoss, in: 0...120, step: 5)
        Stepper("日亏上限:净值的 \(rules.dailyLossLimitPct.cleanNum)%",
                value: $rules.dailyLossLimitPct, in: 0.5...20, step: 0.5)
        Stepper("移动止损:从最高价回撤 \(Int(rules.trailingStopPct))%",
                value: $rules.trailingStopPct, in: 5...60, step: 5)
        Text(md: "★ 移动止损是**这条腿自己价格**的回撤 —— 不是标的的,也不是账户的。复盘页那条「若挂移动止损」用的就是这个数。")
            .font(.caption2).foregroundStyle(.secondary)
    }
}

/// 一条判定。★ `label`/`detail` 存的是格式 key,显示时才翻。
struct RuleRow: View {
    let v: RuleVerdict
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color).font(.caption)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: String(format: Loc.t(v.label), arguments: v.labelArgs))
                    .font(.subheadline)
                Text(verbatim: String(format: Loc.t(v.detail), arguments: v.detailArgs))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
    private var icon: String {
        switch v.level {
        case .pass:    "checkmark.circle.fill"
        case .warn:    "exclamationmark.triangle.fill"
        case .blocked: "xmark.octagon.fill"
        case .unknown: "questionmark.circle"
        }
    }
    private var color: Color {
        switch v.level {
        case .pass: .green
        case .warn: .orange
        case .blocked: .red
        case .unknown: .secondary
        }
    }
}
