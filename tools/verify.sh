#!/bin/bash
# 交付前的统一验证入口。**任何一步失败就停。**
#
# ★★ 2026-09-01 第二次翻车,就翻在这个文件自己身上:
#    原来写的是  xcodebuild ... | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
#    `set -e` 看的是**整条管道**的退出码,也就是 grep 的 ——
#    grep **成功匹配到 "BUILD FAILED"** 就返回 0,于是脚本继续往下,打印「✅ 全部通过」。
#    实测:构建失败,这个脚本照样报成功。`swift test` 那行是同一个洞。
#
#    这和很久以前 `swiftc ... | tail && echo ✅` 的 bug 是**同一个**。
#    我建了守卫防止自己绕过 —— 然后守卫自己在撒谎。
#    ⇒ 规则:凡是把命令接进管道,就必须 `set -o pipefail` 或显式看 PIPESTATUS,
#      并且**断言成功的证据**,而不是「没看到失败字样」。
set -e
set -o pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
LOG=.build/verify.log; mkdir -p .build

fail() { echo "❌ $1"; exit 1; }

echo "── 版本号守卫 ──"
python3 tools/check_version.py || fail "版本号守卫未通过"

echo "── markdown 守卫 ──"
python3 tools/check_markdown.py || fail "markdown 守卫未通过"

# ★ 金额写法守卫(2026-09-24 美化时加的)。
#   `.currency(code: "USD")` 在中文区域下写成 `US$42` —— 那正是这次要清掉的东西。
#   金额一律走引擎的 `Money`(有测试);这里防它从哪个新视图里溜回来。
echo "── 金额写法守卫 ──"
if grep -rn 'currency(code: "USD")' App/*.swift; then
  fail "上面这些地方又用了 .currency(code: \"USD\") —— 中文下会显示 US\$,改用 Money.signed / Money.plain"
fi
# ★ 盈亏必须带符号。2026-09-24 第一轮美化时我把 15 处批量换成 Money.plain,
#   没区分是不是盈亏 —— 于是历史页出现了 `$2,748`(该是 `+$2,748`),自己引入、下一轮才看见。
#   名字里带 pnl 的变量用 plain,基本就是这个错。
if grep -rnE 'Money\.plain\([^)]*[pP]n[lL]' App/*.swift; then
  fail "上面这些是盈亏却用了 Money.plain(不带 + 号)—— 改 Money.signed"
fi
echo "✅ 金额都走 Money,盈亏都带符号"

# ★ 颜色守卫(2026-09-24)。美化前全 App 有 71 处写死的红绿、56 处橙色,每屏各选各的 ——
#   同一个「卖」在 K 线图上是紫色、在成交列表里是橙色(而橙色又是警告色)。
#   颜色只在 Theme.swift 里定义;别的文件出现写死的红绿橙紫就拦。
echo "── 颜色守卫 ──"
if grep -rnE 'Color\.(green|red|orange|purple)|foregroundStyle\(\.(green|red|orange|purple)\)|\? \.(green|red|orange)\b' App/*.swift | grep -v '^App/Theme.swift'; then
  fail "上面这些地方写死了颜色 —— 改用 Theme.profit / loss / alt / warn / open / buy / sell"
fi
echo "✅ 颜色都走 Theme"

echo "── 单元测试 ──"
set +e; swift test > "$LOG" 2>&1; rc=$?; set -e
# ★ `|| true`:构建失败时这行**一个字都匹配不到**,而 `set -e` + `pipefail`
#   会让脚本在这里就死掉 —— 退出码是 1(没错),但**一句原因都不打印**。
#   2026-09-03 实测:删掉夹具跑一遍,只看到「── 单元测试 ──」然后就没了。
#   <b>没有诊断的失败,和错的诊断一样难查。</b>
grep -oE "Executed [0-9]+ tests, with [0-9]+ failures" "$LOG" | tail -1 || true
[ $rc -eq 0 ] || { grep -E "error:|XCTAssert.*failed|failed -" "$LOG" | head -20; fail "测试未通过 (exit $rc)"; }
# 断言「有正面证据」,而不是「没看到 failure 字样」
grep -qE "Executed [0-9]+ tests, with 0 failures" "$LOG" || fail "没看到成功的测试汇总行"

# ★★ 真图 OCR 那一层**必须真的跑过**。
#   「0 failures」看不出它有没有被跳过 —— 夹具删了、测试类改名了、
#   Package.swift 里 resources 掉了,结果都是「静悄悄地不再测」。
#   2026-09-03 的教训:手抄的截图文字测的是我的想象,不是现实(四个 bug 藏在那)。
grep -q "RealScreenshotFixtureTests.*passed" "$LOG" \
  || fail "真图 OCR 测试没跑到 —— 夹具(Tests/ReviewEngineTests/Fixtures)还在吗?"
n_fix=$(ls Tests/ReviewEngineTests/Fixtures/*.png 2>/dev/null | wc -l | tr -d ' ')
[ "$n_fix" -ge 2 ] || fail "真截图夹具少于 2 张(现在 $n_fix)"
echo "✅ 真图 OCR 夹具 $n_fix 张,全部跑过"

echo "── 重生成工程 ──"
# ★ MARKETING_VERSION / 构建号都是 gen_xcodeproj.py 写进 pbxproj 的。
#   不先重生成就构建 = 用上一次的版本戳打这一次的包,
#   「版本戳告诉你装的是哪一版」这个保证当场作废。
python3 gen_xcodeproj.py > /dev/null || fail "工程生成失败"

echo "── 模拟器构建 ──"
set +e
xcodebuild -project TradeMirror.xcodeproj -scheme TradeMirror \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath .build/xc build > "$LOG" 2>&1
rc=$?
set -e
[ $rc -eq 0 ] || { grep -E "error:" "$LOG" | head -20; fail "构建失败 (exit $rc)"; }
grep -q "BUILD SUCCEEDED" "$LOG" || fail "没看到 BUILD SUCCEEDED"
echo "BUILD SUCCEEDED"

echo "── 本地化守卫 ──"
# ★ 用户 2026-09-02:「整个软件都有英文版本,**之后版本更新也是**」。
#   第二半靠人记是记不住的 —— 新加的字符串没翻,这里直接红。
# ★★ 必须放在**构建之后**:守卫读的是编译器产出的 .stringsdata。
#   放在构建前就是读上一次的结果 —— 新字符串会晚一整轮才被发现,
#   而那一轮我已经提交了。(和「守卫自己撒谎」是同一类错。)
python3 tools/check_i18n.py || fail "本地化守卫未通过(新字符串必须同时翻好)"

echo "✅ 全部通过"
