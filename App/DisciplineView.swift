import SwiftUI

/// 平仓之后的**纪律自检** —— 照你自己那本笔记本上的规矩逐条问。
///
/// ★ 用户 2026-09-03:「完成每单就按照里面的问我遵守了哪些,没遵守哪些」。
///
/// ★★ 三态,不是两态:**做到 / 没做到 / 没勾**。
///   「没勾」就是没勾 —— 不许悄悄算成「做到了」。
///   这个 App 里同一条规矩已经出现过很多次:
///   未平仓不显示盈亏、贷记开仓不给收益率、时间没填就显示 `--:--`。
///   <b>拿一个假数字让人安心,是这里最不该做的事。</b>
struct DisciplineCheckView: View {
    @Environment(\.dismiss) private var dismiss
    let trade: Trade
    let book: DisciplineBook
    /// 填完(或跳过)。跳过时传 nil。
    var onDone: (DisciplineCheck?) -> Void

    @State private var state: [UUID: Bool] = [:]      // true = 做到,false = 没做到

    private var answered: Int { state.count }
    private var broken: Int { state.values.filter { !$0 }.count }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let p = trade.displayablePnL {
                        LabeledContent("这一笔") {
                            HStack(spacing: 8) {
                                Text(verbatim: trade.symbol).fontWeight(.semibold)
                                Text(verbatim: Money.signed(p))
                                    .foregroundStyle(Theme.pnl(p))
                                    .monospacedDigit()
                            }
                        }
                    }
                    if answered > 0 {
                        LabeledContent("已经答了") {
                            Text(verbatim: String(format: Loc.t("%1$lld 条 · 没做到 %2$lld"),
                                                  answered, broken))
                                .foregroundStyle(broken > 0 ? Theme.warn : Color.secondary)
                        }
                    }
                } footer: {
                    // ★ 先把「为什么现在问」说清楚 —— 否则这就是一张烦人的表
                    Text(md: "**趁还记得**逐条过一遍。攒够几笔之后,历史页会告诉你**哪一条最常破、破了那些单亏了多少** —— 那才是这张表的用处。\n★ 拿不准的**就别勾**:没勾不会被算成「做到了」。")
                }

                section(.follow, title: "要做到的", icon: "checkmark.seal")
                section(.avoid, title: "要避开的", icon: "exclamationmark.triangle")
            }
            .navigationTitle("这单守规矩了吗")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // ★ 可以跳过。跳过 = 没答,不是「都做到了」。
                    Button("跳过") { onDone(nil); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("记下") {
                        onDone(DisciplineCheck(
                            followed: state.filter { $0.value }.map(\.key),
                            broken: state.filter { !$0.value }.map(\.key)))
                        dismiss()
                    }
                    .disabled(answered == 0)
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ kind: DisciplineRule.Kind,
                         title: LocalizedStringKey, icon: String) -> some View {
        let rules = book.active(kind)
        if !rules.isEmpty {
            Section {
                ForEach(rules) { rule in
                    HStack(spacing: 10) {
                        // ★ 存档值:存中文、显示译文。用户自己写的查不到 ⇒ 原样显示
                        Text(LocalizedStringKey(rule.text))
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        // ★ 两个按钮而不是一个开关 —— 开关只有两态,
                        //   而这里必须能表达「我没答」。
                        Button {
                            toggle(rule.id, to: true)
                        } label: {
                            Image(systemName: state[rule.id] == true
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(state[rule.id] == true
                                                 ? Theme.profit : Color.secondary)
                        }
                        Button {
                            toggle(rule.id, to: false)
                        } label: {
                            Image(systemName: state[rule.id] == false
                                  ? "xmark.circle.fill" : "circle")
                                .foregroundStyle(state[rule.id] == false
                                                 ? Theme.loss : Color.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Label(title, systemImage: icon)
            } footer: {
                if kind == .avoid {
                    Text(md: "「要避开的」勾 ✓ 表示**避开了**,勾 ✗ 表示**犯了**。")
                }
            }
        }
    }

    /// 再点一次同一个 = 取消,回到「没答」。
    private func toggle(_ id: UUID, to v: Bool) {
        if state[id] == v { state[id] = nil } else { state[id] = v }
    }
}

/// 纪律手册的编辑页。
///
/// ★★ 为什么必须能改:种子清单是**我认手写字认出来的**。
///   认错一条,它就会在每一笔交易后面板着脸问一个你从没写过的规矩。
struct DisciplineBookView: View {
    @Environment(\.dismiss) private var dismiss
    @State var book: DisciplineBook
    var onSave: (DisciplineBook) -> Void

    @State private var newText = ""
    @State private var newKind: DisciplineRule.Kind = .follow

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(md: "★ 这份清单是**从你笔记本的照片里认出来的** —— 手写字我不敢保证全认对。\n带 **?** 的那几条是我**认不准**的,请对着本子核对一下;改错、删掉、加新的都行。")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                editSection(.follow, title: "要做到的")
                editSection(.avoid, title: "要避开的")

                Section {
                    Picker("放到哪一类", selection: $newKind) {
                        Text("要做到的").tag(DisciplineRule.Kind.follow)
                        Text("要避开的").tag(DisciplineRule.Kind.avoid)
                    }
                    HStack {
                        TextField("再加一条", text: $newText)
                        Button {
                            add()
                        } label: { Image(systemName: "plus.circle.fill") }
                            .disabled(newText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("自己加")
                }

                Section {
                    Button(role: .destructive) {
                        book = .seed
                    } label: { Label("恢复成最初那份", systemImage: "arrow.counterclockwise") }
                } footer: {
                    Text("会覆盖你改过的内容,连同自己加的那些一起。")
                }
            }
            .navigationTitle("纪律手册")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { onSave(book); dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func editSection(_ kind: DisciplineRule.Kind, title: LocalizedStringKey) -> some View {
        let idx = book.rules.indices.filter { book.rules[$0].kind == kind }
        Section {
            ForEach(idx, id: \.self) { i in
                HStack(spacing: 8) {
                    // 关掉的留着但不问 —— 删掉会连历史统计里的名字一起丢
                    Button {
                        book.rules[i].enabled.toggle()
                    } label: {
                        Image(systemName: book.rules[i].enabled
                              ? "checkmark.square.fill" : "square")
                            .foregroundStyle(book.rules[i].enabled
                                             ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    TextField("规矩", text: Binding(
                        get: { book.rules[i].text },
                        set: { book.rules[i].text = $0 }))
                        .foregroundStyle(book.rules[i].enabled ? .primary : .secondary)
                }
            }
            .onDelete { off in
                let ids = off.map { idx[$0] }
                book.rules.remove(atOffsets: IndexSet(ids))
            }
        } header: {
            Text(title)
        } footer: {
            if kind == .follow {
                Text("左边的勾去掉 = 留着但不再问。★ 直接删掉的话,历史统计里那条的名字也会跟着没。")
            }
        }
    }

    private func add() {
        let t = newText.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        book.rules.append(DisciplineRule(text: t, kind: newKind,
                                         order: (book.rules.map(\.order).max() ?? 0) + 1))
        newText = ""
    }
}
