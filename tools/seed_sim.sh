#!/bin/bash
# 往已启动的模拟器写一份用户的真实交易,方便拍界面前后对比。
# 用法:tools/seed_sim.sh          (需要模拟器已开、App 已装过一次)
set -euo pipefail
cd "$(dirname "$0")/.."
C=$(xcrun simctl get_app_container booted dev.ruizhang.trademirror data)/Documents
mkdir -p "$C"
SEED_DEST="$C/trades.json" swift test --filter DevSeedTests 2>&1 | grep -E "✅|error" || true
xcrun simctl terminate booted dev.ruizhang.trademirror 2>/dev/null || true
xcrun simctl launch booted dev.ruizhang.trademirror >/dev/null
