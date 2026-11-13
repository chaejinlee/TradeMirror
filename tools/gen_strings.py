#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 / 更新 App/Localizable.xcstrings。

★★ key 必须和**运行时真正查表用的那一串**逐字一致,否则「翻了但查不到」——
   而那是最坏的一种错:**它看起来像完成了**。今天已经栽过两次。
   所以 key 有三个来源,一个都不能少:

   ① `Text("字面量")` 这一路 → **读编译器自己抽的 `.stringsdata`**,不靠我猜。
      插值会被编译器转成 `%lld` / `%@`,只有它知道确切形式。
   ② `Text(md:)` 这一路 → 编译器抽不到(它是运行时按 String 查的),自己扫源码。
   ③ 引擎的 `L("…")` → 同上,自己扫。

★ 源码里的 `\\n` 是**转义序列**,运行时拿到的是**真换行**。
  ②③ 扫出来的必须做转义还原,否则 key 差一个字符就查不到。

★ 已有译文永远保留;死 key(源码里已经没有的)会**列出来**但不自动删。
"""
import json, re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "App" / "Localizable.xcstrings"
BUILD = ROOT / (".build/xc/Build/Intermediates.noindex/TradeMirror.build/"
                "Debug-iphonesimulator/TradeMirror.build/Objects-normal/arm64")
CJK = re.compile(r"[一-鿿]")
STR = r'"((?:[^"\\]|\\.)*)"'
# ★ Label(md:) 也走 Text(md:) —— 少认一个就有一片句子永远查不到
MD = re.compile(r"\b(?:Text|Label)\(\s*md:\s*" + STR)
ENG = re.compile(r'\bL\(\s*' + STR)
# ★ 界面里 String(format: Loc.t("…")) 这一路,编译器同样抽不到
LOCT = re.compile(r'\bLoc\.t\(\s*' + STR)


def unescape(s: str) -> str:
    """源码字面量 → 运行时字符串。只处理实际用到的这几个。"""
    return (s.replace("\\n", "\n").replace("\\t", "\t")
             .replace('\\"', '"').replace("\\\\", "\\"))


def strip_comments(src: str) -> str:
    return "\n".join(l for l in src.splitlines()
                     if not l.strip().startswith(("//", "///", "*")))


def from_stringsdata() -> set[str]:
    keys = set()
    if not BUILD.exists():
        print("⚠️ 没有 .stringsdata —— 先跑一次构建,否则界面 key 会漏。")
        return keys
    for f in BUILD.glob("*.stringsdata"):
        try:
            d = json.loads(f.read_text(encoding="utf-8"))
        except Exception:
            continue
        for entries in d.get("tables", {}).values():
            for e in entries:
                k = e.get("key", "")
                if CJK.search(k):
                    keys.add(k)
    return keys


# ★★ 动态 key:`LocalizedStringKey(someString)` —— 编译器抽不到、正则也扫不到,
#    但它们**运行时确实要查表**。这些字符串同时是**存档值**(所以源码里不能改),
#    显示时才翻 ⇒ 必须在这里显式登记,否则守卫会以为它们不存在。
# ★ 这些文件里的中文是**存档值**(存进 JSON,源码里不能改),
#   显示时靠 `LocalizedStringKey(存的那串)` 查表 ⇒ 它们全都是 key。
#   自动扫,不手抄 —— 手抄清单漏一条就是一句永远翻不出来的话。
ARCHIVED_VALUE_FILES = [
    "Psychology.swift",        # 心理状态词表
    "Legs.swift",              # 开单/出场原因预设、单位
    "StrategyTemplate.swift",  # 各腿的提示语
    "TradingRules.swift",      # RuleVerdict 的格式 key(存档冻结的是数字)
    "DisciplineSeed.swift",    # 纪律手册的种子条目(存中文、显示译文)
]


def archived_value_keys() -> set[str]:
    keys = set()
    for name in ARCHIVED_VALUE_FILES:
        f = ROOT / "Sources/ReviewEngine" / name
        if not f.exists():
            continue
        code = strip_comments(f.read_text(encoding="utf-8"))
        for m in re.finditer(STR, code):
            k = unescape(m.group(1))
            if CJK.search(k):
                keys.add(k)
    return keys


DYNAMIC_KEYS = [
    # StrategyKind.rawValue —— 存进 Trade.strategy
    "单腿", "垂直价差", "日历价差", "对角价差", "跨式", "宽跨式", "铁鹰", "铁蝶",
    "蝶式", "备兑开仓", "保护性看跌", "领口", "比例价差", "自定义组合",
    # EntryReason / ExitReason presets —— 存进 Trade.entryReason / exitReason
    "结构位", "趋势跟随", "量价信号", "均线反应", "缺口回补", "突破回踩", "消息面", "其他",
    "触及目标", "触及止损", "提前手动平", "破位离场", "时间到了", "收盘平掉",
    # 数量单位
    "股", "张", "手",
]


# ★ `missing.append("…")` 里的字段名会**直接显示给用户**(「截图里没认出来,
#   要你自己填:标的、数量」)。而 ScreenshotParser 整个文件在裸中文守卫的豁免名单里
#   (它满是券商界面的匹配关键词,那些一个字都不能翻)—— 于是这几条从缝里漏了过去:
#   英文版会显示 “fill these in yourself: 标的、数量”。
#   ⇒ 只把 `missing.append` 的参数登记成 key,精确到这一个调用点。
MISSING = re.compile(r'missing\.append\(\s*' + STR)


def missing_field_keys() -> set[str]:
    keys = set()
    for f in (ROOT / "Sources/ReviewEngine").glob("*.swift"):
        code = strip_comments(f.read_text(encoding="utf-8"))
        for m in MISSING.finditer(code):
            k = unescape(m.group(1))
            if CJK.search(k):
                keys.add(k)
    return keys


def scanned() -> set[str]:
    keys = set()
    for folder, pats in (("App", [MD, LOCT]), ("Sources/ReviewEngine", [ENG])):
        for f in (ROOT / folder).glob("*.swift"):
            code = strip_comments(f.read_text(encoding="utf-8"))
            for pat in pats:
                for m in pat.finditer(code):
                    k = unescape(m.group(1))
                    if CJK.search(k):
                        keys.add(k)
    return keys


def main() -> int:
    live = (from_stringsdata() | scanned() | archived_value_keys()
            | missing_field_keys() | set(DYNAMIC_KEYS))
    doc = {"sourceLanguage": "zh-Hans", "version": "1.0", "strings": {}}
    if OUT.exists():
        doc = json.loads(OUT.read_text(encoding="utf-8"))
        doc.setdefault("strings", {})

    added = 0
    for k in sorted(live):
        if k not in doc["strings"]:
            doc["strings"][k] = {"extractionState": "manual", "localizations": {}}
            added += 1

    dead = sorted(k for k in doc["strings"] if k not in live)
    OUT.write_text(json.dumps(doc, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    done = sum(1 for v in doc["strings"].values()
               if v.get("localizations", {}).get("en", {}).get("stringUnit", {}).get("value")
               and _k(doc, v) )
    live_done = sum(1 for k in live
                    if doc["strings"][k].get("localizations", {})
                       .get("en", {}).get("stringUnit", {}).get("value"))
    print(f"活 key {len(live)} 条(新增 {added})· 已翻 {live_done} 条 "
          f"({live_done * 100 // max(len(live), 1)}%)")
    if dead:
        print(f"⚠️ {len(dead)} 条**死 key**(源码里已经没有,翻了也没人查):")
        for k in dead[:6]:
            print(f"     {k[:52]!r}")
        print("   → 确认无误后用 --prune 删掉")
    if "--prune" in sys.argv and dead:
        for k in dead:
            doc["strings"].pop(k)
        OUT.write_text(json.dumps(doc, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(f"   已删掉 {len(dead)} 条死 key")
    return 0


def _k(doc, v):
    return True


if __name__ == "__main__":
    sys.exit(main())
