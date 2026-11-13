import Foundation

/// 种子清单 —— **从用户 2026-09-03 发来的两页手写笔记认出来的**。
///
/// ★★ 必须说清楚:这是**我认手写字认出来的**,不是他打字给我的。
///   第二张照片(Follow / Avoid 那页)字迹清楚,基本可信;
///   第一张照片两页字小、连笔多,<b>有几条我认不准,已经在文案里标了「?」</b>。
///   ⇒ 所以手册**全部可改**,而且第一次打开时界面上就写着「请核对」。
///   <b>宁可让他改一遍,也不要在每笔交易后面板着脸问一条他从没写过的规矩。</b>
public extension DisciplineBook {

    /// 认不准的那几条,文案里带这个前缀 —— 用户一眼看得出该核对哪几行。
    static let uncertainMark = "?"

    static var seed: DisciplineBook {
        var order = 0
        func r(_ text: String, _ kind: DisciplineRule.Kind) -> DisciplineRule {
            order += 1
            return DisciplineRule(text: text, kind: kind, order: order)
        }

        return DisciplineBook(rules: [
            // ── 第二张照片:Follow(字迹清楚,可信)──
            r("绝不放弃", .follow),
            r("冷静思考", .follow),
            r("持续学习", .follow),

            // ── 第一张照片右页:交易者的心态(20 条,我只认出这些)──
            r("接受不可知、不可控的风险", .follow),
            r("同等接受赚钱和亏钱的交易", .follow),
            r("不和市场敌对", .follow),
            r("认真对待每一笔交易", .follow),
            r("不试图预测或控制市场", .follow),
            r("有信心、有自控力", .follow),
            r("只用自己承受得起的风险交易", .follow),
            r("交易时保持冷静", .follow),
            r("有能力面对现实", .follow),
            r("顺势交易", .follow),
            r("? 不在单边市场逆势交易", .follow),
            r("? 总是想着提高技术", .follow),

            // ── 第二张照片:Avoid(行为金融学的标准名词,可信)──
            r("损失厌恶", .avoid),
            r("锚定效应", .avoid),
            r("框架效应", .avoid),
            r("确认偏误", .avoid),
            r("心理账户", .avoid),
            r("禀赋效应", .avoid),
            r("现状偏见", .avoid),
            r("过度自信", .avoid),
            r("及时满足", .avoid),
            r("羊群效应", .avoid),

            // ── 第一张照片左页:毁灭交易的心理(15 条,认不准的已标 ?)──
            r("用自己亏不起的钱去交易", .avoid),
            r("冲动性交易", .avoid),
            r("赚钱后放松警惕", .avoid),
            r("不遵守自己的交易系统", .avoid),
            r("? 拿不住盈利,却拿得住亏损", .avoid),
            r("? 报复性交易", .avoid),
            r("? 重仓/一把梭", .avoid),
            r("? 死扛不止损", .avoid),
            r("? 亏损后急于回本", .avoid),
            r("? 让情绪主导交易", .avoid),
            r("? 过度解读单次交易结果", .avoid),
            r("? 只顾眼前,忽视长期", .avoid),
            r("? 在非交易时段交易", .avoid),
        ])
    }
}
