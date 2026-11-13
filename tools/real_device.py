#!/usr/bin/env python3
"""从 `devicectl list devices --json-output` 里挑出**真机**,打印一行给 shell 用。

★★ 2026-09-30 为什么要这个文件:
  原来 install_to_iphone.sh 是 `devicectl list devices | grep -i iphone` 找设备的。
  系统升级(Darwin 27 / Xcode 26)之后,devicectl 开始把**模拟器**也列出来 ——
  于是手机没插线时,grep 抓到一台叫「iPhone 17」的模拟器,报「✅ 检测到设备」,
  再往模拟器上装,得到一句莫名其妙的 `Install Application is not supported`。
  ⇒ 不再 grep 文本,读 JSON,按真实字段判断。

判据:
  · transportType 是 wired / localNetwork —— 模拟器是 sameMachine
  · 硬件属性里 reality 是 physical(有这个字段时)
  · 只要 iPhone(iPad 不是这个 App 的目标)

输出(一行,制表符分隔):
  状态  UDID  名字  连接方式  隧道  开发者模式
  状态:ok / locked / nodevmode / none
"""
import json, subprocess, sys, tempfile, os

def scan(xc: str):
    """列一次设备,挑出真机。返回 (输出行, 状态, 标识);读不到列表时抛异常。"""
    with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as f:
        out = f.name
    try:
        subprocess.run(["xcrun", "devicectl", "list", "devices", "--json-output", out],
                       env={**os.environ, "DEVELOPER_DIR": xc},
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
        data = json.load(open(out))
    finally:
        try: os.unlink(out)
        except OSError: pass

    phones = []
    for d in data.get("result", {}).get("devices", []):
        cp, dp, hp = (d.get("connectionProperties", {}), d.get("deviceProperties", {}),
                      d.get("hardwareProperties", {}))
        transport = cp.get("transportType") or ""
        reality = hp.get("reality")                     # "physical" / "virtual"(有些版本没有)
        is_sim = transport == "sameMachine" or reality == "virtual"
        if is_sim:
            continue
        if (hp.get("deviceType") or dp.get("deviceType") or "").lower() != "iphone" \
                and "iphone" not in (hp.get("marketingName") or "").lower():
            continue
        phones.append((d, cp, dp, hp, transport))

    if not phones:
        return "none\t\t\t\t\t", "none", ""

    # 有线优先
    phones.sort(key=lambda x: 0 if x[4] == "wired" else 1)
    d, cp, dp, hp, transport = phones[0]
    udid = hp.get("udid") or d.get("identifier") or ""
    name = dp.get("name") or hp.get("marketingName") or "iPhone"
    tunnel = cp.get("tunnelState") or ""
    devmode = dp.get("developerModeStatus") or ""
    ddi = dp.get("ddiServicesAvailable")
    if devmode and devmode != "enabled":
        state = "nodevmode"
    elif ddi is False and tunnel != "connected":
        state = "locked"            # 开发者模式开着但服务起不来 —— 多半是锁屏或刚插线
    else:
        state = "ok"
    # udid 在 hardwareProperties 里是真机的 UDID;devicectl 的 --device 两种都认
    ident = d.get("identifier") or udid
    return "\t".join([state, ident, name, transport, tunnel, devmode]), state, ident


def main() -> int:
    xc = os.environ.get("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    try:
        line, state, ident = scan(xc)
        # ★★ 2026-10-04:「locked」大多是**误报**。`list devices` 只是读状态,不会去建隧道 ——
        #   手机明明已经解锁,隧道却一直 disconnected、ddiServicesAvailable 一直 False。
        #   用户说「解锁了」之后还连报三次锁屏;手动跑一句 `devicectl device info details`
        #   (一条真要跟手机说话的命令)隧道立刻连上、DDI 变 True,当场就装好了。
        #   10-03 那两次「开发服务起不来」多半也是这个。
        #   ⇒ 先叫一声再判;叫过之后还是这样,才是真锁屏(或者手机上的「信任」没点)。
        if state == "locked" and ident:
            subprocess.run(["xcrun", "devicectl", "device", "info", "details", "--device", ident],
                           env={**os.environ, "DEVELOPER_DIR": xc},
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
            line, state, ident = scan(xc)
    except Exception as e:
        print(f"none\t\t\t\t\t读不到设备列表:{e}")
        return 0
    print(line)
    return 0

if __name__ == "__main__":
    sys.exit(main())
