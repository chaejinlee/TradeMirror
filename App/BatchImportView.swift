import SwiftUI

/// 批量导入的确认页。
///
/// ★ 用户原话:「不该一遍又一遍查找然后输入」。
/// 一笔交易在 Wealthsimple 是两张截图,一天 5 笔就是 10 张 —— 原来要走 10 遍流程。
/// 这里:**一次多选 → 自动配对 → 一次确认**。
///
/// 仍然守住那条底线:**永不自动保存**,每一组都摆出来让用户看过再存。
struct BatchImportView: View {
    @Environment(\.dismiss) private var dismiss
    /// ★ 改成 `@State`:确认页现在能**就地补上没读出来的价** ——
    ///   原来这里是死路,缺价的那张只有一个小问号,保存时被静默扔掉。
    @State var drafts: [BatchImporter.Draft]
    /// 这次导入的账:选了几张、少的几张去哪了。
    let tally: ImportTally
    let onConfirm: ([BatchImporter.Draft]) -> Void

    /// 正在手填的那个格子。
    @FocusState private var editing: String?

    /// 全部都能存进去。★ 有一张存不进去就**不许保存** —— 见 `Draft.isComplete`。
    private var allComplete: Bool { drafts.allSatisfy(\.isComplete) }
    private var blockedCount: Int { drafts.reduce(0) { $0 + $1.unfillableParts.count } }

    var body: some View {
        List {
            Section {
                Text("\(drafts.count) 笔交易 · 来自 \(drafts.reduce(0) { $0 + $1.parts.count }) 张截图")
                    .font(.subheadline.weight(.medium))
                Text("同一合约的开仓与平仓已经自动配到一起了。核对无误再保存。")
                    .font(.caption).foregroundStyle(.secondary)
                // ★★ 「你选了几张」这个数,以前从来没到过这一屏。
                //   8 进 5 出,差额只有用户自己发现 —— 那不该是他的活。
                if let note = tally.note({ Loc.t($0) }) {
                    // ★ `note` 已经是译好的整句 —— 再当 key 查一次会查不到并原样吐回
                    Label { Text(verbatim: note) }
                          icon: { Image(systemName: "exclamationmark.triangle.fill") }
                        .font(.caption).foregroundStyle(Theme.warn)
                }
            }

            // ★★ 有存不进去的 ⇒ 先说清楚**后果**,再让他补。
            //   不写「有个字段没识别出来」这种轻描淡写的话:
            //   少一笔成交 = 张数对不上 = 这笔永远平不了 = 不进任何统计。
            if !allComplete {
                Section {
                    Text(md: "有 **\(blockedCount) 张**截图缺了必需的字段,下面标成红色。\n★ 少存一笔成交,**整笔交易的张数就对不上** —— 它会一直显示「未平仓」,盈亏永远算不出来,也不会进胜率和战绩格子。\n⇒ 请把红色那几行的数字照着原图补上,或者取消、单张重新导入。")
                        .font(.caption)
                }
                .listRowBackground(Theme.loss.opacity(0.08))
            }

            ForEach($drafts) { $d in
                Section {
                    ForEach(Array(d.parts.enumerated()), id: \.offset) { idx, p in
                        HStack(spacing: 10) {
                            // ★ 这里原来写死 22pt —— 够放「买」「卖」,
                            //   却放不下 "Buy" / "Sell",英文下被折成「Bu / y」。
                            //   <b>按中文字数定的固定宽度,换了语言就崩。</b>
                            Text(p.side?.value == .buy ? "买" : "卖")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(p.side?.value == .buy ? Theme.buy : Theme.sell)
                                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                                .frame(minWidth: 22, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: contractLine(p)).font(.subheadline)
                                Text(verbatim: detailLine(p)).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !p.canBecomeFill {
                                // ★ 缺价就地补。<b>把死路变成一个能填的格子</b> ——
                                //   原来只有一个橙色问号,而它既不解释、也不能改。
                                if p.price == nil, p.quantity != nil, p.side != nil {
                                    priceField($d, idx)
                                } else {
                                    Text(verbatim: String(format: Loc.t("缺 %@"),
                                                          p.fillBlockers({ Loc.t($0) }).joined(separator: "、")))
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(Theme.loss)
                                }
                            } else if !p.missing.isEmpty {
                                Image(systemName: "questionmark.circle.fill")
                                    .foregroundStyle(Theme.warn).font(.caption)
                            }
                        }
                        .listRowBackground(p.canBecomeFill ? nil : Theme.loss.opacity(0.10))
                    }
                    if !d.reason.isEmpty {
                        Text(verbatim: d.reason).font(.caption2).foregroundStyle(.tertiary)
                    }
                    if d.mergeInto != nil {
                        Label("并进已有的那一笔", systemImage: "arrow.triangle.merge")
                            .font(.caption).foregroundStyle(Theme.buy)
                    }
                } header: {
                    Text(verbatim: d.parts.first?.symbol?.value ?? "?")
                }
            }

            Section {
                Text("标的价截图里没有 —— 留空即可,只影响「若在峰值出场」那一条。收盘价在复盘页填一次,当天同标的全部交易共用。")
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("确认 \(drafts.count) 笔")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("全部保存") { onConfirm(drafts); dismiss() }
                    // ★★ 有一张存不进去就挡住。存个残的比存不进去更糟 ——
                    //   残的会安安静静地待在列表里,永远「未平仓」。
                    .disabled(drafts.isEmpty || !allComplete)
            }
            // 数字键盘没有回车键 —— 给一个「完成」
            ToolbarItem(placement: .keyboard) {
                HStack { Spacer(); Button("完成") { editing = nil } }
            }
        }
    }

    /// 缺价那一格的输入框。★ 存的时候走引擎的 `fillInPrice`(0 和负数不算填)。
    @ViewBuilder
    private func priceField(_ d: Binding<BatchImporter.Draft>, _ idx: Int) -> some View {
        let key = "\(d.wrappedValue.id)-\(idx)"
        HStack(spacing: 4) {
            Text(verbatim: "$").font(.caption).foregroundStyle(Theme.loss)
            TextField(Loc.t("成交价"), text: Binding(
                get: { typed[key] ?? "" },
                set: { v in
                    typed[key] = v
                    if let x = Double(v.replacingOccurrences(of: ",", with: ".")) {
                        d.wrappedValue.fillInPrice(x, atPartIndex: idx,
                                                   source: Loc.t("手动填写"))
                    }
                }))
                .keyboardType(.decimalPad)
                .focused($editing, equals: key)
                .multilineTextAlignment(.trailing)
                .frame(width: 68)
                .textFieldStyle(.roundedBorder)
        }
    }

    /// 输入框里的原文。★ 单独存:直接绑到 `price` 上的话,
    /// 输到一半的 `0.` 会被 `Double("0.")` 判成合法而把光标搅乱。
    @State private var typed: [String: String] = [:]

    private func contractLine(_ p: ParsedTrade) -> String {
        var s = p.symbol?.value ?? "?"
        if let r = p.right?.value, let k = p.strike?.value {
            s += " \(k.cleanNum)\(r == .call ? "C" : "P")"
        }
        return s
    }
    private func detailLine(_ p: ParsedTrade) -> String {
        var bits: [String] = []
        if let q = p.quantity?.value, let px = p.price?.value {
            bits.append("\(q.cleanNum) @ \(String(format: "%g", px))")
        }
        if let t = p.time?.value, let h = t.hour {
            bits.append(String(format: "%02d:%02d", h, t.minute ?? 0))
        }
        // ★ 按**当下的字段**算,不读解析时那份快照 —— 补完价还挂着「缺:成交价」就是那么来的
        let lack = p.missing.filter { $0 != "成交价" || p.price == nil }
        if !lack.isEmpty { bits.append(String(format: Loc.t("缺:%@"), lack.joined(separator: "、"))) }
        return bits.joined(separator: " · ")
    }
}
