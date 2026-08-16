#!/usr/bin/env python3
# Copyright 2026 Gigaion, LLC
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Generate the abcli suite icon — SVG and PNG — from ONE set of constants.

    python docs/brand/render-icon.py

Writes `abcli-icon.svg` and `abcli-icon-1024.png` beside this file. The PNG is what
`flutter_launcher_icons` consumes for every platform icon; the SVG is what a human
reads, edits and drops into a README. Maintaining them as two files guarantees they
drift, and raster drift is invisible because nobody diffs a PNG — so the geometry
lives once, here, and both renderers read it.

THE MARK
    A terminal window containing the command `> AB`, with two branches leaving the
    window and merging into one arrow.

    It says what the product is (a CLI, and a GUI that drives one) and what it does
    (reconciles two states into one). The letters are Apple Business, and they are
    also the two things being merged — declared and live.

    Notes from the versions that did not work, so they are not repeated:
      * An "ab" wordmark read as "alo". Two lowercase letters at icon scale are mush.
      * An apple silhouette read as an animal head: a leaf plus a deep top notch makes
        a beak and an ear. It is also the highest-risk place to put fruit, given the
        product manages Apple Business Manager.
      * Letters beside an arrow read as clip-art. The branches have to LEAVE something.
      * Branch origins too close together fuse into a solid wedge below ~32px; the V
        has to stay open, which means a long diagonal run.

Requires only Pillow — no cairo/inkscape, neither of which installs cleanly on Windows.
Rendering is supersampled 4x then LANCZOS-downsampled, because Pillow's primitives are
not antialiased and a 16px icon built from aliased edges looks broken exactly where
icons are judged.
"""
from __future__ import annotations

import pathlib

from PIL import Image, ImageDraw

S = 1024
SS = 4
N = S * SS
HERE = pathlib.Path(__file__).parent

# --- palette -------------------------------------------------------------------
INK = (255, 255, 255)        # the window, the prompt, the letters
# Indigo -> violet, on the DIAGONAL. Sampled from the original abgui mark
# (git show v0.4.27:abgui/Resources/AppIcon.png): #525FEA top-left, #633AD9
# bottom-right, dominant ~#5840E0. Carried over deliberately — it is the colour
# the product has always been, and the one people recognise it by.
GROUND_TOP = (82, 95, 234)   # #525FEA
GROUND_BOT = (99, 58, 217)   # #633AD9
AMBER = (255, 176, 60)       # the merge. Warm against violet: the one complementary
                             # accent on the tile, so the eye lands on what HAPPENS

# --- geometry ------------------------------------------------------------------
TILE_RADIUS = 196

WIN = (130, 168, 894, 624)   # x0, y0, x1, y1
WIN_RADIUS = 56
FRAME = 40                   # window stroke
TITLE_Y = 272                # the rule under the title bar
TITLE_W = 30
DOTS = ((196, 220), (256, 220), (316, 220))
DOT_R = 17

# Lowercase "ab", measured off the original mark rather than invented:
#   x-height 270, stroke ~66 (0.24 of x-height — considerably bolder than a normal
#   geometric sans, and the reason the original reads as friendly rather than technical),
#   b-ascender 1.37x the x-height, letter gap 0.20x. Both letters are as wide as the
#   x-height: a circle with a stem flush to its right edge, and a stem with a circle
#   flush to its left.
BASELINE = 580
X_HEIGHT = 190
ASCENDER = 260               # 1.37 x the x-height, per the original
GLYPH_W = 46                 # 0.24 x the x-height
A_X = 368                    # left edge of the a
B_X = 596                    # left edge of the b's stem
PROMPT = ((238, 425), (318, 485), (238, 545))   # the > chevron, centred on the x-height

BRANCH_W = 46
BRANCH_L = 190               # inset from each window edge — a long diagonal keeps the
BRANCH_R = 190               # V open instead of fusing into a wedge when scaled down
MERGE_Y = 806
STEM_TO = 856
HEAD = (512, 952, 404, 842, 620, 842)   # apex, then the two shoulders


def k(*v):
    return [x * SS for x in v]


# ============================================================ PNG
def _stroke(md, pts, w, col=255):
    md.line(k(*[c for p in pts for c in p]), fill=col, width=int(w) * SS, joint='curve')
    r = w / 2
    for x, y in pts:
        md.ellipse(k(x - r, y - r, x + r, y + r), fill=col)


def _glyph_a(md):
    """Single-storey geometric a: a full circle with a stem flush to its right edge."""
    w, x = GLYPH_W, X_HEIGHT
    cx, cy = A_X + x / 2, BASELINE - x / 2
    r = x / 2 - w / 2                       # stroke centreline
    md.ellipse(k(cx - r, cy - r, cx + r, cy + r), outline=255, width=int(w) * SS)
    md.rounded_rectangle(k(A_X + x - w, BASELINE - x, A_X + x, BASELINE),
                         radius=int(w / 2) * SS, fill=255)


def _glyph_b(md):
    """b: ascending stem with a full circle flush to its right."""
    w, x = GLYPH_W, X_HEIGHT
    md.rounded_rectangle(k(B_X, BASELINE - ASCENDER, B_X + w, BASELINE),
                         radius=int(w / 2) * SS, fill=255)
    cx, cy = B_X + x / 2, BASELINE - x / 2
    r = x / 2 - w / 2
    md.ellipse(k(cx - r, cy - r, cx + r, cy + r), outline=255, width=int(w) * SS)


def render_png(path: pathlib.Path) -> None:
    img = Image.new('RGBA', (N, N), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    # Diagonal, top-left to bottom-right, matching the original mark. Drawn as
    # anti-diagonal bands (constant x+y) rather than rows, which is the cheap way to
    # get a 45-degree ramp out of a line primitive.
    span = 2 * (N - 1)
    for i in range(span + 1):
        t = i / span
        col = tuple(round(a + (b - a) * t) for a, b in zip(GROUND_TOP, GROUND_BOT)) + (255,)
        d.line([(max(0, i - (N - 1)), min(i, N - 1)), (min(i, N - 1), max(0, i - (N - 1)))],
               fill=col, width=2)

    ink = Image.new('L', (N, N), 0)
    idr = ImageDraw.Draw(ink)
    x0, y0, x1, y1 = WIN
    idr.rounded_rectangle(k(x0, y0, x1, y1), radius=WIN_RADIUS * SS, outline=255, width=FRAME * SS)
    idr.line(k(x0, TITLE_Y, x1, TITLE_Y), fill=255, width=TITLE_W * SS)
    # Drawn IN, not knocked out. The title bar here is a rule, not a filled bar, so
    # punching holes in the ground colour left nothing visible at all.
    for cx, cy in DOTS:
        idr.ellipse(k(cx - DOT_R, cy - DOT_R, cx + DOT_R, cy + DOT_R), fill=255)
    _stroke(idr, [PROMPT[0], PROMPT[1]], GLYPH_W)
    _stroke(idr, [PROMPT[1], PROMPT[2]], GLYPH_W)
    _glyph_a(idr)
    _glyph_b(idr)

    amber = Image.new('L', (N, N), 0)
    ad = ImageDraw.Draw(amber)
    _stroke(ad, [(x0 + BRANCH_L, y1), (512, MERGE_Y)], BRANCH_W)
    _stroke(ad, [(x1 - BRANCH_R, y1), (512, MERGE_Y)], BRANCH_W)
    _stroke(ad, [(512, MERGE_Y - 14), (512, STEM_TO)], BRANCH_W)
    ad.polygon(k(*HEAD), fill=255)

    for mask, col in ((amber, AMBER), (ink, INK)):
        lay = Image.new('RGBA', (N, N), col + (255,))
        img.alpha_composite(Image.composite(lay, Image.new('RGBA', (N, N), (0, 0, 0, 0)), mask))

    m = Image.new('L', (N, N), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, N - 1, N - 1], radius=TILE_RADIUS * SS, fill=255)
    img.putalpha(m)
    img.resize((S, S), Image.LANCZOS).save(path)


# ============================================================ SVG
def _hex(c):
    return '#%02X%02X%02X' % c


def render_svg(path: pathlib.Path) -> None:
    x0, y0, x1, y1 = WIN
    w, x = GLYPH_W, X_HEIGHT
    r = x / 2 - w / 2                      # bowl stroke centreline
    a_cx, a_cy = A_X + x / 2, BASELINE - x / 2
    b_cx, b_cy = B_X + x / 2, BASELINE - x / 2

    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {S} {S}" width="{S}" height="{S}"
     role="img" aria-label="abcli">
  <title>abcli</title>
  <!-- GENERATED by docs/brand/render-icon.py — edit the constants there, not this file.

       A terminal window running `> ab`, with two branches leaving the window and merging
       into one arrow: what the product is (a CLI, and a GUI that drives one) and what it
       does (reconciles two states into one). ab is Apple Business, and also the two things
       being merged — declared and live.

       The letterforms are measured off the original abgui mark, not invented: heavy
       geometric lowercase, stroke 0.24 of the x-height, b-ascender 1.37x. -->
  <defs>
    <linearGradient id="ground" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="{_hex(GROUND_TOP)}"/>
      <stop offset="1" stop-color="{_hex(GROUND_BOT)}"/>
    </linearGradient>
    <clipPath id="tile"><rect width="{S}" height="{S}" rx="{TILE_RADIUS}" ry="{TILE_RADIUS}"/></clipPath>
  </defs>
  <g clip-path="url(#tile)">
    <rect width="{S}" height="{S}" fill="url(#ground)"/>

    <!-- the merge: branches out of the window, into one arrow -->
    <g stroke="{_hex(AMBER)}" stroke-width="{BRANCH_W}" stroke-linecap="round" fill="none">
      <path d="M{x0 + BRANCH_L},{y1} L512,{MERGE_Y}"/>
      <path d="M{x1 - BRANCH_R},{y1} L512,{MERGE_Y}"/>
      <path d="M512,{MERGE_Y - 14} L512,{STEM_TO}"/>
    </g>
    <polygon points="{HEAD[0]},{HEAD[1]} {HEAD[2]},{HEAD[3]} {HEAD[4]},{HEAD[5]}" fill="{_hex(AMBER)}"/>

    <!-- the terminal window -->
    <g stroke="{_hex(INK)}" fill="none" stroke-linecap="round" stroke-linejoin="round">
      <!-- Inset by half the stroke. Pillow draws a rectangle outline INSIDE the given box,
           whereas SVG centres a stroke on its path — so emitting the same numbers to both
           renderers would put the SVG's frame half a stroke-width proud on every side. The
           constants are shared; this reconciles the two conventions. -->
      <rect x="{x0 + FRAME / 2}" y="{y0 + FRAME / 2}"
            width="{x1 - x0 - FRAME}" height="{y1 - y0 - FRAME}"
            rx="{WIN_RADIUS - FRAME / 2}" ry="{WIN_RADIUS - FRAME / 2}" stroke-width="{FRAME}"/>
      <path d="M{x0},{TITLE_Y} H{x1}" stroke-width="{TITLE_W}"/>

      <!-- > prompt -->
      <path d="M{PROMPT[0][0]},{PROMPT[0][1]} L{PROMPT[1][0]},{PROMPT[1][1]} L{PROMPT[2][0]},{PROMPT[2][1]}"
            stroke-width="{w}"/>

      <!-- a — a full circle with a stem flush to its right edge -->
      <circle cx="{a_cx}" cy="{a_cy}" r="{r}" stroke-width="{w}"/>
      <rect x="{A_X + x - w}" y="{BASELINE - x}" width="{w}" height="{x}"
            rx="{w / 2}" fill="{_hex(INK)}" stroke="none"/>

      <!-- b — ascending stem with a full circle flush to its right -->
      <rect x="{B_X}" y="{BASELINE - ASCENDER}" width="{w}" height="{ASCENDER}"
            rx="{w / 2}" fill="{_hex(INK)}" stroke="none"/>
      <circle cx="{b_cx}" cy="{b_cy}" r="{r}" stroke-width="{w}"/>
    </g>

    <!-- title-bar dots, in ink: the title bar is a RULE, not a filled bar, so knocking
         them out in the ground colour produced nothing visible at all. -->
    <g fill="''' + _hex(INK) + '''">
'''
    for cx, cy in DOTS:
        svg += f'      <circle cx="{cx}" cy="{cy}" r="{DOT_R}"/>\n'
    svg += '''    </g>
  </g>
</svg>
'''
    path.write_text(svg, encoding='utf-8')


if __name__ == '__main__':
    render_svg(HERE / 'abcli-icon.svg')
    render_png(HERE / 'abcli-icon-1024.png')
    print('wrote abcli-icon.svg and abcli-icon-1024.png')
