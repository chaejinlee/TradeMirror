import SwiftUI

/// 记录开仓时的心理状态。
///
/// ★ `beforeOutcome` 决定这条记录**算不算数** ——
/// 事后补的必然被结果污染(赚了选冷静、亏了选冲动),所以它不参与任何统计,
/// 而且界面上必须**明说**,不能让用户以为自己记了就有用。
struct PsychologyView: View {
    @Environment(\.dismiss) private var dismiss
    /// true = 开仓前记(算数);false = 事后补(只留档)
    let beforeOutcome: Bool
    let initialSymbol: String
    let existing: Psychology?
    let onSave: (String, Psychology) -> Void
    /// 开仓前的纪律检查上下文(仅 beforeOutcome 时有意义)。
    var rules: TradingRules? = nil
    var closedToday: [Trade] = []
    var onSaveRules: ((TradingRules) -> Void)? = nil
    @State private var showRules = false
    @State private var draftRules = TradingRules()

    @State private var symbol: String
    @State private var states: Set<String>
    @State private var confidence: Int
    @State private var plan: String

    init(beforeOutcome: Bool, initialSymbol: String = "", existing: Psychology? = nil,
         rules: TradingRules? = nil, closedToday: [Trade] = [],
         onSaveRules: ((TradingRules) -> Void)? = nil,
         onSave: @escaping (String, Psychology) -> Void) {
        self.rules = rules; self.closedToday = closedToday; self.onSaveRules = onSaveRules
        _draftRules = State(initialValue: rules ?? TradingRules())
        self.beforeOutcome = beforeOutcome
        self.initialSymbol = initialSymbol
        self.existing = existing
        self.onSave = onSave
        _symbol = State(initialValue: initialSymbol)
        _states = State(initialValue: Set(existing?.states ?? []))
        _confidence = State(initialValue: existing?.confidence ?? 3)
        _plan = State(initialValue: existing?.plan ?? "")
    }

    private var redFlagged: Bool { states.contains { Psychology.redFlags.contains($0) } }

    private func verdicts(_ r: TradingRules) -> [RuleVerdict] {
        RuleEngine.check(r, .init(confidence: confidence, closedToday: closedToday,
                                  allClosed: closedToday))
    }
    private func icon(_ l: RuleVerdict.Level) -> String {
        switch l {
        case .pass:    return "checkmark.circle.fill"
        case .warn:    return "exclamationmark.triangle.fill"
        case .blocked: return "hand.raised.fill"
        case .unknown: return "questionmark.circle"
        }
    }
    private func color(_ l: RuleVerdict.Level) -> Color {
        switch l {
        case .pass: return .green
        case .warn: return .orange
        case .blocked: return .red
        case .unknown: return .secondary
        }
    }

    /// ★★ 2026-09-22:这几个 Stepper 原来在这里写了一份,`RulesView` 里又要一份。
    ///   <b>同一件事写两遍,迟早会分叉</b>(这个项目在周起点、counterfactualRank 上栽过)。
    ///   ⇒ 统一用 `RulesEditor`。
    /// ★ 净值**搬走了** —— 它是「填一次长期有效」的设置,
    ///   不该藏在一个每次交易才走一遍的流程里(那正是它一直没被填的原因)。
    @ViewBuilder private var rulesEditor: some View {
        RulesEditor(rules: $draftRules)
        Button("保存规则") { onSaveRules?(draftRules) }.font(.footnote)
    }

    var body: some View {
        Form {
            if !beforeOutcome {
                Section {
                    Label(md: "这是**事后补记**的。它会存下来,但**不参与任何统计** —— 你已经知道结果了,这时候选的心情必然被结果带着走。",
                        systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(Theme.warn)
                }
            }

            if beforeOutcome {
                Section("准备做哪个") {
                    TextField("标的(如 QQQ)", text: $symbol)
                        .textInputAutocapitalization(.characters)
                }
            }

            Section {
                // ★★ 2026-09-24:原来是 9 行勾选清单,一屏只放得下它,像在填问卷。
                //   开仓前那几秒最不该让人觉得麻烦 —— 一麻烦就不记了(23 笔里只记了 6 笔)。
                //   ⇒ 标签云:一眼看完,点一下就选中。
                FlowLayout(spacing: 8) {
                    ForEach(Psychology.vocabulary, id: \.self) { v in
                        ChipToggle(label: LocalizedStringKey(v), on: states.contains(v),
                                   tint: Psychology.redFlags.contains(v) ? Theme.warn : .accentColor) {
                            if states.contains(v) { states.remove(v) } else { states.insert(v) }
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("现在的状态(可多选)")
            } footer: {
                Text(md: "这些都是**当下能观察到的状态**,不是「损失厌恶」那种事后诊断 —— 让你在开仓时给自己贴诊断标签,只会变成先有结论再找证据。")
            }

            if redFlagged {
                Section {
                    // ★ 原来写「规范里你自己写的是」—— 「规范」是我内部的设计文档,用户不知道那是什么。
                    Label(md: "这是你自己说过的那种会出事的状态:**连续小止损后不愿承认亏损,情绪加仓想一把赚回来,结果亏更多。**",
                        systemImage: "flame.fill")
                    .font(.footnote).foregroundStyle(Theme.warn)
                }
            }

            Section {
                Picker("信心度", selection: $confidence) {
                    ForEach(1...5, id: \.self) { Text("\($0)").tag($0) }
                }.pickerStyle(.segmented)
                if confidence < 4 {
                    Label("你的硬规则:信心度 < 4 不开单。", systemImage: "hand.raised.fill")
                        .font(.footnote).foregroundStyle(Theme.warn)
                }
            } header: { Text("信心度") }

            Section("打算怎么做(原话,别整理)") {
                TextField("可留空", text: $plan, axis: .vertical).lineLimit(1...5)
            }

            // ★ 纪律检查:**在开仓那一刻做,并冻结**。规范 §2.3「绝对不要事后重算」。
            if beforeOutcome, let r = rules {
                Section {
                    ForEach(verdicts(r)) { v in
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: icon(v.level))
                                .foregroundStyle(color(v.level)).font(.subheadline)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: v.labelText).font(.subheadline)
                                Text(verbatim: v.detailText)
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    if verdicts(r).contains(where: { $0.level != .pass && $0.level != .unknown }) {
                        Label(md: "保存这条计划 = **系统警告过、你仍然要做**。这条记录会被冻结下来,以后能看到「警告过 N 次,做了 M 次」。",
                            systemImage: "hand.raised.fill")
                        .font(.footnote).foregroundStyle(Theme.warn)
                    }
                    Button { showRules.toggle() } label: {
                        Label(showRules ? "收起规则设置" : "改我的规则", systemImage: "slider.horizontal.3")
                            .font(.footnote)
                    }
                    if showRules { rulesEditor }
                } header: {
                    Text("开仓前检查(此刻冻结)")
                } footer: {
                    Text(md: "这一栏**不会**事后重算。事后重算带幸存者偏差,而且会丢掉「警告过、仍然做了」这条行为记录 —— 那才是最能预测未来违规的东西。")
                }
            }
        }
        .navigationTitle(beforeOutcome ? "开仓前" : "补记当时的状态")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    var snap: RuleSnapshot? = nil
                    if beforeOutcome, let r = rules {
                        let vs = verdicts(r)
                        let warned = vs.contains { $0.level == .warn || $0.level == .blocked }
                        snap = RuleSnapshot(verdicts: vs, proceededAnyway: warned)
                    }
                    onSave(symbol.uppercased(),
                           Psychology(states: Array(states).sorted(), confidence: confidence,
                                      plan: plan.isEmpty ? nil : plan,
                                      beforeOutcome: beforeOutcome, ruleSnapshot: snap))
                    dismiss()
                }
                .disabled(states.isEmpty || (beforeOutcome && symbol.isEmpty))
            }
        }
    }
}

extension Label where Title == Text, Icon == Image {
    /// markdown 版 Label(`Text(md:)` 的配套)。
    init(md: String, systemImage: String) {
        self.init(title: { Text(md: md) }, icon: { Image(systemName: systemImage) })
    }
}
