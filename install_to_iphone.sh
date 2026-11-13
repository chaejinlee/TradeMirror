#!/bin/bash
# 把 TradeMirror 装到你自己的 iPhone 上。
# 逐条检查前置条件,缺什么就明确告诉你缺什么、怎么补。
# ★ 检查一律用 env -u DEVELOPER_DIR —— 否则会被脚本自己设的环境变量骗到(踩过)。

set -uo pipefail
XC=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")" || exit 1
OK=1
say() { printf "%s\n" "$1"; }
fail() { printf "❌ %s\n" "$1"; OK=0; }
pass() { printf "✅ %s\n" "$1"; }

say "──────── 前置检查 ────────"

# ① xcode-select
if [ "$(env -u DEVELOPER_DIR xcode-select -p)" = "$XC" ]; then
  pass "xcode-select 指向 Xcode"
else
  fail "xcode-select 还指向 CommandLineTools"
  say "   在终端跑(要输你的开机密码):"
  say "     sudo xcode-select -s $XC"
fi

# ② 签名身份 = Apple ID 是否登录进 Xcode
NOCERT=0
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Development"; then
  pass "已有签名身份(证书在 —— 注意:这**不代表**账号还登着,见下一条)"
  security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | sed 's/^/     /'
else
  # ★ 不是阻塞项:开发证书本来就在第一次真机构建时由 -allowProvisioningUpdates 自动创建。
  #   之前把它当成 ❌ 是我写错了。
  say "ℹ️  还没有开发证书 —— 正常,下面第一次构建时会自动创建(可能弹窗要你的 Apple ID 密码)"
  say "   前提是 Xcode 里已经登录过 Apple 账号(Xcode → Settings → Accounts)"
  NOCERT=1
fi

# ②b ★★ Xcode 里到底有没有登录 Apple 账号 —— 和「有没有证书」是两回事。
#
#   2026-09-06 踩的:证书在、缓存的描述文件也在,于是这个脚本每次都报绿,
#   装也装得上 —— 但那是在**吃 8/31 签的那张老本**。
#   真要签新的时候才发现 `error: No Accounts`。
#   <b>能装 ≠ 能续签。</b>缓存到期那天才暴露,就正好是最不该暴露的那天。
#   ★ 探测器用 `DVTDeveloperAccountManagerAppleIDLists`(Xcode 26 真正记账号的地方)。
#     我第一版猜的是 `IDEProvisioningTeams.plist` —— 那个文件在这台机器上压根不存在,
#     于是刚续签成功的当下它照样报警。<b>喊狼来了的守卫,和不出声的守卫一样坏</b>:
#     前者让你忽略它,后者让你看不见 —— 都通向同一个结局。
#   ★★ 2026-09-30:这条检查**又撒谎了**。它原来只问「这个键在不在」——
#     而账号退出之后,键还在,里面是个空数组 `( )`;团队记录(teamID)也还在。
#     于是它报「✅ 已登录 · 团队 XXXXXXXXXX」,下一步 xcodebuild 就是 `No Accounts`。
#     09-06 我验它会红的办法是**把键名改错** —— 那测的是「键不存在」,
#     不是真实会发生的「键在、但是空的」。<b>改坏得不像,就等于没验</b>(09-15 已经写过一次)。
#   ⇒ 数数组里到底有几个账号。0 个就是没登录,不管键在不在。
# ★ 用 `defaults export` 拿 XML plist 再读数组长度 —— 不数文本行。
#   第一版(同一天)按行数的:真实格式里每个账号是一个三行的字典 `{ identifier = ...; }`,
#   于是 1 个账号被数成 3 个。我当时的测试输入是「一行一个邮箱」—— <b>又不是真实格式</b>。
ACCTS=$(defaults export com.apple.dt.Xcode - 2>/dev/null | python3 -c '
import sys, plistlib
try:
    d = plistlib.loads(sys.stdin.buffer.read())
    print(len(d.get("DVTDeveloperAccountManagerAppleIDLists", {}).get("IDE.Identifiers.Prod", [])))
except Exception:
    print(0)' 2>/dev/null || echo 0)
if [ "${ACCTS:-0}" -gt 0 ] 2>/dev/null; then
  TEAM=$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null \
         | grep -o 'teamID = [A-Z0-9]*' | head -1 | awk '{print $3}')
  pass "Xcode 里已登录 Apple 账号($ACCTS 个,能续签)${TEAM:+ · 团队 $TEAM}"
else
  # ★ 2026-10-05:没登录**不一定**装不上 —— 缓存的描述文件还没过期时,xcodebuild 照样签得出来
  #   (那天这条报 ❌ 拦住了,手动跑 xcodebuild 却当场装上了 5.9)。
  #   ⇒ 缓存还有效:黄牌 —— 这次照装,但把「过期前必须登录」说清楚;缓存没了 / 过期了:红牌。
  LEFT=$(python3 - <<'PYLEFT'
import glob, os, plistlib, subprocess, datetime
best = None
for f in glob.glob(os.path.expanduser("~/Library/Developer/Xcode/UserData/Provisioning Profiles/*.mobileprovision")):
    try:
        d = plistlib.loads(subprocess.run(["security", "cms", "-D", "-i", f], capture_output=True).stdout)
        if "trademirror" not in d["Entitlements"].get("application-identifier", "").lower():
            continue
        exp = d["ExpirationDate"].replace(tzinfo=datetime.timezone.utc)
        days = (exp - datetime.datetime.now(datetime.timezone.utc)).total_seconds() / 86400
        best = days if best is None else max(best, days)
    except Exception:
        pass
print("" if best is None else f"{best:.1f}")
PYLEFT
)
  if [ -n "$LEFT" ] && awk "BEGIN { exit !($LEFT > 0) }"; then
    say "⚠️  Xcode 里**没有登录 Apple 账号** —— 这次用缓存的签名照样装(还剩 $LEFT 天),但**续不了签**"
    say "   过期之前必须在 Xcode 里重新登录,不然到期那天 App 就打不开了。"
    say "   ★ Xcode → Settings → Accounts → 左下角 + → Apple ID 登录"
  else
    fail "Xcode 里**没有登录 Apple 账号** —— 续不了签,缓存里也没有还能用的签名"
    say "   (账号记录还在、团队记录也在,但里面一个账号都没有 —— 系统升级或 Apple ID 会话过期都会这样)"
    say "   ★ Xcode → Settings → Accounts → 左下角 + → Apple ID 登录"
  fi
fi

# ②c ★ 描述文件还剩几天 —— 过期前就该主动刷,别等打不开了才想起来
PP="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
if [ -d "$PP" ]; then
  python3 - "$PP" <<'PYPP'
import sys, glob, os, plistlib, subprocess, datetime
tz = datetime.timezone(datetime.timedelta(hours=-4))
now = datetime.datetime.now(tz)
found = False
for f in glob.glob(os.path.join(sys.argv[1], "*.mobileprovision")):
    try:
        d = plistlib.loads(subprocess.run(["security","cms","-D","-i",f],
                                          capture_output=True).stdout)
        if "trademirror" not in d["Entitlements"].get("application-identifier","").lower():
            continue
        found = True
        exp = d["ExpirationDate"].replace(tzinfo=datetime.timezone.utc).astimezone(tz)
        days = (exp - now).total_seconds() / 86400
        # ★★ 三种情况的处置**完全不同**,别混成一句话(2026-09-15 混过一次):
        #   已过期 → Xcode 不会复用过期的,本脚本跑一遍就自动换新 ⇒ 什么都不用做
        #   快到期 → 它**会**复用,跑一遍只重装不续签 ⇒ 必须先删缓存
        #   还很久 → 不用管
        if days < 0:
            print(f"⚠️  签名 {exp:%m-%d %H:%M} 已过期 {-days:.1f} 天 —— App 打不开了")
            print("   ★ 不用做别的:过期的描述文件 Xcode 不会复用,下面这次构建会自动换新的。")
            print("   ★ 千万别删 App —— 删了沙盒里的交易记录一起没。覆盖安装不丢数据。")
        elif days <= 2:
            print(f"⚠️  签名 {exp:%m-%d %H:%M} 过期 —— 只剩 {days:.1f} 天")
            print("   ★ 注意:还没过期的描述文件会被**复用**,直接跑只会重装 App、不会续签。")
            print("     要真的续满 7 天,先删掉缓存那张再跑本脚本:")
            print(f"       rm '{os.path.join(sys.argv[1], os.path.basename(f))}'")
        else:
            print(f"✅ 签名 {exp:%m-%d %H:%M} 过期 —— 还剩 {days:.1f} 天")
    except Exception:
        pass
# ★ 2026-09-30:缓存里一张都没有时,这条检查原来**什么都不说** ——
#   重新登录 Xcode 后旧描述文件会被清掉,正好就是这种情况。沉默看起来像「没问题」。
if not found:
    print("ℹ️  缓存里没有这个 App 的描述文件 —— 正常:下面这次构建会新建一张,有效 7 天")
PYPP
fi

# ③ 连接的 iPhone
# ★★ 2026-09-30:原来是 `devicectl list devices | grep -i iphone`。
#   系统升级后 devicectl 把**模拟器**也列出来了 —— 手机没插线时,grep 抓到一台叫
#   「iPhone 17」的模拟器,报「✅ 检测到设备」,再往模拟器上装,
#   得到一句莫名其妙的 `Install Application is not supported by this device`。
#   ⇒ 用 tools/real_device.py 读 JSON,只认 wired / localNetwork 的真 iPhone。
IFS=$'\t' read -r DSTATE UDID DNAME DTRANS DTUN DDEV <<< "$(env DEVELOPER_DIR=$XC python3 tools/real_device.py)"
case "$DSTATE" in
  ok)
    pass "检测到手机:$DNAME($DTRANS)"
    ;;
  locked)
    fail "手机($DNAME)连着,但开发服务起不来 —— 通常是**锁屏了**,或刚插上线还没握手"
    say "   解锁手机、停在主屏幕上,再跑一次。"
    [ "$DTRANS" = "localNetwork" ] && say "   ★ 现在是**无线**连接 —— 插上数据线更稳。"
    ;;
  nodevmode)
    fail "手机($DNAME)连着,但**开发者模式没开**(状态:$DDEV)"
    say "   设置 → 隐私与安全性 → 开发者模式 → 打开 → 重启手机,重启后再跑一次。"
    say "   (iOS 大版本更新后这个开关有时会被关掉)"
    ;;
  *)
    fail "没有检测到你的 iPhone(模拟器不算)"
    say "   ① 用数据线连上 Mac"
    say "   ② 手机解锁 → 弹窗点「信任此电脑」→ 输手机密码"
    say "   ③ ★ 开发者模式:**这一项在连过 Xcode 之前根本不会出现在设置里**"
    say "      所以顺序是 —— 先连线、先跑一次本脚本(会失败,正常),"
    say "      **那次失败的握手正是让开关冒出来的动作**;然后再去手机上:"
    say "        设置 → 隐私与安全性 → 开发者模式 → 打开 → 重启手机"
    say "      重启后回来再跑一次本脚本,这次会成功。"
    ;;
esac

if [ "$OK" != "1" ]; then
  say ""
  say "──────── 上面 ❌ 的补完再跑一次本脚本 ────────"
  exit 1
fi

say ""
say "──────── 构建前守卫 ────────"
if ! python3 tools/check_markdown.py; then
  say "❌ markdown 守卫未通过,先修上面那几处再装。"; exit 1
fi

say ""
say "──────── 开始构建并安装 ────────"
# ★ 先重生成工程:构建号是生成时刻写进去的,不重生成的话版本戳会停在上一次,
#   而「版本戳告诉你装的是哪一版」这个保证就不成立了。
python3 gen_xcodeproj.py >/dev/null || { say "❌ 工程生成失败"; exit 1; }
export DEVELOPER_DIR=$XC
# ★ 用正则抓 UUID,不要按字段位置抓 —— devicectl 的输出列数会随「connected (no DDI)」这类状态变化。
# ★ UDID 用前置检查里挑出来的那台真机 —— 原来这里又 grep 了一遍 iphone,同样会抓到模拟器
if [ -z "${UDID:-}" ]; then say "❌ 取不到设备 UDID,把上面 devicectl 的输出发给我"; exit 1; fi
say "目标设备 UDID: $UDID"

# ★ 2026-10-05:装到手机上的包**开优化**(-O)。原来是 Debug 默认的 -Onone ——
#   凯利页的重抽 + 回撤表在 -Onone 下要 2.4 秒(每一步循环 70–85 ns),开 -O 是 0.04 秒。
#   只改优化级别,不换配置:`#if DEBUG` 照旧生效;代码里没有 assert(-O 会把它拿掉)。
#   verify.sh 的模拟器构建不动 —— 那是给我看的,慢点没关系。
xcodebuild -project TradeMirror.xcodeproj -scheme TradeMirror \
  -destination "id=$UDID" -derivedDataPath .build/dev \
  SWIFT_OPTIMIZATION_LEVEL=-O \
  -allowProvisioningUpdates build 2>&1 | tee .build/last_build.log | tail -30
if ! grep -q "BUILD SUCCEEDED" .build/last_build.log; then
  say ""
  if grep -qi "requires a development team\|no development team\|Signing for" .build/last_build.log; then
    say "❌ 缺「开发团队」。在 Xcode 里点一次就好(只需一次):"
    say "   ① 双击打开 $(pwd)/TradeMirror.xcodeproj"
    say "   ② 左侧最上面那个蓝色 TradeMirror 图标 → TARGETS 下的 TradeMirror"
    say "   ③ 上方标签选「Signing & Capabilities」"
    say "   ④ Team 下拉框 → 选你自己的「Personal Team」"
    say "   ⑤ 关掉 Xcode,回来再跑一次本脚本"
  else
    say "❌ 构建失败。完整日志在 .build/last_build.log,把它发给我。"
  fi
  exit 1
fi

APP=.build/dev/Build/Products/Debug-iphoneos/TradeMirror.app
xcrun devicectl device install app --device "$UDID" "$APP" \
  || { say "❌ 安装失败,把上面的报错发给我"; exit 1; }

say ""
pass "装好了。手机上找「TradeMirror」图标。"
say ""
say "★ 第一次点开会提示「不受信任的开发者」,这是正常的,去手机上信任一下:"
say "   设置 → 通用 → VPN与设备管理 → 点你的 Apple ID → 信任"
say ""
say "★ 免费 Apple ID 的限制:签名 7 天过期,过期后重跑本脚本即可。"
say "   同时最多装 3 个自签 App。付了 \$99 之后是 1 年,而且可以走 TestFlight(不用插线)。"
