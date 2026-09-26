#!/usr/bin/env python3
"""Build the self-contained Preview page for HyperSend's window captures.

The dev server that serves .preview/ only serves the HTML file itself, so the
PNGs are inlined as base64 data URLs. Run it after taking fresh captures:

    python3 tools/preview-page.py
"""

import base64
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PREVIEW = os.path.join(ROOT, ".preview")
OUT = os.path.join(PREVIEW, "hs-glass.html")

SHOTS = [
    ("Main window", "hs-main.png",
     "Glass chrome over a live colour field. Sidebar, toolbar cluster, "
     "transfer cards and the floating status capsule all in one metal."),
    ("Settings", "hs-settings.png",
     "A real .sidebar List beside a .formStyle(.grouped) Form — the system's "
     "own grammar, so it stays correct in light, dark and Reduce Transparency."),
]


def data_url(path):
    with open(path, "rb") as handle:
        return "data:image/png;base64," + base64.b64encode(handle.read()).decode()


def figure(title, caption, src):
    return (
        '  <figure>\n'
        '    <figcaption><span class="t">' + title + '</span>'
        '<span class="c">' + caption + '</span></figcaption>\n'
        '    <img src="' + src + '" alt="' + title + '">\n'
        '  </figure>\n'
    )


def main():
    figures = []
    for title, filename, caption in SHOTS:
        path = os.path.join(PREVIEW, filename)
        if not os.path.exists(path):
            print("missing capture: " + path, file=sys.stderr)
            continue
        figures.append(figure(title, caption, data_url(path)))

    html = TEMPLATE.replace("<!--FIGURES-->", "".join(figures))
    with open(OUT, "w") as handle:
        handle.write(html)
    print("wrote " + OUT + " (" + str(os.path.getsize(OUT)) + " bytes, "
          + str(len(figures)) + " captures)")


TEMPLATE = """<!doctype html>
<meta charset="utf-8">
<title>HyperSend - Liquid Glass at Max</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body {
    margin: 0; background: #08080a; color: #f5f5f7;
    font: 13px/1.55 -apple-system, "SF Pro Text", system-ui, sans-serif;
    -webkit-font-smoothing: antialiased;
  }
  header { padding: 30px 34px 6px; }
  h1 {
    margin: 0 0 8px; font-size: 21px; font-weight: 600;
    letter-spacing: -0.021em;
  }
  header p { margin: 0; color: #98989d; max-width: 68ch; }
  .wrap { display: grid; gap: 34px; padding: 24px 34px 56px; }
  figure { margin: 0; }
  figcaption { margin-bottom: 9px; display: flex; flex-direction: column; gap: 2px; }
  figcaption .t {
    font-size: 11px; font-weight: 600; letter-spacing: 0.07em;
    text-transform: uppercase; color: #f5f5f7;
  }
  figcaption .c { font-size: 12px; color: #98989d; max-width: 68ch; }
  img {
    display: block; width: 100%; height: auto; border-radius: 13px;
    box-shadow: 0 20px 55px rgba(0,0,0,0.62),
                0 0 0 1px rgba(255,255,255,0.08);
  }
</style>
<header>
  <h1>HyperSend &mdash; Liquid Glass at Max</h1>
  <p>Live captures straight off the running app. At Max the glass is interactive
     and accent-tinted, and every panel refracts a real colour field instead of
     sitting on flat grey.</p>
</header>
<div class="wrap">
<!--FIGURES--></div>
"""


if __name__ == "__main__":
    main()
