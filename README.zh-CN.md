# TradeMirror(暂名)—— 交易复盘的**反事实计算器**

> 不是记录器。你已经从券商 app 知道「发生了什么」;
> 这里唯一的增量是 **「如果换个做法会怎样」**。

规范见主仓 `qqq_trader/review_ai_spec.md`(411 行,从 2026-08-03~08-06 五笔真实交易反推)。

## v1 范围(刻意砍到一条流程)
记一笔(fill 级)→ 可选冻结开仓检查 → 平仓后填两个价位 → **看反事实表** → 模式计数器 + never_happened

**零 LLM · 零服务器 · 零账号 · 离线可用。**
理由:规范 §4 那张「代码算 vs AI 判断」的表里,左栏就是产品本身,而左栏一条都不需要 AI。

## 已锁死的两条口径(改动前先读测试)
1. **IV 用交易时间口径**(252d × 6.5h),不是日历时间。
   同一笔真实成交:交易时间 → 12.34%(与规范记录的 12.0% 吻合);日历 → 28.54%。**差 2.4 倍。**
2. **反事实必须双向**(规范 [C7])。差额为负 = 用户做对了,与「少赚了」同等呈现。
   只算一个方向的反事实计算器会退化成**后悔生成器**。

## 测试
```
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test
```
黄金用例是 2026-08-06 QQQ 717C 0DTE 的真实成交,数字来自 `review_payload_example.json`。
**引擎算不出这些数,就是引擎错了。**

## 构建与运行

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # 绕过 xcode-select,不需要 sudo
swift test                                                         # 引擎 19 个测试
python3 gen_xcodeproj.py                                           # ★ 生成器驱动,不要手改 .pbxproj
xcodebuild -project TradeMirror.xcodeproj -scheme TradeMirror \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath .build/xc build
```

DEBUG 启动参数(供自动化验证,Release 里不存在):
`--seed-demo` 写入 08-06 那笔真实交易 · `--open-review` 直接打开反事实页 · `--prefill` 预填两个价位。

## 界面顺序 = 价值顺序

反事实卡片排在明细之前,且**按可执行性排序**:
`持有到收盘` → `平一半` → `不加仓` → `峰值`(最后,并常驻「这是事后视角」的警告)。
规范 §3.1:峰值单独放主位会把 App 变成后悔生成器。

## 真机安装

工程文件由 `gen_xcodeproj.py` 生成,**不要手改 .pbxproj** —— 重跑会覆盖。
但 Xcode 在 Signing & Capabilities 里选过 Team 之后会把 `DEVELOPMENT_TEAM` 写进 pbxproj,
所以生成器会从 **`.developer_team`(本地文件,不入库)** 或环境变量 `DEVELOPMENT_TEAM` 读回来。

别人克隆本仓库时,自己建一个 `.developer_team` 写上自己的 Team ID 即可(或在 Xcode 里选一次)。

```bash
./install_to_iphone.sh          # 自检前置条件 + 构建 + 安装
```
