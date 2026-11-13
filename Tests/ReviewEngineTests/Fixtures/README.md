# 真截图夹具

> **Public repository note:** the real brokerage screenshots this layer runs on contain account details, so they are kept private and are not committed. Without them, `RealScreenshotFixtureTests` is skipped automatically and every other test runs as usual. To run this layer locally, drop your own PNG screenshots here (they are git-ignored) and add matching `Expectation`s.


**这里放的是用户真实的券商截图,构建时会真的跑一遍 Vision OCR。**

## 为什么必须是真图

2026-09-03 用户报「仓位截图没识别成平仓」。当时 `WealthsimpleRealTests` 里
有一份「照抄真图」的文本,而且是绿的 —— 但那是**我以为的样子**,
不是 OCR 吐出来的样子。两者差了四处,每一处都是一个 bug:

| 我抄的 | OCR 真吐出来的 | 后果 |
|---|---|---|
| `10 x $0.12 USD` | `10 × SO.12 USD` | `$`→`S`、`0`→`O`,整行取不出数 ⇒ 成交价为空 |
| `3:43 pm` | `3:43pm`(无空格) | 时间正则结尾的 `\b` 匹配不上 ⇒ 取到状态栏时间 |
| `15:44` | `15:44  今正` | WiFi/电量被认成汉字,状态栏判据失效 |
| — | `Filled  September 3, 2026` | 裸 `filled` 当数量标签 ⇒ 张数读成 3 |

同样的教训 `Sanity.swift` 的注释里 09-01 就写过一次
(「测试测的是我的转录,不是真实链路」),两天后又犯。
**所以这一层必须由机器每次构建都跑,不能靠我记得。**

## 加一张新夹具

1. 图片放进这个目录(PNG;HEIC 用 `sips -s format png` 转)
2. 在 `RealScreenshotFixtureTests.swift` 里加一条 `Expectation`
3. `swift test` —— 它会真的 OCR 这张图再断言

## 隐私

这些图里有账户类型和金额。**本仓库目前没有远端**(`git remote -v` 为空),
截图不出本机。如果哪天要加远端,先把这个目录移出版本控制。

**现在已有公开远端:截图已移出版本控制(见 `.gitignore`),只留在本机。**
