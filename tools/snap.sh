#!/bin/bash
# 截模拟器当前画面:原图存 $1,另存一张 1/3 大小的 $1 去掉 .png 加 _s.png 方便快速看。
# 用法:tools/snap.sh /path/to/name.png [等待秒数]
set -euo pipefail
sleep "${2:-1.5}"
xcrun simctl io booted screenshot "$1" >/dev/null 2>&1
python3 -c "
from PIL import Image; import sys
p = sys.argv[1]; im = Image.open(p); im.resize((im.width//3, im.height//3)).save(p[:-4] + '_s.png')" "$1"
