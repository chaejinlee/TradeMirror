import SwiftUI

/// 填某个月的券商笔数。
///
/// ★★ 这是**唯一能打破循环验证的东西**。在它之前,我给这个 App 写的每一条
///   「对上了」的测试,用的都是它自己导出来的数据 ——
///   OCR 读错一个数,导出里也是那个错数,<b>测试照样绿</b>。
///
/// ★ 2026-09-22 之前也有一张对账卡,但它问的是 `currentMonthKey()` —— **当月**。
///   <b>当月的月结单还没出,它一直在要一个不存在的数</b>,所以记录数一直是 0。
struct ReconcilePromptView: View {
    @Environment(\.dismiss) private var dismiss
    let ask: ReconciliationPrompt.Ask?
    var onSet: (Int, String) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    private var n: Int? { Int(text.trimmingCharacters(in: .whitespaces)) }

    var body: some View {
        NavigationStack {
            Form {
                if let ask {
                    Section {
                        LabeledContent("月份") { Text(verbatim: ask.monthKey) }
                        LabeledContent("App 里记了") {
                            Text(verbatim: String(format: Loc.t("%lld 笔"), ask.recorded))
                                .monospacedDigit()
                        }
                        HStack {
                            Text("券商月结单上")
                            Spacer()
                            TextField(Loc.t("几笔"), text: $text)
                                .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                                .focused($focused).frame(width: 90)
                        }
                    } footer: {
                        Text(md: "★★ 这是**唯一能查出「有交易没记进来」的办法**。\nApp 只知道你导进来的那些;没导的那些,它连不知道自己不知道。\n★ 对不上不一定是 bug —— 也可能是那天嫌烦没记。**知道差几笔本身就是信息。**")
                    }

                    let gap = (n ?? ask.recorded) - ask.recorded
                    if gap != 0 {
                        Section {
                            Label {
                                Text(verbatim: gap > 0
                                     ? String(format: Loc.t("有 %lld 笔没记进来"), gap)
                                     : String(format: Loc.t("App 里比券商多 %lld 笔"), -gap))
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                            }
                            .foregroundStyle(Theme.warn)
                        } footer: {
                            // ★ 不许写成  ——
                            //   本地化提取器只认**紧跟在  后面**的字面量,
                            //   三元表达式会让这两句<b>运行时查不到译文</b>(守卫刚逮到)。
                            if gap > 0 {
                                Text(md: "★ 漏掉的那几笔**多半不是随机的** —— 亏的那天更容易嫌烦不记。历史页上每一个数字都会因此偏乐观。")
                            } else {
                                Text(md: "多半是同一笔导了两遍。去交易列表里找找同一天同一合约的重复项。")
                            }
                        }
                    }

                    if ask.monthsOverdue > 1 {
                        Section {
                            Text(verbatim: String(format: Loc.t("还有 %lld 个月没对过。先对完这个,下次会问下一个。"),
                                                  ask.monthsOverdue - 1))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    ContentUnavailableView {
                        Label("暂时没有要对的月份", systemImage: "checkmark.circle")
                    } description: {
                        Text(md: "当月**不问** —— 月结单还没出。等这个月过完再来。")
                    }
                }
            }
            .navigationTitle("对账")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("以后再说") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("记下") {
                        if let ask, let n, n > 0 { onSet(n, ask.monthKey) }
                        dismiss()
                    }
                    .disabled(ask == nil || (n ?? 0) <= 0)
                }
                // 数字键盘没有回车键
                ToolbarItem(placement: .keyboard) {
                    HStack { Spacer(); Button("完成") { focused = false } }
                }
            }
            .onAppear { focused = true }
        }
    }
}
