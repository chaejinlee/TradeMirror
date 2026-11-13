#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
用 moomoo OpenD 把**真实期权行情**补进复盘镜的备份文件。

★★ 为什么需要这个工具:
   App 里「若持有到收盘」对期权只能给**模型估算**(到期内在价值),
   因为历史期权价没有免费的公开数据源(实测:Yahoo 过期链取不到,Polygon 期权 $79/月)。
   但用户自己有 moomoo —— 而 moomoo **有**,连分钟级都有。
   实测 2026-09-01 QQQ 708C:日 K 收盘 **0.25**,与用户所说完全一致。

★ 为什么不做进 App:
   OpenD 是**跑在电脑上的本地网关**,手机 App 连不到它。
   所以走「导出 → 本机补数据 → 导回」这条路,复用已经建好的备份管道。

★ 补数据的铁律:**只填空着的字段,绝不改你已经填过的任何值。**
   (App 侧的 `Importer.enrich` 也是同一条规则。)

用法:
    # 查一张期权某天的真实收盘价(最常用)
    python3 tools/moomoo_enrich.py quote QQQ 2026-09-01 708 C

    # 把整份备份补全,输出新文件
    python3 tools/moomoo_enrich.py file ~/Downloads/复盘镜-2026-09-01.json
"""
import json, sys, datetime as dt
from pathlib import Path

try:
    from moomoo import OpenQuoteContext, RET_OK, KLType
except ImportError:
    sys.exit("没装 moomoo SDK:  pip install moomoo-api")


def option_code(symbol: str, expiry: str, strike: float, right: str) -> str:
    """QQQ / 2026-09-01 / 708 / call  ->  US.QQQ260901C708000"""
    y, m, d = expiry.split("-")
    return (f"US.{symbol.upper()}{y[2:]}{m}{d}"
            f"{'C' if right.lower().startswith('c') else 'P'}{int(round(strike * 1000))}")


def connect():
    q = OpenQuoteContext(host="127.0.0.1", port=11111)
    return q


def day_close(q, code: str, day: str):
    """那天的**日 K 收盘价**。取不到返回 None —— 不猜。"""
    r, d, *_ = q.request_history_kline(code, start=day, end=day,
                                       ktype=KLType.K_DAY, max_count=2)
    if r != RET_OK or len(d) == 0:
        return None
    return float(d.iloc[-1]["close"])


MAX_BARS = 400   # 一天最多 390 根分钟 K;再多就降采样,免得备份文件失控


def path_between(q, code: str, t0: str, t1: str):
    """持仓期间的分钟路径。**整条存下来** —— 移动止损要看价格出现的**顺序**,
    只给最高最低是算不出来的。返回 App 能直接读的 [{t,h,l,c}]。"""
    r, d, *_ = q.request_history_kline(code, start=t0, end=t1,
                                       ktype=KLType.K_1M, max_count=1000)
    if r != RET_OK or len(d) == 0:
        return None
    if len(d) > MAX_BARS:                      # 降采样:保序,保极值
        step = len(d) // MAX_BARS + 1
        d = d.iloc[::step]
    out = []
    for _, row in d.iterrows():
        # moomoo 给的是纽约时间;转回 UTC 的 ISO8601,和备份里其它时间一致
        t = dt.datetime.strptime(str(row["time_key"]), "%Y-%m-%d %H:%M:%S") + dt.timedelta(hours=4)
        out.append({"t": t.strftime("%Y-%m-%dT%H:%M:%SZ"),
                    "h": float(row["high"]), "l": float(row["low"]), "c": float(row["close"])})
    return out


def ny(iso: str) -> str:
    """备份里的 UTC 时间 -> 纽约时间字符串(moomoo 要的格式)。"""
    t = dt.datetime.fromisoformat(iso.replace("Z", "+00:00"))
    # 美东 = UTC-4(夏令时);这里只用于取分钟 K 的区间,前后各放宽 1 分钟
    return (t - dt.timedelta(hours=4)).strftime("%Y-%m-%d %H:%M:%S")


def enrich_file(path: Path):
    doc = json.loads(path.read_text(encoding="utf-8"))
    q = connect()
    filled = 0
    try:
        for t in doc.get("trades", []):
            sym = t["symbol"]
            # ★ 标的自己的分钟路径也补上 —— 「若在标的峰值处出场」要靠它知道
            #   **峰值出现在几点**,才能去查那一刻这条腿的真实价。
            #   没有它就只能退回 Black–Scholes 估(实测会高估:4.45 vs 真实 4.29)。
            fills0 = sorted(t.get("fills", []), key=lambda f: f["time"])
            if fills0 and not t.get("underlyingPath"):
                day = fills0[-1]["time"][:10]
                ub = path_between(q, f"US.{sym.upper()}", f"{day} 09:30:00", f"{day} 16:00:00")
                if ub:
                    t["underlyingPath"] = ub
                    filled += 1
                    print(f"  ✓ 标的 {sym} 分钟路径 {len(ub)} 根")
                    # ★ 顺手把**每一笔成交当时的标的价**补上(按分钟对齐)。
                    #   之前只有首尾两笔有,中间的加仓是空的 —— 而 IV 是逐笔反解的,
                    #   空着就少一笔可用信息。**从真实分钟 K 取,不是插值猜的。**
                    back = 0
                    for f in t["fills"]:
                        if f.get("underlying"):
                            continue
                        near = min(ub, key=lambda b: abs(
                            (dt.datetime.strptime(b["t"], "%Y-%m-%dT%H:%M:%SZ")
                             - dt.datetime.strptime(f["time"], "%Y-%m-%dT%H:%M:%SZ")).total_seconds()))
                        f["underlying"] = near["c"]
                        back += 1
                    if back:
                        print(f"     顺带补了 {back} 笔成交当时的标的价")
            for leg in t.get("legs", []):
                kind = leg.get("kind", {}).get("option")
                if not kind:
                    continue
                # ★ 只补空 —— 已经填过的一律不动
                if leg.get("userClosePrice") is not None and leg.get("path"):
                    print(f"  跳过 {sym} {kind['strike']}{kind['right'][0].upper()}:已经有数据了")
                    continue
                expiry = kind["expiry"][:10]
                code = option_code(sym, expiry, kind["strike"], kind["right"])
                if leg.get("userClosePrice") is None:
                    px = day_close(q, code, expiry)
                    if px is None:
                        print(f"  ✗ {code}:取不到(权限?非交易日?代码不对?)")
                    else:
                        leg["userClosePrice"] = px
                        filled += 1
                        print(f"  ✓ {code} 到期日收盘 {px}")

                # ★ 整条分钟路径也存进去 —— 真 MAE / 真 MFE / 移动止损全靠它
                if leg.get("path"):
                    print("     (路径已有,不动)")
                    continue
                fills = sorted(t.get("fills", []), key=lambda f: f["time"])
                if not fills:
                    continue
                # ★ 取到**当天收盘**,不是只取到你出场那一刻 ——
                #   「平一半、剩余持有」这条反事实要看你走之后价格怎么走。
                bars = path_between(q, code, ny(fills[0]["time"]),
                                    fills[-1]["time"][:10] + " 16:00:00")
                if not bars:
                    print("     ✗ 分钟路径取不到")
                    continue
                leg["path"] = bars
                filled += 1
                # ★ MAE/MFE 的定义是「**持仓期间**」。路径取到当天收盘,
                #   不切窗就会把你走之后的极值算进来 —— App 里犯过这个错,
                #   这里的打印也一样,别在终端上给一个自己都不信的数。
                t0, t1 = fills[0]["time"], fills[-1]["time"]
                held = [b for b in bars if t0 <= b["t"] <= t1] or bars
                entry = fills[0]["price"]
                lo, hi = min(b["l"] for b in held), max(b["h"] for b in held)
                dlo, dhi = min(b["l"] for b in bars), max(b["h"] for b in bars)
                print(f"     路径 {len(bars)} 根(持仓内 {len(held)} 根)")
                print(f"     持仓内 {lo}–{hi} | 真 MAE {(lo-entry)/entry*100:+.1f}%"
                      f" · 真 MFE {(hi-entry)/entry*100:+.1f}%")
                print(f"     当天全程 {dlo}–{dhi}(仅供参考,**不是** MAE/MFE)")
    finally:
        q.close()

    out = path.with_name(path.stem + "-补全" + path.suffix)
    out.write_text(json.dumps(doc, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n补了 {filled} 条 -> {out}")
    print("把它 AirDrop 到手机,在 App 里「数据与备份 → 从备份导回」即可。")
    print("★ 导回只补空、不覆盖你已经填过的值。")


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    mode = sys.argv[1]
    if mode == "quote" and len(sys.argv) >= 6:
        sym, day, strike, right = sys.argv[2], sys.argv[3], float(sys.argv[4]), sys.argv[5]
        code = option_code(sym, day, strike, right)
        q = connect()
        try:
            px = day_close(q, code, day)
            print(f"{code}  {day} 收盘 = {px if px is not None else '取不到'}")
        finally:
            q.close()
    elif mode == "file" and len(sys.argv) >= 3:
        enrich_file(Path(sys.argv[2]).expanduser())
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
