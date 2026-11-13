#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
公开站点生成器 —— 输出 site/ 下的三个静态页,给 App Store Connect 用。

App Store Connect 三个 URL 位:
  · **隐私政策 URL** —— 必填
  · **支持 URL(Support URL)** —— **必填**。★ 2026-09-01 复核才发现:
    原来的 SUBMISSION.md 只写了隐私政策,**漏了这一条**,而它是提交时的硬性字段。
  · 营销 URL —— 选填,这里用首页顶上

★ 生成器驱动,不要手改 site/*.html。
★ 原来的 privacy.html 是 markdown 粗转 HTML,多行列表项被拆成
  `<li>半句</li></ul><p>另半句</p>` —— 结构是坏的。这一版直接写 HTML。
"""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE.parent / "site"
OUT.mkdir(exist_ok=True)

# 联系邮箱。★ 之前这里写的是我**编出来的**地址,已经改成由参数传入,
#   宁可生成失败,也不要把一个不存在的邮箱印到隐私政策上。
CONTACT = None

CSS = """
:root{color-scheme:light dark;--fg:#1d232e;--bg:#fff;--dim:#5b6a80;--line:#dde3ec;--card:#f6f8fb;--accent:#0b63ce}
@media(prefers-color-scheme:dark){:root{--fg:#e7ecf3;--bg:#0f1420;--dim:#94a3b8;--line:#232c3d;--card:#161d2b;--accent:#5ea0ff}}
*{box-sizing:border-box}
body{max-width:44rem;margin:0 auto;padding:2.5rem 1.25rem 5rem;
 font:16px/1.75 -apple-system,BlinkMacSystemFont,"PingFang SC","Helvetica Neue",sans-serif;
 color:var(--fg);background:var(--bg)}
h1{font-size:1.8rem;margin:0 0 .3rem;letter-spacing:-.01em}
h2{font-size:1.22rem;margin:2.4rem 0 .6rem}
h3{font-size:1rem;margin:1.7rem 0 .4rem;color:var(--dim)}
p,li{margin:.5rem 0}
ul{padding-left:1.15rem}
a{color:var(--accent)}
hr{border:0;border-top:1px solid var(--line);margin:2.8rem 0}
code{background:var(--card);padding:.1em .35em;border-radius:4px;font-size:.9em}
.lede{color:var(--dim);font-size:1.05rem;margin:.2rem 0 1.6rem}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:1rem 1.15rem;margin:1.1rem 0}
.nav{font-size:.92rem;color:var(--dim);margin-bottom:2.2rem}
.nav a{margin-right:1rem}
footer{margin-top:3.5rem;padding-top:1.4rem;border-top:1px solid var(--line);color:var(--dim);font-size:.88rem}
"""

def page(title, body, nav_here=""):
    def n(href, label):
        return f'<strong>{label}</strong>' if nav_here == href else f'<a href="{href}">{label}</a>'
    return f"""<!DOCTYPE html><html lang="zh-Hans"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{title}</title><style>{CSS}</style></head><body>
<div class="nav">{n('index.html','复盘镜')} · {n('support.html','支持')} · {n('privacy.html','隐私政策')}</div>
{body}
<footer>复盘镜 · TradeMirror —— 交易复盘的反事实计算器。<br>
不提供投资建议,不给买卖信号,不预测价格,不代为下单。<br>
联系:<a href="mailto:{CONTACT}">{CONTACT}</a></footer>
</body></html>"""


def index():
    return page("复盘镜 · TradeMirror", f"""
<h1>复盘镜 · TradeMirror</h1>
<p class="lede">它不只记录你赚了多少,它算<strong>「如果换个做法会怎样」</strong>。</p>

<p>你已经从券商 App 知道<strong>发生了什么</strong>。复盘镜的增量只有一个:同一笔交易,
换成另一种做法会是什么结果 —— 而且是<strong>双向的</strong>。</p>

<div class="card">
<ul>
<li>若<strong>持有到收盘</strong>会怎样(0DTE 常常是归零,这条比「卖早了」重要得多)</li>
<li>若<strong>不加仓</strong>、只做首仓会怎样</li>
<li>若<strong>触及目标平一半</strong>、剩余持有会怎样</li>
<li>若在<strong>标的峰值</strong>处出场会怎样</li>
</ul>
<p>四条都会明确告诉你「<strong>你的做法更好</strong>」还是「那样会更好」。
只算一个方向的反事实,会变成后悔生成器 —— 所以这里两个方向都算。</p>
</div>

<h2>录入:截个图就行</h2>
<ul>
<li>在券商成交详情页截图,<strong>分享 → 复盘镜</strong>。不用切回相册,不用切 App</li>
<li>自动识别标的、张数、成交价、时间 —— 你只需核对一眼</li>
<li>一次可以选多张,同一笔的开仓和平仓会自动配到一起</li>
<li><strong>永不自动保存。</strong>识别错了,当场改</li>
</ul>

<h2>隐私</h2>
<p><strong>只有你点「自动填标的价」时才联网</strong>,而且发出去的只有<strong>一个股票代码和一个日期</strong>。不连券商、不注册账号、没有分析、没有广告、没有第三方 SDK。
数据只在你手机里 —— 而且<strong>随时导得出去,也导得回来</strong>。
详见<a href="privacy.html">隐私政策</a>。</p>

<h2>需要帮助</h2>
<p>去<a href="support.html">支持页</a>。里面写清楚了这一版<strong>算不了什么</strong> ——
这类事实比任何功能列表都有用。</p>
""", "index.html")


def support():
    return page("支持 · 复盘镜", f"""
<h1>支持</h1>
<p class="lede">有问题、发现算错了、想要某个功能 —— 都从这里说。</p>

<div class="card">
<p><strong>邮箱:<a href="mailto:{CONTACT}">{CONTACT}</a></strong></p>
<p>写清楚:①什么品种/策略 ②你做了什么 ③你期待看到什么、实际看到什么。
如果是数字对不上,<strong>附上你在 App 里导出的 CSV</strong> 最有用
(「数据与备份 → 导出 CSV」)。</p>
</div>

<h2>常见问题</h2>

<h3>为什么未平仓的持仓不显示盈亏?</h3>
<p>因为<strong>未平仓的持仓成本不是亏损</strong>。只录了买入的一笔如果显示成红色的
「−$434」,那是把开仓花掉的钱当成了亏损 —— 那不是盈亏,是成本。
平掉之后盈亏才会出现。</p>

<h3>为什么同一个标的买了两次,只算一笔交易?</h3>
<p>因为那本来就是一笔交易的两次成交(加仓)。拆成两笔会让均价、盈亏、
以及「不加仓会怎样」这条反事实全部失真。<strong>浮亏加仓会被自动标出来。</strong></p>

<h3>做空怎么记?</h3>
<p>不用找开关 —— <strong>第一笔选「卖」就是做空</strong>。
入场价会显示你的卖出价,不是买回价。</p>

<h3>识别错了怎么办?</h3>
<p>确认页上每个字段都能改,而且<strong>永远不会自动保存</strong>。
券商的截图版式各不相同,识别不可能百分之百 —— 所以设计上就要你核对一眼。</p>

<h3>数据会丢吗?怎么备份?</h3>
<p>数据只在你手机的 App 沙盒里。<strong>iPhone 的整机备份会带上它,所以换手机不会丢;
但误删 App 会。</strong></p>
<p>所以请用「<strong>数据与备份 → 导出备份文件</strong>」,存到「文件」/iCloud Drive/邮件里。
那个备份<strong>能原样导回来</strong>,而且<strong>导回时只合并、不覆盖</strong> ——
已经有的那几笔会被跳过,并如实告诉你跳了几笔。</p>

<h3>CSV 和备份文件有什么区别?</h3>
<p>CSV 给 Excel 看,<strong>有损,导不回来</strong>(多腿、心理标签会被摊平)。
备份文件<strong>无损,能导回来</strong>。<strong>要留退路请用备份文件。</strong></p>

<h2>这一版算不了的</h2>
<p>写在前面,免得你以为是坏了:</p>
<ul>
<li><strong>期权的分钟级价格路径</strong> —— 股票/ETF、期货、外汇的分钟 K,
App 点一下就能取(免费公开行情,<strong>但只回溯 29 天</strong>,更早的只能画示意图)。
<strong>期权不行</strong>:期权的历史行情没有免费源。
但如果你有 moomoo:在电脑上跑一次 <code>tools/moomoo_enrich.py</code> 把备份补全再导回来,
这两条就都能算了 —— <strong>真 MAE、真 MFE、你吃到了 MFE 的百分之几、
挂移动止损会怎样</strong>,全部基于真实成交路径,不是模型估的。</li>
<li><strong>自动同步券商</strong> —— 不做。做了就要拿你的账户凭据,那是另一个量级的信任。</li>
<li><strong>期权的历史收盘价</strong> —— 没有免费数据源(实测过)。所以那一格给的是<strong>模型估算</strong>,并且<strong>标明是估算、让你直接改</strong>。末日期权尤其要改:收盘时往往还有几分钱时间价值,而模型算的是到期归零。</li>
<li><strong>英文界面</strong> —— 这一版只有中文。</li>
</ul>

<h2>它不做的事</h2>
<p>本 App <strong>不提供投资建议</strong>,不给买卖信号,不预测价格,不代为下单,
不连接任何券商账户。它只对你<strong>自己录入的、已经发生的</strong>交易做计算。</p>
""", "support.html")


def privacy():
    return page("隐私政策 · 复盘镜", f"""
<h1>隐私政策 · Privacy Policy</h1>
<p class="lede">最后更新 / Last updated: 2026-09-01</p>

<h2>中文</h2>
<p><strong>复盘镜(TradeMirror)不收集任何数据。</strong></p>
<ul>
<li><strong>只有一处联网,而且要你主动点。</strong>点「自动填标的价」时,App 会向公开行情源
请求某个代码某一天的行情(开高低收,以及当天的分钟 K)。
<strong>发出去的只有代码和日期</strong> —— 不含你的成交、张数、盈亏、心理标签,
也不含任何设备或账号标识。不点就完全不联网,手动填一样能算。</li>
<li><strong>没有分析、没有崩溃上报、没有广告 SDK、没有第三方 SDK。</strong></li>
<li><strong>不注册账号。</strong>没有登录,没有邮箱,没有手机号。</li>
<li><strong>不连接券商。</strong>App 不读取、不同步你的任何券商或银行账户。</li>
<li><strong>数据只在你的设备上。</strong>你录入的交易保存在本 App 的沙盒文件里
(<code>Documents/trades.json</code>)。它会随你自己的 iPhone 备份(iCloud 备份或电脑备份)
一起备份 —— 那是你和 Apple 之间的事,开发者接触不到。</li>
<li><strong>删除 App 即删除全部数据。</strong>所以 App 里提供了「导出备份文件」——
导出去的文件由你自己保管,<strong>App 不参与、也不知道你存到了哪里</strong>。</li>
<li><strong>照片。</strong>从相册选截图用的是系统选择器,只有你选中的那几张会交给 App;
App <strong>不申请、也没有</strong>相册访问权限。识别在本机完成,图片不会离开设备。</li>
</ul>
<p><strong>开发者无法看到你的任何交易记录</strong>,因为它们从未离开过你的设备。</p>

<h3>关于本 App 不做的事</h3>
<p>本 App <strong>不提供投资建议</strong>,不给出买卖信号,不预测价格,不代为下单,
不连接任何券商账户。它只对你<strong>自己录入的、已经发生的</strong>交易做计算。</p>

<h3>联系方式</h3>
<p>有任何问题:<a href="mailto:{CONTACT}">{CONTACT}</a></p>

<hr>

<h2>English</h2>
<p><strong>TradeMirror collects no data.</strong></p>
<ul>
<li><strong>One network call, and only when you tap it.</strong> Tapping "auto-fill
underlying price" requests one symbol's prices for one date (daily OHLC plus that day's minute bars) from a public
market-data source. <strong>Only the ticker and the date leave your device</strong> — never your
fills, sizes, P&amp;L, psychology tags, or any device/account identifier. Don't tap it and the app
never touches the network; typing the price by hand works exactly the same.</li>
<li><strong>No analytics, no crash reporting, no advertising SDKs, no third-party SDKs.</strong></li>
<li><strong>No account.</strong> No sign-in, no email, no phone number.</li>
<li><strong>No brokerage connection.</strong> The app never reads or syncs any brokerage
or bank account.</li>
<li><strong>Your data stays on your device.</strong> Trades you enter are stored in the
app's own sandbox (<code>Documents/trades.json</code>). It is included in your own iPhone
backup (iCloud or computer) — that is between you and Apple; the developer has no access.</li>
<li><strong>Deleting the app deletes all of it.</strong> That is why the app offers
"Export backup" — the exported file is yours to keep, and the app has no idea where
you put it.</li>
<li><strong>Photos.</strong> Picking screenshots uses the system picker, so only the
images you select are handed to the app. The app requests <strong>no</strong> photo-library
permission. Recognition happens on-device; images never leave your phone.</li>
</ul>
<p><strong>The developer cannot see any of your trades</strong>, because they never leave
your device.</p>

<h3>What this app does not do</h3>
<p>This app <strong>does not provide investment advice</strong>. It gives no buy/sell
signals, makes no price predictions, places no orders, and connects to no brokerage
account. It only performs calculations on trades <strong>you entered yourself, that
already happened</strong>.</p>

<h3>Contact</h3>
<p><a href="mailto:{CONTACT}">{CONTACT}</a></p>
""", "privacy.html")


if __name__ == "__main__":
    if len(sys.argv) < 2 or "@" not in sys.argv[1]:
        sys.exit("用法: make_site.py <联系邮箱>\n"
                 "★ 必须显式传入 —— 隐私政策上的邮箱不能是编的。")
    CONTACT = sys.argv[1]
    for name, fn in [("index.html", index), ("support.html", support),
                     ("privacy.html", privacy)]:
        (OUT / name).write_text(fn(), encoding="utf-8")
        print("wrote site/" + name)
