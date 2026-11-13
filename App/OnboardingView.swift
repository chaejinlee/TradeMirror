import SwiftUI

/// 新用户引导。
///
/// ★ 刻意**只做一屏,不做轮播** —— 多页轮播的完成率极低,用户会直接划到底点跳过。
/// 新用户只需要明白一件事:**这不是记账本**。
/// 你已经从券商 App 知道发生了什么;这里算的是「如果换个做法会怎样」。
///
/// ★ 「看个例子」比任何文案都有用:空 App 讲不清价值,
/// 让他先看见那张分叉图,一眼就懂了。
/// 但示例数据必须**明确标记、一键删掉、删了不回来**
/// —— 竞品就因为「删了还会自己回来」被打 1 星。
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    let onLoadSample: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                VStack(spacing: 10) {
                    Text("这不是记账本")
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                    Text(md: "你已经从券商 App 知道**发生了什么**。\n这里算的是 **如果换个做法会怎样**。")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 12)

                // 一眼看懂:实线是你走的,虚线是你没走的
                VStack(spacing: 6) {
                    ForkChart(actualPnL: 162, branches: [
                        ("拿到收盘", -591, false),
                        ("平一半",   -89,  false),
                        ("不加仓",    68,  false),
                        ("峰值出场", 351,  true),
                    ])
                    Text("实线是你走的 · 虚线是你没走的")
                        .font(.caption2).foregroundStyle(.tertiary)
                }

                VStack(alignment: .leading, spacing: 16) {
                    step("1", "券商里截个图",
                         Loc.t("在成交详情页截图,**分享 → 复盘镜**。不用切回相册。"))
                    step("2", "核对一眼",
                         Loc.t("标的、张数、成交价都认好了,你只需确认。**永不自动保存。**"))
                    step("3", "看四条替代路线",
                         Loc.t("拿到收盘会怎样、不加仓会怎样、平一半会怎样、峰值出场会怎样。"))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 18))

                VStack(spacing: 10) {
                    Button {
                        onLoadSample(); dismiss()
                    } label: {
                        Text("先看个例子").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)

                    Button("直接开始") { dismiss() }
                        .font(.subheadline)

                    Text(md: "例子会被标成「示例」,随时左滑删掉 —— **删了不会再回来**。")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }

                // ★ 这句话必须跟着行为改。v3.2 起复盘页会自动补当天 K 线 ——
                //   还写「只有你点按钮时才联网」就是**假的**,哪怕是往好的方向改。
                Text(md: "计算全在本机。**不连券商、不注册账号、没有广告。**\n联网只有一件事:取行情(代码 + 日期)。打开复盘页会自动补那天的 K 线,**这条可以在数据页关掉**。\n不提供投资建议,不给买卖信号 —— 只对你自己录入的、已经发生的交易做计算。")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 20)
            }
            .padding(.horizontal, 22)
        }
        .background(Color(.systemGroupedBackground))
        .interactiveDismissDisabled()
    }

    private func step(_ n: String, _ title: LocalizedStringKey,
                      _ body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(verbatim: n)
                .font(.footnote.weight(.bold)).foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(md: body).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
