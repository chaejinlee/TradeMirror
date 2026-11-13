#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把用户 2026-08 的历史交易(review_bundle)转成复盘镜的备份文件。

★★ 三条不许越的线(都来自规范,也来自 bundle 自己的 caveat):
  ① **规则判定不导入。** bundle 的 `rule_check_at_entry` 自己写着:
     「本批数据在开仓时【未冻结】规则判定,以下为事后按同一公式重算 ——
       存在幸存者偏差,且丢失了「系统警告过但用户仍执行」这条行为记录。」
     ⇒ 事后重算的规则检查<b>比不写更糟</b>,它会假装那时候检查过。一律不写。
  ② **心理标签一律标成事后。** CSV 里的「交易心理/行为偏误」是复盘时填的
     (「提前平仓求安心」显然是在讲出场)。标成事前会污染统计。
  ③ **方向按成交推,不按「方向」列推。** 第 2 笔写着 direction=short,
     但它是**买入** 720P —— 买 put 做空标的。腿本身是多头。
     按「空」记成卖出开仓会让盈亏符号整个翻过来。

用法: python3 tools/import_review_bundle.py <review_bundle 目录> <输出.json>
"""
import csv, json, sys, uuid, datetime as dt
from pathlib import Path

ET_OFFSET = dt.timedelta(hours=4)      # 2026-08 是夏令时,ET = UTC-4


def uid() -> str:
    return str(uuid.uuid4()).upper()


def stable_uid(*parts) -> str:
    """★★ 确定性 id:同样的输入永远给同样的 UUID。

    2026-09-02 的事故:这里原来用 `uuid4()`,每跑一次都换一批 id。
    我为了加「开单原因」重新生成了一次文件,用户一导入 —— **5 笔变 10 笔**。
    ⇒ 从内容派生(UUID5),重新生成同一份数据得到**同一批 id**,
      再导入就是「已经有了,只补空」,而不是又来一遍。
    """
    key = "|".join(str(p) for p in parts)
    return str(uuid.uuid5(uuid.NAMESPACE_URL, "trademirror/" + key)).upper()


def utc(day: str, hhmm: str) -> str:
    """'2026-08-06' + '10:30'(ET) -> ISO8601 UTC"""
    h, m = (int(x) for x in hhmm.split(":"))
    t = dt.datetime.strptime(day, "%Y-%m-%d") + dt.timedelta(hours=h, minutes=m) + ET_OFFSET
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")


def load_csv(bundle: Path):
    """CSV 提供:日期、逐字原话、心理标签。payload 提供:结构化成交。"""
    rows = {}
    with open(bundle / "trades.csv", encoding="utf-8-sig") as f:
        for r in csv.DictReader(f):
            rows[int(r["id"])] = r
    return rows


def build(bundle: Path):
    rows = load_csv(bundle)
    trades = []
    skipped = []
    for pf in sorted((bundle / "payloads").glob("trade_*.json")):
        p = json.loads(pf.read_text(encoding="utf-8"))
        t, raw = p["trade"], p.get("user_raw", {})
        row = rows.get(t["id"], {})
        day = (row.get("记录时间") or "")[:10]
        if not day:
            skipped.append((t["id"], "CSV 里没有日期")); continue

        leg_id = stable_uid("leg", t["id"], day, t.get("strike"), t.get("right"))
        # ── 腿 ───────────────────────────────────────────────
        if t.get("strike") and t.get("right"):
            kind = {"option": {"right": "call" if t["right"].upper().startswith("C") else "put",
                               "strike": float(t["strike"]),
                               # 0DTE:到期 = 当天 16:00 ET
                               "expiry": utc(day, "16:00")}}
        else:
            kind = {"equity": {}}

        # ── 成交 ★ 按 fills 推方向,不看 direction 列 ────────────
        fills_src = t.get("fills")
        if not fills_src:
            # BEX 那种:payload 没给 fills,用 CSV 的入场价 + 股数兜底
            if row.get("入场价") and row.get("股数"):
                fills_src = [{"t": (row.get("记录时间") or " 09:30")[11:16] or "09:30",
                              "side": "buy", "qty": float(row["股数"]),
                              "px": float(row["入场价"])}]
            else:
                skipped.append((t["id"], "没有任何成交记录")); continue

        entry_u = (p.get("market", {}).get("at_entry") or {}).get("px")
        exit_u = (p.get("market", {}).get("at_exit") or {}).get("px")
        fills = []
        for i, f in enumerate(fills_src):
            fl = {"id": stable_uid("fill", t["id"], day, f["t"], f["side"], f["qty"], f["px"]),
                  "legID": leg_id, "price": float(f["px"]),
                  "quantity": float(f["qty"]), "side": f["side"],
                  "time": utc(day, f["t"])}
            # 只在**确实知道**的那两笔上写标的价;中间那几笔留空,
            # 由 moomoo_enrich 从真实分钟 K 补 —— **不猜**。
            if i == 0 and entry_u:
                fl["underlying"] = float(entry_u)
            elif i == len(fills_src) - 1 and exit_u and len(fills_src) > 1:
                fl["underlying"] = float(exit_u)
            fills.append(fl)

        # ── 心理:一律事后 ────────────────────────────────────
        states = [s for s in (row.get("交易心理", "").split(";")
                              + row.get("行为偏误", "").split(";"))
                  if s and s not in ("无",)]
        psych = None
        if states or row.get("信心度"):
            psych = {"beforeOutcome": False,          # ★ 不许标成事前
                     "confidence": int(row.get("信心度") or 3),
                     "recordedAt": utc(day, "16:00"),
                     "states": states}

        cf = p.get("counterfactuals", {})
        peak = (cf.get("exit_vs_peak") or {})
        out = {
            "id": stable_uid("trade", t["id"], day, t["symbol"]), "symbol": t["symbol"], "strategy": "单腿",
            "legs": [{"id": leg_id, "kind": kind}],
            "fills": fills,
        }
        if raw.get("at_entry"):
            out["rawNoteAtEntry"] = raw["at_entry"]
        # 复盘原文放到「出场时的原话」——它确实是出场之后写的
        if row.get("复盘"):
            out["rawNoteAtExit"] = row["复盘"]
        if row.get("出场原因"):
            out["exitReason"] = row["出场原因"]
        # ★ 2026-09-02 新增字段:开单原因 / 事前止损 / 事前止盈。
        #   这三列他的 CSV 里一直有(理由_主 / 止损 / 目标)——
        #   说明他早就在按原因思考,只是 App 之前没地方放。
        if row.get("理由_主"):
            out["entryReason"] = row["理由_主"]
        for col, key in (("止损", "plannedStop"), ("目标", "plannedTarget")):
            try:
                v = float(row.get(col) or "")
            except ValueError:
                continue
            if v > 0:
                out[key] = v
        if psych:
            out["psychology"] = psych
        if peak.get("peak_underlying"):
            out["peakUnderlying"] = float(peak["peak_underlying"])
            if peak.get("peak_time"):
                out["peakTime"] = utc(day, peak["peak_time"])
        eod = (cf.get("hold_to_eod") or {}).get("eod_underlying")
        if eod:
            out["finalUnderlying"] = float(eod)
        trades.append(out)

    # ── 规则:从 profile 取,**但不导入任何事后重算的规则判定** ──
    prof = json.loads((bundle / "payloads" / "trade_001.json").read_text(encoding="utf-8")).get("profile", {})
    rules = {"minConfidence": 4, "maxConsecutiveLosses": 3, "dailyLossLimitPct": 3,
             "coolDownMinutesAfterLoss": 15, "enabled": True,
             # 「0DTE:触及目标平50%,剩余移动止损(-30%或破前1m低)」-> 30,不是默认的 25
             "trailingStopPct": 30}
    if prof.get("equity_usd"):
        rules["equity"] = float(prof["equity_usd"])
    return {"schemaVersion": 12, "trades": trades, "pendingPlans": [],
            "dailyCloses": {"closes": {}}, "rules": rules}, skipped


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    doc, skipped = build(Path(sys.argv[1]).expanduser())
    Path(sys.argv[2]).write_text(json.dumps(doc, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"转换 {len(doc['trades'])} 笔 -> {sys.argv[2]}")
    for t in doc["trades"]:
        k = t["legs"][0]["kind"]
        desc = (f"{k['option']['strike']:.0f}{k['option']['right'][0].upper()}"
                if "option" in k else "股票")
        n = len(t["fills"])
        print(f"  · {t['symbol']:5s} {desc:6s} {n} 笔成交  "
              f"{t['fills'][0]['time'][:10]}  "
              f"{'已平' if abs(sum((1 if f['side']=='buy' else -1)*f['quantity'] for f in t['fills']))<1e-9 else '★未平'}")
    for i, why in skipped:
        print(f"  ✗ 跳过 #{i}: {why}")
    print("\n★ 没有导入的东西(故意的):")
    print("  · 开仓时的规则判定 —— bundle 自己写明是**事后重算**的,导进来等于假装那时检查过")
    print("  · 心理标签一律标成**事后**(那些话是复盘时写的,标成事前会污染统计)")
