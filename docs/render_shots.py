#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
渲染 macOS 终端风格截图（模拟运行效果，不真实发包）。

技术路线：真实 tty 带色输出 → 解析 ANSI → HTML 终端窗口 →
         qlmanage（系统 WebKit）渲染 PNG → PIL 裁白边。

  WebKit 正确处理 box-drawing（╭─╮╰╯）与 CJK，杜绝缺字 / 字形错位乱码。

内容来源：
  - help / login / logout：以 DRY_RUN=1 在伪 tty（script）真实运行捕获的带色输出
  - auto：据 guet_drcom.sh 中 auto_command() 的输出语句模拟（auto 会改 crontab，不真实运行）

用法：python3 docs/render_shots.py
"""
import html
import os
import re
import subprocess
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOCS = os.path.join(ROOT, "docs")

# ---- ANSI → CSS 类 ----
# 对照 guet_drcom.sh：1=bold 2=dim 31=red 32=green 33=yellow 36=cyan 0=reset
ANSI_CLASS = {1: "b", 2: "d", 31: "r", 32: "g", 33: "y", 36: "c"}
ANSI_RE = re.compile(r"\x1b\[([0-9;]*)m")


def ansi_to_html(line):
    """把一行带 ANSI 的文本转成 HTML span 序列。"""
    # 维护当前样式栈
    out = []
    cur = set()

    def flush():
        if not cur:
            return ""
        cls = " ".join(sorted(cur))
        return f'</span><span class="{cls}">'

    out.append('<span>')  # 默认前景
    pos = 0
    for m in ANSI_RE.finditer(line):
        out.append(html.escape(line[pos:m.start()], quote=False))
        pos = m.end()
        for code in (m.group(1).split(";") if m.group(1) else ["0"]):
            code = int(code) if code else 0
            if code == 0:
                cur.clear()
            elif code in ANSI_CLASS:
                cur.add(ANSI_CLASS[code])
        out.append(flush())
    out.append(html.escape(line[pos:], quote=False))
    out.append("</span>")
    return "".join(out)


def tty_to_body(path):
    """读 tty 捕获文件，去控制字符，逐行转 HTML。"""
    raw = open(path, "rb").read().decode("utf-8", "replace")
    # 去 script 残留控制字符与 \r
    raw = raw.replace("\r", "").replace("\x04", "")
    lines = raw.split("\n")
    # 去首尾空行
    while lines and not lines[0].strip():
        lines.pop(0)
    while lines and not lines[-1].strip():
        lines.pop()
    return "\n".join(ansi_to_html(ln) for ln in lines)


def build_html(title, body_html):
    return f"""<!DOCTYPE html><html><head><meta charset="utf-8">
<style>
* {{ margin:0; padding:0; box-sizing:border-box; }}
html {{ background:#ffffff; }}
body {{ padding:40px; background:#ffffff; display:inline-block; }}
.term {{
  background:#1e1e1e; border-radius:8px; padding:0; box-shadow:0 6px 24px rgba(0,0,0,.45);
  font-family:"Menlo","SF Mono","PingFang SC","STHeiti","Heiti SC",sans-serif;
  font-size:22px; line-height:1.55; color:#cccccc;
  display:inline-block; overflow:hidden;
}}
.bar {{ background:#3a3a3a; height:38px; display:flex; align-items:center;
        padding:0 14px; position:relative; }}
.dot {{ width:13px; height:13px; border-radius:50%; display:inline-block; margin-right:9px; }}
.r {{ background:#ff5f56; }} .y2 {{ background:#ffbd2e; }} .gn {{ background:#27c93f; }}
.title {{ position:absolute; left:0; right:0; text-align:center; color:#a8a8a8;
         font-size:13px; font-family:-apple-system,"Helvetica Neue",sans-serif;
         line-height:38px; pointer-events:none; }}
.body {{ padding:16px 20px; white-space:pre; }}
.b {{ font-weight:bold; color:#e6e6e6; }}
.d {{ color:#7a7a7a; }}
.c {{ color:#4ec9e8; }} .b.c {{ color:#4ec9e8; font-weight:bold; }}
.g {{ color:#7ec680; }} .b.g {{ color:#7ec680; font-weight:bold; }}
.y {{ color:#dcdcaa; }} .b.y {{ color:#dcdcaa; font-weight:bold; }}
.r {{ color:#f44747; }}
</style></head><body>
<div class="term">
  <div class="bar">
    <span class="dot r"></span><span class="dot y2"></span><span class="dot gn"></span>
    <span class="title">{html.escape(title)}</span>
  </div>
  <div class="body">{body_html}</div>
</div>
</body></html>"""


def render(title, body_html, out_name):
    hpath = os.path.join("/tmp", out_name.replace(".png", ".html"))
    open(hpath, "w", encoding="utf-8").write(build_html(title, body_html))
    # qlmanage 渲染（WebKit），输出固定正方形 PNG
    pngdir = "/tmp"
    subprocess.run(["qlmanage", "-t", "-s", "2000", "-o", pngdir, hpath],
                   capture_output=True)
    qlpng = os.path.join(pngdir, os.path.basename(hpath) + ".png")
    im = Image.open(qlpng).convert("RGB")
    # 裁白边：找非背景(#1e1e1e)区域
    bg = (30, 30, 30)
    pix = im.load()
    w, h = im.size
    # qlmanage 可能留白边（背景是 #1e1e1e 之外可能近黑/白），统一裁到终端窗口
    # 找最左/右/上/下非纯白且非纯黑像素
    from PIL import Image as I
    import numpy as np
    a = np.asarray(im)
    # 终端窗口有 #3a3a3a 标题栏 + #1e1e1e 正文，都是深色；qlmanage 背景若为白需裁白
    # 判前景：与白色差异大的像素
    nonwhite = (a.min(axis=2) < 240)
    ys = nonwhite.any(axis=1)
    xs = nonwhite.any(axis=0)
    if xs.any() and ys.any():
        x0, x1 = int(xs.argmax()), int(w - xs[::-1].argmax())
        y0, y1 = int(ys.argmax()), int(h - ys[::-1].argmax())
        im = im.crop((max(0, x0 - 4), max(0, y0 - 4),
                      min(w, x1 + 4), min(h, y1 + 4)))
    out = os.path.join(DOCS, out_name)
    im.save(out)
    print("saved", out, im.size)


# ---- auto：据 auto_command() 模拟的带色输出 ----
AUTO_LINES = [
    "\x1b[1m\x1b[36m╭─ GUET Dr.COM ─────────────────────────╮\x1b[0m",
    "\x1b[1m  自动重连\x1b[0m",
    "\x1b[1m\x1b[36m╰───────────────────────────────────────╯\x1b[0m",
    "\x1b[32m✓\x1b[0m 定时任务已启用，每分钟检查一次",
    "  \x1b[2m配置文件\x1b[0m /Users/bsty/documents/drcom2026/.env",
    "  \x1b[2m日志文件\x1b[0m /Users/bsty/documents/drcom2026/guet_drcom.log",
    "  \x1b[2m查看任务\x1b[0m crontab -l",
]
auto_body = "\n".join(ansi_to_html(l) for l in AUTO_LINES)

render("guet_drcom.sh — help  (DRY_RUN)", tty_to_body("/tmp/help_tty.txt"), "screenshot-help.png")
render("guet_drcom.sh — login  (DRY_RUN=1)", tty_to_body("/tmp/login_tty.txt"), "screenshot-login.png")
render("guet_drcom.sh — logout  (DRY_RUN=1)", tty_to_body("/tmp/logout_tty.txt"), "screenshot-logout.png")
render("guet_drcom.sh — auto", auto_body, "screenshot-auto.png")
