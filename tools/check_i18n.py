#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""本地化守卫:**新加的字符串没法漏掉翻译**。

★★ 用户 2026-09-02 的要求有两半:「整个软件都有英文版」+「**之后版本更新也是**」。
   第二半才是难的 —— 一次翻完不难,难的是**下一版不再漏**。
   ⇒ 所以要一个会自己失败的机制,而不是靠我记得。

★ key 从哪来:**直接用 gen_strings.py 的那一套**,不再自己写一份。
  (今天已经因为「同一张表两份副本」栽过三次;守卫和抽取器用两套规则,
   结果就是守卫报的和实际能翻的对不上。)

★ 三类中文**不算漏翻**:
  ① 券商截图的匹配关键词 —— 那是认中文券商界面用的
  ② CSV 列值和文件名 —— 那是数据格式,翻了导出就变了
  ③ 注释
  (存档值不在此列:它们**存中文、显示译文**,所以仍然要有英文 ——
   见 gen_strings.py 的 DYNAMIC_KEYS。)
"""
import json, re, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gen_strings as G          # ★ 唯一一份 key 规则

ROOT = G.ROOT
BASELINE = ROOT / "tools" / "i18n_baseline.txt"
CJK = re.compile(r"[一-鿿]")

# 引擎里**没包 L()** 的裸中文 = 还没接进本地化 ⇒ 也算欠账。
# 一个看不见这些的守卫,会在引擎整个没翻的情况下报绿(今天验过这个洞)。
BARE_EXEMPT = {
    "Legs.swift", "Psychology.swift", "StrategyTemplate.swift",   # 存档值
    "ScreenshotParser.swift", "LineAssembler.swift", "NumericSolver.swift",  # 匹配关键词
    "TradingRules.swift",                                          # 进 RuleSnapshot(存档)
    "DisciplineSeed.swift",                                        # 手册条目:存档值
    "Exporter.swift",                                              # CSV 列值 / 文件名
    "L10n.swift",
}


def bare_chinese_in_engine():
    out = []
    for f in sorted((ROOT / "Sources/ReviewEngine").glob("*.swift")):
        if f.name in BARE_EXEMPT:
            continue
        code = G.strip_comments(f.read_text(encoding="utf-8"))
        code = G.ENG.sub("", code)                                  # 挖掉已包好的 L("…")
        code = re.sub(r"presets\s*=\s*\[[^\]]*\]", "", code, flags=re.S)  # 存档值
        for m in re.finditer(r'"((?:[^"\\]|\\.)*)"', code):
            if CJK.search(m.group(1)):
                out.append(f"{f.name}|裸中文(要包 L()): {m.group(1)[:46]}")
    return out


# ★★ 2026-09-02 用户报「里面好多中文还是」时挖出的一整类:
#    **返回 String 的属性/函数里含中文** —— 它们最终进 `Text(String)`,
#    而 `Text(String)` **永远不本地化**。编译器抽不到,扫描器也看不见,
#    于是守卫报 100% 而屏幕上是中文。
#    ⇒ 显式扫出来。合法写法只有两种:返回 `LocalizedStringKey`,或用 `Loc.t()`。
RET_STRING = re.compile(r"(?:var|func)\s+(\w+)[^\n]*->\s*String\b"
                        r"|(?:var|func)\s+(\w+)\s*:\s*String\s*\{")
# 这几个返回的**就该是**原文:语言名按惯例用各自的语言写;示例/存档值不翻
RET_EXEMPT = {"label", "id", "localizedUnit",         # Localization.swift
              "prefillPeak", "prefillClose",           # DebugHooks:示例数据
              "shortLabel"}                            # 已经走 counterfactualShortLabel


def _decl_body(lines: list[str], start: int) -> str:
    """从声明行开始,按花括号配对取出**这一个声明的函数体**。"""
    depth, out, seen = 0, [], False
    for ln in lines[start:start + 200]:
        code = ln.split("//")[0]
        out.append(ln if not ln.strip().startswith(("//", "///")) else "")
        for ch in code:
            if ch == "{":
                depth += 1; seen = True
            elif ch == "}":
                depth -= 1
        if seen and depth <= 0:
            break
    return "\n".join(out)


def string_returning_with_chinese():
    out = []
    for f in sorted((ROOT / "App").glob("*.swift")):
        lines = f.read_text(encoding="utf-8").split("\n")
        for i, ln in enumerate(lines):
            m = RET_STRING.search(ln)
            if not m:
                continue
            name = m.group(1) or m.group(2)
            if name in RET_EXEMPT:
                continue
            # ★★ 原来是「往下数 25 行」—— 那是**猜**函数体有多长。
            #   2026-09-03 实测:它把声明后面**别的代码**里的中文算到了这个函数头上
            #   (`stamp` 报「还没有可导出的交易」,而那句在 20 行开外的另一段里)。
            #   <b>误报和漏报一样坏</b>:守卫开始说谎,人就开始忽略它。
            #   ⇒ 用花括号配对取**真正的函数体**。
            body = _decl_body(lines, i)
            # 已经用 Loc.t( 的算合规
            body_wo = re.sub(r"Loc\.t\(\s*\"(?:[^\"\\\\]|\\\\.)*\"", "", body)
            for lit in re.findall(r'\"((?:[^\"\\\\]|\\\\.)*)\"', body_wo):
                if CJK.search(lit):
                    out.append(f"{f.name}|返回 String 却含中文(Text(String) 不本地化): "
                               f"{name} -> {lit[:34]}")
                    break
    return out


# ★★ 第二类(2026-09-02 用户**第二次**报「还有中文」时挖出的):
#    `Text(someString)` —— 参数是运行时 String 就**永不本地化**。
#    上一轮我只查了「返回 String 的属性」,漏掉「参数传进来的 String」
#    ——<b>同一个病,换了个入口</b>,于是守卫报 100% 而屏幕上还是中文。
#
#    ⇒ 规则:`Text/TextField/Label` 的第一个参数只要不是字面量,
#      就必须在**代码里写明意图**,四选一:
#        `verbatim:`(这是数据,本来就不该翻)
#        `LocalizedStringKey(…)`(存档中文,显示时翻)
#        `Loc.t(…)`(运行时拼)
#        `format:`/`style:`(数值格式化)
#      或者那个变量本身声明成 `LocalizedStringKey`。
#    <b>不设名字白名单</b> —— 白名单是我上一轮漏掉一半站点的原因:
#    我照着名字勾了「看起来像数据」的,没一个个去看。
CALL = re.compile(r"\b(Text|TextField|Label)\(")
OK_PREFIX = ("verbatim:", "LocalizedStringKey", "Loc.t", "md:")
STR_LIT = re.compile(r'"(?:[^"\\]|\\.)*"')


def _balanced(code: str, lparen: int) -> str:
    depth, out = 0, []
    for i in range(lparen, len(code)):
        ch = code[i]
        if ch == "(":
            depth += 1
            if depth == 1:
                continue
        elif ch == ")":
            depth -= 1
            if depth == 0:
                break
        out.append(ch)
    return "".join(out)


def _blank_comments(src: str) -> str:
    """挖掉注释但**保留行号** —— 报错报错行,不然还得自己去数。"""
    out, i, n = [], 0, len(src)
    while i < n:
        two = src[i:i + 2]
        if two == "//":
            j = src.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i)); i = j
        elif two == "/*":
            j = src.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append("".join(c if c == "\n" else " " for c in src[i:j])); i = j
        elif src[i] == '"':
            m = STR_LIT.match(src, i)
            if m:
                out.append(m.group(0)); i = m.end()
            else:
                out.append(src[i]); i += 1
        else:
            out.append(src[i]); i += 1
    return "".join(out)


def _lsk_members() -> set[str]:
    """整个 App 里所有返回 `LocalizedStringKey` 的成员名(跨文件)。"""
    names = set()
    for f in (ROOT / "App").glob("*.swift"):
        code = f.read_text(encoding="utf-8")
        names |= set(re.findall(r"(?:var|func)\s+(\w+)[^\n]*?:\s*LocalizedStringKey", code))
        names |= set(re.findall(r"(?:var|func)\s+(\w+)[^\n]*->\s*LocalizedStringKey", code))
    return names


LSK_MEMBERS: set[str] = set()


def nonliteral_text_calls():
    global LSK_MEMBERS
    LSK_MEMBERS = _lsk_members()
    out = []
    for f in sorted((ROOT / "App").glob("*.swift")):
        raw = f.read_text(encoding="utf-8")
        code = _blank_comments(raw)
        lsk = set(re.findall(r"(?:var|func|let)\s+(\w+)[^\n]*?:\s*LocalizedStringKey", code))
        lsk |= set(re.findall(r"(?:var|func)\s+(\w+)[^\n]*->\s*LocalizedStringKey", code))
        lsk |= set(re.findall(r"\b(\w+)\s*:\s*LocalizedStringKey", code))   # 函数参数
        for m in CALL.finditer(code):
            args = _balanced(code, m.end() - 1)
            first = args.split(",")[0].strip()
            # 三元只看**分支**:条件里有属性访问不影响能不能翻
            branch = first.split(" ? ", 1)[-1].strip()
            if branch.startswith('"') or first.startswith(OK_PREFIX):
                continue
            if re.search(r"\b(format|style|value):", args):
                continue
            if re.match(r"^\$?\w+$", first) and first.lstrip("$") in lsk:
                continue
            if first.split(".")[-1].split("(")[0] in LSK_MEMBERS:
                continue                        # 跨文件的 `-> LocalizedStringKey` 成员
            line = code[: m.start()].count("\n") + 1
            if _ok_marked(raw.splitlines(), line):
                continue
            out.append(f"{f.name}:{line}|Text(运行时 String) 不会本地化: {m.group(1)}({first[:44]})")
    return out


# ★★ 第三类(2026-09-02 装完英文版**看屏幕**才发现的):
#    源码里的一句中文,只有走过下面几条路之一,运行时才查得到译文:
#      · 直接写在 `Text("…")` 这类**接 LocalizedStringKey 的 API** 里 ⇒ 编译器抽进 .stringsdata
#      · `Loc.t("…")` / `L("…")` / `Text(md: "…")` ⇒ 我自己扫得到
#    <b>其余全部查不到</b> —— 赋值给变量、当函数参数传下去(`group("按开单原因", …)`)、
#    return 出去,都属于「翻了也没人查」。而这正是「守卫报 100%、屏幕上是中文」的成因。
#    ⇒ 判据直接反过来:**凡是编译器没抽到、我也没扫到的中文,一律报**。
CN_LIT = re.compile(r'"((?:[^"\\\n]|\\.)*[一-鿿](?:[^"\\\n]|\\.)*)"')


def _mask_interpolations(code: str) -> str:
    """把 `\\(…)` 整段换成占位符 —— 里面还可能有引号(`?? ""`),
    不先挖掉的话字符串字面量会被从中间截断,报出一堆假问题。"""
    out, i = [], 0
    while i < len(code):
        if code.startswith("\\(", i):
            depth, j = 0, i + 1
            while j < len(code):
                if code[j] == "(":
                    depth += 1
                elif code[j] == ")":
                    depth -= 1
                    if depth == 0:
                        j += 1
                        break
                j += 1
            out.append("\\(@)"); i = j
        else:
            out.append(code[i]); i += 1
    return "".join(out)
WRAPPED = re.compile(r"(?:\bLoc\.t\(|\bL\(|\bmd:)\s*$")


def _key_seen(lit: str, known: set[str]) -> bool:
    """字面量 → 运行时 key。插值会被编译器换成 %lld/%@,所以用通配比对。"""
    k = G.unescape(lit)
    if k in known:
        return True
    if "\\(" not in lit:
        return False
    # 手写切分:`\(…)` 里面还可能有括号,正则一层套一层容易写错(刚写错过一次)。
    parts, buf, i = [], [], 0
    while i < len(k):
        if k.startswith("\\(", i):
            parts.append(re.escape("".join(buf))); buf = []
            depth, i = 0, i + 1
            while i < len(k):
                if k[i] == "(":
                    depth += 1
                elif k[i] == ")":
                    depth -= 1
                    if depth == 0:
                        i += 1
                        break
                i += 1
            parts.append(".{1,16}")
        else:
            buf.append(k[i]); i += 1
    parts.append(re.escape("".join(buf)))
    rx = re.compile("^" + "".join(parts) + "$")
    return any(rx.match(x) for x in known)


# 这些 API 的**第一个参数**接 LocalizedStringKey
LOCALIZING = {"Text", "Label", "Button", "Section", "Toggle", "Picker", "Stepper",
              "TextField", "LabeledContent", "navigationTitle", "alert",
              "confirmationDialog", "Link", "Menu", "DisclosureGroup"}


def _first_arg_of_localizing_api(code: str, at: int) -> bool:
    """这条字面量是不是某个本地化 API 的第一个参数?"""
    depth, i = 0, at - 1
    while i >= 0:
        c = code[i]
        if c == ")":
            depth += 1
        elif c == "(":
            if depth == 0:
                m = re.search(r"([A-Za-z_]\w*)\s*$", code[max(0, i - 40):i])
                return bool(m) and m.group(1) in LOCALIZING
            depth -= 1
        elif c == "," and depth == 0:
            return False                        # 前面还有别的参数 ⇒ 不是第一个
        i -= 1
    return False


def chinese_literals_assigned():
    known = G.from_stringsdata() | G.scanned() | G.archived_value_keys()
    out = []
    for f in sorted((ROOT / "App").glob("*.swift")):
        raw = f.read_text(encoding="utf-8")
        code = _mask_interpolations(_blank_comments(raw))
        spans = _lsk_spans(code)
        lines = raw.splitlines()
        for m in CN_LIT.finditer(code):
            if WRAPPED.search(code[max(0, m.start() - 12):m.start()]):
                continue                        # Loc.t("…") / L("…") / md: "…"
            if any(a <= m.start() <= b for a, b in spans):
                continue                        # 在 `-> LocalizedStringKey` 体内
            line = code[: m.start()].count("\n") + 1
            if _ok_marked(lines, line):
                continue
            if "\\(" in m.group(1) and not _first_arg_of_localizing_api(code, m.start()):
                # 带插值的中文只能靠编译器抽,而编译器只认**接 LocalizedStringKey 的位置**。
                # `LabeledContent("交易", value: "\\(n) 笔")` 里的 value: 就不是 —— 屏幕上
                # 那个「5 笔」正是这么漏出来的(2026-09-02 装完英文版看屏幕才发现)。
                out.append(f"{f.name}:{line}|插值中文没在可本地化的位置: {m.group(1)[:40]}")
                continue
            if _key_seen(m.group(1), known):
                continue                        # 编译器抽到了 ⇒ 运行时查得到
            out.append(f"{f.name}:{line}|运行时查不到这条中文: {m.group(1)[:40]}")
    return out


def _lsk_spans(code: str) -> list[tuple[int, int]]:
    """返回 `-> LocalizedStringKey` 声明体的字符区间 —— 里面的中文是**合法的 key**。"""
    spans = []
    for m in re.finditer(r":\s*LocalizedStringKey\s*\{|->\s*LocalizedStringKey\s*\{", code):
        i, depth = m.end() - 1, 0
        while i < len(code):
            if code[i] == "{":
                depth += 1
            elif code[i] == "}":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        spans.append((m.start(), i))
    return spans


# 唯一的逃生口:**写在代码里、能 grep 出来、带理由**。
# 不做名字白名单 —— 白名单让我上一轮漏掉了一半站点(照名字勾,没一个个看)。
OK_MARK = re.compile(r"//\s*i18n-ok")


def _ok_marked(lines: list[str], line: int) -> bool:
    for ln in (line - 1, line - 2):
        if 0 <= ln < len(lines) and OK_MARK.search(lines[ln]):
            return True
    return False




# ★ 译文里出现**字面** `\n`(两个字符)= 屏幕上就原样显示一个反斜杠 n。
#   我在 xcstrings 里手写译文时escape 多了一层,8 条备份说明全是这样 ——
#   守卫报「已翻」,用户看到的却是「…isn't a backup.\\n\\nRestoring…」。
def literal_backslash_n(cat) -> list[str]:
    out = []
    for k, v in cat.get("strings", {}).items():
        en = v.get("localizations", {}).get("en", {}).get("stringUnit", {}).get("value", "")
        if "\\n" in en:
            out.append(f"Localizable.xcstrings|译文里是字面 \\n,屏幕会原样显示: {k[:36]}")
    return out


def main():
    live = G.from_stringsdata() | G.scanned() | G.archived_value_keys() | set(G.DYNAMIC_KEYS)
    cat = json.loads((ROOT / "App" / "Localizable.xcstrings").read_text(encoding="utf-8"))
    have = {k for k, v in cat.get("strings", {}).items()
            if v.get("localizations", {}).get("en", {}).get("stringUnit", {}).get("value")}

    problems = (sorted([f"未翻|{k}" for k in live - have])
                + sorted(set(bare_chinese_in_engine()))
                + sorted(set(string_returning_with_chinese()))
                + sorted(set(nonliteral_text_calls()))
                + sorted(set(chinese_literals_assigned()))
                + sorted(set(literal_backslash_n(cat))))

    base = set()
    if BASELINE.exists():
        base = {l.rstrip("\n") for l in BASELINE.read_text(encoding="utf-8").splitlines()
                if l.strip() and not l.startswith("#")}

    if "--update-baseline" in sys.argv:
        BASELINE.write_text(
            "# 本地化欠账明账 —— 只许缩小,不许扩大。\n"
            "# 生成:tools/check_i18n.py --update-baseline\n"
            + "\n".join(problems) + ("\n" if problems else ""), encoding="utf-8")
        print(f"基线已写入 {len(problems)} 条")
        return 0

    total = (len(live) + len(bare_chinese_in_engine())
             + len(string_returning_with_chinese())
             + len(nonliteral_text_calls())
             + len(chinese_literals_assigned()))
    done = total - len(problems)
    print(f"本地化守卫:{done}/{total} 处已完成 "
          f"({done * 100 // max(total, 1)}%)" + (f"· 欠账 {len(problems)} 处" if problems else ""))

    new = [p for p in problems if p not in base]
    if [b for b in base if b not in problems]:
        print(f"  ✅ 比基线少了 {len([b for b in base if b not in problems])} 处 —— 跑 --update-baseline 收紧")
    if new:
        print(f"❌ {len(new)} 处**不在基线里**的新问题(新加的字符串必须同时翻好):")
        for p in new[:12]:
            print(f"     {p[:88]}")
        return 1
    print("✅ 没有新的漏翻")
    return 0


if __name__ == "__main__":
    sys.exit(main())
