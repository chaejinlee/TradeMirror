# 决策记录 —— 2026-08-30

> 每条决定都注明**证据来源**。凭偏好做的决定要标「无数据支撑」。

## 证据基础

1. **262 条竞品真实评论**(Apple 公开 customerreviews RSS,一手),其中交易日志类 **177 条**。
   ⚠️ **必须带的限定:RSS 只包含「写了文字」的评论。**绝大多数用户只点星不写字,
   而写字的人系统性偏不满 —— 所以下面的 45% 差评率**不等于**这些 App 的真实评分分布
   (它们显示的是 4.6–4.8★)。**这批数据能说「用户在抱怨什么」,不能说「多少人不满」。**
2. **App Store 搜索补全**(Apple 一手)。
3. **交易复盘的行业标准字段**(公开资料:R-multiple / MAE / MFE / expectancy)。

## 差评主题分布(177 条中 80 条 ≤3★)

| 主题 | 占差评 |
|---|---|
| **数据丢失 / P&L 算错** | **29%** |
| 同步 / 导入失败 | 25% |
| 订阅 / 计费怨气 | 21% |
| 期权 / 价差 / forex 不支持 | 21% |
| 客服无响应 | 20% |
| 时区 / 日期错位 | 6% |
| 崩溃 | 5% |

**跨 4 个 App 复现,不是某一家的问题。** 原话样本:
- 「over half of my data got deleted by the app」(SuperTrader)
- 「all my trades got deleted」「Update reset my results」(TradeTracker)
- 「First day on the app journaled trades, next day they were gone」(Leaprr)
- 「I had pnl's on Saturdays and Sundays」「shift my trades from Monday to Sunday」

---

## D1 · v1 不做云同步、不做券商同步 —— 本地优先

**证据:** 数据丢失 29% + 同步失败 25% = 差评的主要来源,**而这两类几乎全部由同步引入。**
**代价:** 用户要手动录入。有差评直说「you are better off using excel」「Useless, you have to put everything manually」。
**对策:** 录入速度是 v1 的一等公民,不是次要体验。
**这不是回避难点,是把难点花在别处。**

## D2 · 交易日按交易所时区判定,不跟设备走

**证据:** 「pnl's on Saturdays and Sundays」是跨 App 的可见症状,根因都是用设备本地时区归日期。
**实现:** `TradingDay.swift`,固定 `America/New_York`,自动处理夏令时。
存库与分组一律用 `YYYY-MM-DD` 字符串,**不用 `Date` 直接比较**。
**测试锁死:** 纽约当晚 20:00(UTC 已是次日)必须仍归当天。

## D3 · fill 级 schema —— 这是竞品做不到的那件事

**证据(1★/3★ 原话):**
- 「Can't even enter multiple entries to same stock (symbol). Why?」
- 「you can't include add-on buys. You have to do a separate transaction」
- 「Cant track call option spreads!」
- 「does not track gains unless you input the entry and exit points at the same time」

**⇒ 规范里最核心的设计(fill 级),恰好是竞品的硬伤,而且用户在 1 星评论里点名要它。**
规范原话:「只存 avg_entry 的话,浮亏加仓这个行为在数据里彻底消失」——
现在有了第二个理由:**竞品连录都录不进去。**

## D4 · 免费无内购 —— 从「学签变通」升级为定位优势

**证据:** 订阅/计费怨气占差评 21%(「paid $20 for LIFETIME access」后出问题、
「purchased monthly 8.99 but was charged 22 USD」)。
且 Apple 补全里 **`trading journal free` 是真实搜索词**。
**原本这条只是为了绕开学签收入问题,现在它同时是差异化。**

## D5 · `rule_scale_out` 做**可算的简化版**,不做完整版

用户实际规则 = 「触及目标平 50% + **剩余移动止损**」。
移动止损**何时**触发要分钟级路径,v1 拿不到。
但把后半段换成「持有到强平」后,剩余部分的结局就是 `holdToClose` 已知的数
⇒ **整条规则只用「成交明细 + 一个收盘价」就能算完。**
`note` 里必须写明「这是简化版,去掉了移动止损那条腿」,**不许冒充完整版**。

**08-06 实算:平 2 留 1 → 502,实际 753 ⇒ 判「你做得更好」。**
这是第三条判用户做对的反事实 —— **0DTE 里「分批出场让利润奔跑」当天是错的。**

## D6 · 收盘价只问一个数,歧义不会出现

上一轮我说规范「内部不一致(715.56 vs 715.21)」—— **那是我读错了**:
`post_exit_path` 末点是 **15:55 采样**,`eod_underlying` 是**收盘价**,两个不同时刻。
且用户硬规则是 15:50 强平。⇒ v1 只设**一个**用户填写字段「强平/收盘时的标的价」,
没有第二个来源可以矛盾。v2 接行情源后,路径末点为权威,该字段变只读。

## D7 · 术语对齐行业标准

`exit_vs_peak` 就是行业通用的 **MFE 捕获率**(「平均 MFE 3.4R vs 实际出场 1.7R ⇒ 只吃到 50%」)。
用标准术语,用户理解与 App Store 搜索都更好。
同时补 **MAE** —— 规范没有,但它是标准字段。
**v1 的 MAE 只能从成交点观测,是下界不是真值,`label` 必须写「≥」。把下界说成真值等于编数据。**

## 未采纳(记下来,连同理由)

| 需求 | 呼声 | 为什么 v1 不做 |
|---|---|---|
| Robinhood 等券商同步 | kinfo 差评里 4 次点名 | 正是 D1 里 bug 的最大来源 |
| forex / 期货 / prop firm | 多个 App 被点名 | 先把美股+期权做对;扩品类是 v2 |
| 云备份 | 未直接出现 | 与 D1 冲突;v1 用系统导出(用户自己掌握文件) |
