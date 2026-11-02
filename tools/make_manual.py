"""manual/manual.md를 앱에서 여는 사용자 매뉴얼 페이지(manual/index.html)로 만든다.

사용법: python3 tools/make_manual.py   (markdown 패키지 필요: pip install markdown)
manual/index.html은 직접 고치지 않는다. manual.md를 고친 뒤 다시 만든다.
"""
import html
import pathlib
import re

import markdown

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "manual" / "manual.md"
OUT = ROOT / "manual" / "index.html"


def slug(text, used):
    s = re.sub(r"[^\w가-힣]+", "-", text).strip("-").lower() or "sec"
    base, n = s, 2
    while s in used:
        s = f"{base}-{n}"; n += 1
    used.add(s)
    return s


def build():
    md = SRC.read_text(encoding="utf-8")
    title = re.search(r"^# (.+)$", md, re.M).group(1).strip()
    body = markdown.markdown(md, extensions=["tables", "sane_lists"])
    used, toc = set(), []

    def add_id(m):
        text = re.sub(r"<[^>]+>", "", m.group(1))
        sid = slug(text, used)
        toc.append((sid, text))
        return f'<h2 id="{sid}">{m.group(1)}</h2>'

    body = re.sub(r"<h2>(.*?)</h2>", add_id, body)
    body = body.replace("<table>", '<div class="tw"><table>').replace("</table>", "</table></div>")
    body = re.sub(r'<img alt="([^"]*)" src="([^"]+)" ?/?>', r'<figure><img src="\2" alt="\1" loading="lazy"><figcaption>\1</figcaption></figure>', body)
    body = re.sub(r"<p>(<figure>.*?</figure>)</p>", r"\1", body, flags=re.S)
    toc_html = "".join(f'<a href="#{i}">{html.escape(t)}</a>' for i, t in toc)
    page = f"""<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<title>{html.escape(title)}</title>
<link rel="icon" type="image/png" href="../favicon.png">
<style>
:root{{--bg:#f5f6f4;--surface:#fff;--sunk:#eceeea;--line:#d8dcd6;--fg:#1d2420;--muted:#5f6a63;--accent:#0f6b5c;--soft:#dcefe9;color-scheme:light}}
@media (prefers-color-scheme:dark){{:root{{--bg:#131816;--surface:#1b211e;--sunk:#232a26;--line:#333c37;--fg:#e7ece8;--muted:#9aa69f;--accent:#4fbfa8;--soft:#1d3a34;color-scheme:dark}}}}
*{{box-sizing:border-box}}
html{{scroll-behavior:smooth}}
body{{margin:0;background:var(--bg);color:var(--fg);font-family:"Apple SD Gothic Neo","Malgun Gothic",system-ui,sans-serif;font-size:16px;line-height:1.7;word-break:keep-all;overflow-wrap:anywhere}}
.top{{position:sticky;top:0;z-index:5;background:var(--accent);color:#fff;padding:10px 16px;display:flex;align-items:center;gap:12px}}
.top a{{color:#fff;text-decoration:none;font-weight:700;font-size:14px;white-space:nowrap}}
.top b{{flex:1;font-size:15px}}
@media (prefers-color-scheme:dark){{.top{{background:#0a4038}}}}
main{{max-width:760px;margin:0 auto;padding:8px 16px 64px}}
h1{{font-size:26px;margin:24px 0 8px;letter-spacing:-.02em}}
h2{{font-size:21px;margin:44px 0 10px;padding-top:12px;border-top:2px solid var(--line);scroll-margin-top:64px}}
nav.toc{{display:flex;flex-wrap:wrap;gap:6px;margin:16px 0 8px}}
nav.toc a{{font-size:13.5px;text-decoration:none;color:var(--accent);background:var(--soft);border-radius:99px;padding:4px 12px}}
a{{color:var(--accent)}}
strong{{font-weight:700}}
blockquote{{margin:16px 0;padding:12px 16px;background:var(--soft);border-left:4px solid var(--accent);border-radius:8px}}
blockquote p{{margin:0}}
.tw{{overflow-x:auto;margin:14px 0;border:1px solid var(--line);border-radius:10px;background:var(--surface)}}
table{{border-collapse:collapse;width:100%;font-size:14.5px}}
th,td{{text-align:left;vertical-align:top;padding:9px 12px;border-bottom:1px solid var(--line)}}
th{{background:var(--sunk);font-size:13px;white-space:nowrap}}
tr:last-child td{{border-bottom:0}}
figure{{margin:16px 0}}
figure img{{display:block;width:100%;height:auto;border-radius:10px;border:1px solid var(--line)}}
figcaption{{font-size:13px;color:var(--muted);margin-top:6px}}
ol,ul{{padding-left:22px}} li{{margin:4px 0}}
.foot{{margin-top:48px;font-size:13px;color:var(--muted);text-align:center}}
</style>
</head>
<body>
<div class="top"><b>데모콕 사용 설명서</b><a href="../">앱으로 돌아가기 →</a></div>
<main>
{body.replace('</h1>', '</h1><nav class="toc">' + toc_html + '</nav>', 1)}
<p class="foot">이 페이지는 manual/manual.md에서 자동으로 만들어져요.</p>
</main>
</body>
</html>
"""
    OUT.write_text(page, encoding="utf-8")
    print(f"{OUT.relative_to(ROOT)}: {len(toc)} sections")


if __name__ == "__main__":
    build()
