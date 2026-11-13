#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""版本号守卫。
★ 起因:v0.7 → v1.4 一共八个版本,App 里显示的一直是 v0.6 ——
  gen_xcodeproj.py 里写死了,而我每次只顾着改代码。
  「做完了但用户验不了」等于没做完。

规则:git 提交标题里出现过的最高 vX.Y,必须 ≤ VERSION 文件里的版本。
     发布了新版本却忘了改 VERSION —— 这个脚本会红。
"""
import re, subprocess, sys, pathlib

root = pathlib.Path(__file__).resolve().parent.parent
cur = root.joinpath("VERSION").read_text().strip()

def tup(v): return tuple(int(x) for x in v.split("."))

subs = subprocess.run(["git", "log", "--format=%s"], cwd=root,
                      capture_output=True, text=True).stdout
seen = {m.group(1) for m in re.finditer(r"(?:^|\s)v(\d+\.\d+)\b", subs, re.M)}
if seen:
    top = max(seen, key=tup)
    if tup(top) > tup(cur):
        print(f"❌ 提交历史里已经有 v{top},但 VERSION 还是 {cur}")
        print("   → 改 VERSION 文件(版本号只有这一个来源)")
        sys.exit(1)
print(f"✅ 版本号守卫通过 (VERSION={cur})")
