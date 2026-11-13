#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
守卫:禁止在视图里写「会让 markdown 失效」的字面量。

★ 这个脚本存在的理由:同一个 bug 出现了**四次**。
  `Text("...**粗体**...")` 只有在**纯字符串字面量**时才走 LocalizedStringKey、
  从而解析 markdown。一旦用 `+` 拼接或传 String 变量,`**` 就原样显示在屏幕上。
  前三次我都是「发现 → 批量扫一遍 → 修掉」,**下一轮写新代码时又犯**。
  ⇒ 修实例没用,要修类别:把检查放进 CI/测试前,让它**自己失败**。

规则一:`Text(` 或 `Label(` 的第一个字符串字面量里若含 `**`,
       必须写成 `Text(md:` / `Label(md:`。

★★ 第五次之后我以为堵住了。**第六次它换了个出口** ——
   跑到 branding/make_shots.py 里,被 PIL 原样画进了 **App Store 截图**。
   守卫只盯着 Swift,而星号出现在下一个「把文本渲染出来」的地方。
   ⇒ 规则二:截图/图标生成器里的字符串一律不许出现星号 ——
     PIL 不认 markdown,写了就是画上去。
   ★ 教训:守卫要按「会不会被渲染」划边界,而不是按文件类型划。
"""
import re, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from check_i18n import _balanced, _blank_comments   # ★ 括号配对只写一份

ROOT = Path(__file__).resolve().parent.parent
BAD = re.compile(r'\b(Text|Label)\(\s*"((?:[^"\\]|\\.)*\*\*(?:[^"\\]|\\.)*)"')

# ★★ 第七次(2026-09-03),又换了一个出口:
#    `Text(verbatim: String(format: Loc.t("…**只补不覆盖**…"), …))`
#    —— 星号藏在**两层调用里面**,规则一那条「紧跟在 Text( 后面的字面量」看不见它。
#    实测:恢复对话框上原样显示 `**只补不覆盖**`。
#    ⇒ 规则三按**这个文件自己写下的边界**来:不看写法,看「会不会被渲染」。
#      `Text(...)` / `Label(...)` 的**整个参数**里只要出现带 `**` 的字面量,
#      而这个调用又不是 `md:`,就是漏。
CALL = re.compile(r"\b(Text|Label)\(")
LIT_WITH_STARS = re.compile(r'"(?:[^"\\]|\\.)*\*\*(?:[^"\\]|\\.)*"')


def stars_inside_text_calls(root: Path):
    out = []
    for f in sorted((root / "App").glob("*.swift")):
        if f.name == "MarkdownText.swift":
            continue
        code = _blank_comments(f.read_text(encoding="utf-8"))
        for m in CALL.finditer(code):
            args = _balanced(code, m.end() - 1)
            if args.lstrip().startswith("md:"):
                continue                       # 明确走 markdown ⇒ 合规
            if LIT_WITH_STARS.search(args):
                line = code[: m.start()].count("\n") + 1
                out.append((f.name, line, args.strip()[:90]))
    return out


def main() -> int:
    bad = []
    bad += stars_inside_text_calls(ROOT)
    for f in sorted((ROOT / "App").glob("*.swift")):
        if f.name == "MarkdownText.swift":      # 它的注释里就是在讲这个坑
            continue
        for i, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
            if BAD.search(line):
                bad.append((f.name, i, line.strip()[:90]))
    # 规则二:图片生成器(PIL 直接画字,根本不解析 markdown)
    for rel in ["branding/make_shots.py", "branding/make_icon.py"]:
        f = ROOT / rel
        if not f.exists():
            continue
        for i, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
            if line.lstrip().startswith("#"):        # 注释里可以讲这个坑
                continue
            if "**" in line and '"' in line:
                bad.append((rel, i, line.strip()[:90]))
    if bad:
        print("❌ 这些地方的 markdown 不会生效(星号会原样显示):")
        print("   .swift -> 改成 Text(md:) / Label(md:);生成器 -> 直接删掉星号")
        for n, i, l in sorted(set(bad)):
            print(f"   {n}:{i}  {l}")
        return 1
    print(f"✅ markdown 守卫通过")
    return 0

if __name__ == "__main__":
    sys.exit(main())
