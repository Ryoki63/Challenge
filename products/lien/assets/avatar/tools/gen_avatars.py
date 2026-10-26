#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Lien avatar set generator (Python 3 stdlib only).

Writes, under assets/avatar/:
  svg/avatar_<id>.svg          12 circular badges (viewBox 0 0 120 120, transparent outside the circle)
  avatars.json                 ordered [{"id", "name_ja"}]
  AvatarAssets.xcassets/       rebuilt from scratch every run
  preview/sheet.png            4x3 grid, 200px each, with labels
  preview/sheet_small.png      56 / 44 / 28 px rows on white and on #1C1C1E

Run:  python3 assets/avatar/tools/gen_avatars.py            (add --no-preview to skip Chrome)
"""

import json
import math
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent  # assets/avatar
SVG_DIR = ROOT / 'svg'
XC_DIR = ROOT / 'AvatarAssets.xcassets'
PREV_DIR = ROOT / 'preview'
CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'

# ----------------------------------------------------------------------------
# palette / stroke widths (same family as assets/plant/tools/gen_v4.py)
# ----------------------------------------------------------------------------
OUT = '#4A3428'
EYE = '#3A2A22'
BLUSH = '#FF9C9C'
CREAM = '#FFF1DC'
LEAF = '#82C95C'
LEAF_L = '#B5E58C'
LEAF_D = '#5BA543'
VEIN = '#D6F5B8'
STEM = '#74BD52'
SPARK = '#FFCF4D'
SPARK_L = '#FFF0B3'
WHITE = '#FFFFFF'
SHADE = '#9C6B45'

SW = 3.0    # head / pot / hats
SWA = 2.6   # accessories
SWD = 2.0   # fine detail

HEAD_D = 'M14 82C14 56 32 38 60 38C88 38 106 56 106 82L106 102L14 102Z'


# ----------------------------------------------------------------------------
# tiny svg helpers
# ----------------------------------------------------------------------------
def f(v):
    v = round(float(v), 1)
    if v == 0:
        return '0'
    s = '%.1f' % v
    return s[:-2] if s.endswith('.0') else s


def cs(deg):
    a = math.radians(deg)
    return round(math.cos(a), 10), round(math.sin(a), 10)


def mix(c1, c2, t):
    a = [int(c1[i:i + 2], 16) for i in (1, 3, 5)]
    b = [int(c2[i:i + 2], 16) for i in (1, 3, 5)]
    return '#%02X%02X%02X' % tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def _ex(extra):
    return (' ' + extra) if extra else ''


def _stroke(stroke, sw):
    if not stroke:
        return ''
    return ' stroke="%s" stroke-width="%s" stroke-linejoin="round" stroke-linecap="round"' % (stroke, f(sw))


def _rot(rot, cx, cy):
    if not rot:
        return ''
    if isinstance(rot, tuple):
        return ' transform="rotate(%s %s %s)"' % (f(rot[0]), f(rot[1]), f(rot[2]))
    return ' transform="rotate(%s %s %s)"' % (f(rot), f(cx), f(cy))


def P(d, fill='none', stroke=None, sw=SWA, extra=''):
    return '<path d="%s" fill="%s"%s%s/>' % (d, fill, _stroke(stroke, sw), _ex(extra))


def E(cx, cy, rx, ry, fill, stroke=None, sw=SWA, rot=0, extra=''):
    return '<ellipse cx="%s" cy="%s" rx="%s" ry="%s" fill="%s"%s%s%s/>' % (
        f(cx), f(cy), f(rx), f(ry), fill, _stroke(stroke, sw), _rot(rot, cx, cy), _ex(extra))


def C(cx, cy, r, fill, stroke=None, sw=SWA, extra=''):
    return '<circle cx="%s" cy="%s" r="%s" fill="%s"%s%s/>' % (
        f(cx), f(cy), f(r), fill, _stroke(stroke, sw), _ex(extra))


def G(inner, transform=None, extra=''):
    t = (' transform="%s"' % transform) if transform else ''
    return '<g%s%s>%s</g>' % (t, _ex(extra), inner)


class Ctx(object):
    """Collects <defs> for one avatar; every id is prefixed with the avatar id."""

    def __init__(self, pid):
        self.pid = pid
        self.defs = []
        self._seen = set()

    def _id(self, name):
        return '%s_%s' % (self.pid, name)

    def lin(self, name, stops, x1=0, y1=0, x2=0, y2=1):
        gid = self._id(name)
        if gid not in self._seen:
            self._seen.add(gid)
            s = ''.join('<stop offset="%g" stop-color="%s"/>' % (o, col) for o, col in stops)
            self.defs.append('<linearGradient id="%s" x1="%g" y1="%g" x2="%g" y2="%g">%s</linearGradient>'
                             % (gid, x1, y1, x2, y2, s))
        return 'url(#%s)' % gid

    def rad(self, name, stops, cx=0.5, cy=0.5, r=0.5):
        gid = self._id(name)
        if gid not in self._seen:
            self._seen.add(gid)
            s = ''.join('<stop offset="%g" stop-color="%s"/>' % (o, col) for o, col in stops)
            self.defs.append('<radialGradient id="%s" cx="%g" cy="%g" r="%g">%s</radialGradient>'
                             % (gid, cx, cy, r, s))
        return 'url(#%s)' % gid

    def clip(self, name, shape):
        gid = self._id(name)
        if gid not in self._seen:
            self._seen.add(gid)
            self.defs.append('<clipPath id="%s">%s</clipPath>' % (gid, shape))
        return 'url(#%s)' % gid


# ----------------------------------------------------------------------------
# shape helpers
# ----------------------------------------------------------------------------
def leaf(x, y, L, W, ang, flip=False, sw=SWA, tip=0.75, col=(LEAF, LEAF_L)):
    """Two-tone leaf; base at (x,y), pointing along `ang` degrees (SVG rotate sign). flip mirrors x."""
    c1, c2 = L * 0.25, L * 0.7
    up = 'C%s %s %s %s %s 0' % (f(c1), f(-W * 0.9), f(c2), f(-W * tip), f(L))
    dn = 'C%s %s %s %s 0 0' % (f(c2), f(W * tip), f(c1), f(W * 0.9))
    outer = 'M0 0%s%sZ' % (up, dn)
    half = 'M0 0%sZ' % up
    vein = 'M%s 0L%s 0' % (f(L * 0.14), f(L * 0.62))
    body = P(outer, col[0]) + P(half, col[1]) + P(vein, 'none', VEIN, 1.3) + P(outer, 'none', OUT, sw)
    t = 'translate(%s %s)' % (f(x), f(y)) + (' scale(-1 1)' if flip else '') + ' rotate(%s)' % f(ang)
    return G(body, t)


def stem(d, core=3.0, color=STEM, sw=SWA):
    return P(d, 'none', OUT, core + 2 * sw * 0.6) + P(d, 'none', color, core)


def rounded_poly(pts, radii):
    n = len(pts)
    d = ''
    for i in range(n):
        p0, p1, p2 = pts[i - 1], pts[i], pts[(i + 1) % n]
        r = radii[i]

        def toward(a, b, dist):
            dx, dy = b[0] - a[0], b[1] - a[1]
            l = math.hypot(dx, dy)
            return (a[0] + dx / l * dist, a[1] + dy / l * dist)

        a = toward(p1, p0, r)
        b = toward(p1, p2, r)
        d += ('M' if i == 0 else 'L') + '%s %s' % (f(a[0]), f(a[1]))
        d += 'Q%s %s %s %s' % (f(p1[0]), f(p1[1]), f(b[0]), f(b[1]))
    return d + 'Z'


def star_path(cx, cy, R, r, rot=-90, tip=2.4, inner=1.1):
    pts, rad = [], []
    for k in range(10):
        c, s = cs(rot + k * 36)
        rr = R if k % 2 == 0 else r
        pts.append((cx + rr * c, cy + rr * s))
        rad.append(tip if k % 2 == 0 else inner)
    return rounded_poly(pts, rad)


def sparkle(cx, cy, s, fill=SPARK, sw=SWD, k=0.2):
    q = s * k
    d = ('M%s %sQ%s %s %s %s' % (f(cx), f(cy - s), f(cx + q), f(cy - q), f(cx + s), f(cy)) +
         'Q%s %s %s %s' % (f(cx + q), f(cy + q), f(cx), f(cy + s)) +
         'Q%s %s %s %s' % (f(cx - q), f(cy + q), f(cx - s), f(cy)) +
         'Q%s %s %s %sZ' % (f(cx - q), f(cy - q), f(cx), f(cy - s)))
    return P(d, fill, OUT, sw)


def crescent_path(cx, cy, R, r, d, ang=0):
    x0 = (d * d + R * R - r * r) / (2.0 * d)
    y0 = math.sqrt(max(R * R - x0 * x0, 0))
    c, s = cs(ang)

    def rp(px, py):
        return cx + px * c - py * s, cy + px * s + py * c

    p1, p2 = rp(x0, -y0), rp(x0, y0)
    return ('M%s %sA%s %s 0 1 0 %s %sA%s %s 0 1 1 %s %sZ' %
            (f(p1[0]), f(p1[1]), f(R), f(R), f(p2[0]), f(p2[1]), f(r), f(r), f(p1[0]), f(p1[1])))


def hat_shadow(c, shape, dy=3.0, op=0.30, band=None):
    """Soft contact shadow on the head right under a hat (copy of the hat, shifted down, clipped to the head)."""
    clip = c.clip('headclip', '<path d="%s"/>' % HEAD_D)
    tr = 'transform="translate(0 %s)"' % f(dy)
    if band:
        s = P(shape, 'none', SHADE, band, 'stroke-opacity="%s" %s' % (op, tr))
    else:
        s = P(shape, SHADE, None, extra='fill-opacity="%s" %s' % (op, tr))
    return G(s, extra='clip-path="%s"' % clip)


# ----------------------------------------------------------------------------
# the mascot: head, face, pot, hands
# ----------------------------------------------------------------------------
def gloss(kind):
    if kind == 'none':
        return ''
    if kind == 'hat':
        return (E(25.5, 63, 5.2, 2.5, WHITE, rot=-62, extra='fill-opacity=".9"') +
                C(24.6, 71.2, 1.6, WHITE, extra='fill-opacity=".9"'))
    return (E(37, 51, 8, 3.8, WHITE, rot=-33, extra='fill-opacity=".9"') +
            C(28.3, 61.6, 1.9, WHITE, extra='fill-opacity=".9"'))


def face(kind, dx=0.0, look=0.0):
    ey, ex = 63.0, 17.0
    xl, xr = 60 - ex + dx, 60 + ex + dx
    mx = 60 + dx * 0.8

    def open_eye(x):
        return (E(x, ey, 4.6, 6.0, EYE) + C(x + 1.6 + look, ey - 2.4, 2.0, WHITE) +
                C(x - 1.5 + look * 0.4, ey + 2.5, 0.9, WHITE, extra='fill-opacity=".8"'))

    def happy_eye(x):
        return P('M%s %sQ%s %s %s %s' % (f(x - 5.2), f(ey + 2.2), f(x), f(ey - 7.2), f(x + 5.2), f(ey + 2.2)),
                 'none', EYE, 3.0)

    def sleep_eye(x):
        return P('M%s %sQ%s %s %s %s' % (f(x - 5.2), f(ey - 1.2), f(x), f(ey + 7.4), f(x + 5.2), f(ey - 1.2)),
                 'none', EYE, 3.0)

    smile = P('M%s 72Q%s 77.6 %s 72' % (f(mx - 4.6), f(mx), f(mx + 4.6)), 'none', OUT, 2.4)
    wide = P('M%s 71.6Q%s 79 %s 71.6' % (f(mx - 5.2), f(mx), f(mx + 5.2)), 'none', OUT, 2.4)
    opened = (P('M%s 71.2C%s 78.4 %s 82 %s 82C%s 82 %s 78.4 %s 71.2Z' %
                (f(mx - 5.4), f(mx - 5.4), f(mx - 2.6), f(mx), f(mx + 2.6), f(mx + 5.4), f(mx + 5.4)),
                '#B5473F', OUT, 2.2) + E(mx, 78.6, 2.9, 1.8, '#FF8C8C'))
    small_o = E(mx, 75.0, 3.1, 2.3, '#E58B82', OUT, 1.8)

    blush = (E(60 - 29 + dx * 0.7, 73.4, 6.8, 4.2, BLUSH, extra='fill-opacity=".62"') +
             E(60 + 29 + dx * 0.7, 73.4, 6.8, 4.2, BLUSH, extra='fill-opacity=".62"'))
    if kind == 'happy':
        eyes, mouth = happy_eye(xl) + happy_eye(xr), opened
    elif kind == 'wink':
        eyes, mouth = open_eye(xl) + happy_eye(xr), wide
    elif kind == 'sleep':
        eyes, mouth = sleep_eye(xl) + sleep_eye(xr), small_o
    else:
        eyes, mouth = open_eye(xl) + open_eye(xr), smile
    return blush + eyes + mouth


def pot(c):
    gp = c.lin('gPot', [(0, '#F4AE86'), (.45, '#E6895C'), (1, '#CC6E45')], 0, 0, 1, 0)
    gr = c.lin('gRim', [(0, '#F7BE9A'), (.5, '#F4AE86'), (1, '#E6895C')], 0, 0, 1, 0)
    body = P('M10 104H110L104 128H16Z', gp, OUT, SW)
    rim = ('<rect x="3" y="91" width="114" height="16" rx="8" fill="%s" stroke="%s" stroke-width="%s" '
           'stroke-linejoin="round"/>' % (gr, OUT, f(SW)))
    hl = P('M17 96.2H46', 'none', WHITE, 2.2, 'stroke-opacity=".5"')
    return body + rim + hl


def hands():
    s = ''
    for x, rot, hx in ((23.5, -14, -1.8), (96.5, 14, 1.8)):
        s += E(x, 90.5, 7.6, 5.9, CREAM, OUT, SW, rot)
        s += E(x + hx, 88.2, 2.4, 1.2, WHITE, rot=rot, extra='fill-opacity=".6"')
    return s


# ----------------------------------------------------------------------------
# accessories: each returns (behind_head, in_front_of_head)
# ----------------------------------------------------------------------------
def b_sprout(c):
    b = stem('M60 50C60 42 60 37 60 33')
    b += leaf(60, 33, 28, 11, -30) + leaf(60, 33, 28, 11, -30, flip=True)
    return b, ''


def b_tulip(c):
    g_out = c.lin('gTulip', [(0, '#FFC2D3'), (1, '#F58BA9')])
    g_mid = c.lin('gTulipMid', [(0, '#FFE6EC'), (1, '#FFB8CC')])
    b = stem('M60 50C60 44 60 38 60 31')
    b += leaf(60, 40, 22, 7.5, -26) + leaf(60, 40, 22, 7.5, -26, flip=True)
    outer = 'M46.5 11C43 21 49.5 32.5 60 34C70.5 32.5 77 21 73.5 11L66.5 19.5L60 8L53.5 19.5Z'
    mid = 'M53.5 19.5L60 8L66.5 19.5C68 26 64 31 60 34C56 31 52 26 53.5 19.5Z'
    b += P(outer, g_out, OUT, SWA) + P(mid, g_mid, OUT, SWD)
    return b, ''


def b_sunflower(c):
    g_pet = c.lin('gPetal', [(0, '#FFF0A0'), (1, '#FFCF45')])
    g_cen = c.rad('gCenter', [(0, '#C98A52'), (1, '#8F5A33')], .4, .35, .7)
    cx, cy = 60, 27
    b = ''
    for k in range(12):
        b += E(cx, cy - 12.5, 5.0, 9.0, g_pet, OUT, SWD, rot=(k * 30, cx, cy))
    b += C(cx, cy, 10.0, g_cen, OUT, SWA)
    for dx_, dy_, r_ in ((-3.6, -3.2, 1.4), (2.8, -4.2, 1.1), (3.8, 1.8, 1.3), (-1.2, 3.4, 1.1), (-4.6, 2.2, 0.9)):
        b += C(cx + dx_, cy + dy_, r_, '#E3B07A')
    return b, ''


HEART = ('M0 0C-2 -2 -9 -5 -8 -10.5C-7.5 -14.5 -2 -15.5 0 -11.5'
         'C2 -15.5 7.5 -14.5 8 -10.5C9 -5 2 -2 0 0Z')


def b_clover(c):
    g = c.lin('gClover', [(0, '#B5E58C'), (1, '#74BF52')])
    b = stem('M60 28C60 36 60 44 60 50')
    for a in (135, 225, 315, 45):
        inner = P(HEART, g, OUT, 2.3) + P('M0 -2.8L0 -10.5', 'none', VEIN, 1.3)
        b += G(inner, 'translate(60 24) rotate(%d) scale(1.15)' % a)
    return b, ''


PETAL = ('M0 0C-7 -2.5 -8.5 -9.5 -5 -13.5C-3.5 -15 -1.5 -13 0 -11.2'
         'C1.5 -13 3.5 -15 5 -13.5C8.5 -9.5 7 -2.5 0 0Z')


def b_sakura(c):
    g = c.lin('gSak', [(0, '#FF9DB8'), (1, '#FFD9E4')], 0, 1, 0, 0)
    cx, cy = 60, 26
    b = ''
    for k in range(5):
        b += G(P(PETAL, g, OUT, 2.4), 'translate(%s %s) rotate(%s) scale(1.45)' % (f(cx), f(cy), f(k * 72)))
    b += C(cx, cy, 4.4, '#FFD45E', OUT, 1.9)
    return b, ''


def b_mushroom(c):
    g = c.lin('gCap', [(0, '#FF8080'), (1, '#E4474B')])
    cap = 'M19 51C17 28 36 13 60 13C84 13 103 28 101 51C86 57 34 57 19 51Z'
    clip = c.clip('capclip', '<path d="%s"/>' % cap)
    dots = (C(44, 29, 6.4, WHITE) + C(73, 25, 6.8, WHITE) + C(91, 43, 4.6, WHITE) +
            C(29, 43, 4.2, WHITE) + C(58, 45, 3.4, WHITE))
    f_ = hat_shadow(c, cap)
    f_ += P(cap, g) + G(dots, extra='clip-path="%s"' % clip)
    f_ += P('M28 38C28.5 30 33 22 41 18', 'none', WHITE, 2.6, 'stroke-opacity=".5"')
    f_ += P(cap, 'none', OUT, SW)
    return '', f_


def b_acorn(c):
    g = c.lin('gAcorn', [(0, '#D9A06A'), (1, '#A8693C')])
    cap = 'M27 43C25 27 41 17 60 17C79 17 95 27 93 43C81 48 39 48 27 43Z'
    clip = c.clip('capclip', '<path d="%s"/>' % cap)
    hatch = ''
    for x0 in range(-10, 130, 8):
        hatch += 'M%d 10L%d 52M%d 52L%d 10' % (x0, x0 + 40, x0, x0 + 40)
    f_ = stem('M60 19C60 14 62 11 66 9', core=3.6, color='#A8693C')
    f_ += hat_shadow(c, cap, dy=2.8)
    f_ += P(cap, g) + G(P(hatch, 'none', '#8A5430', 1.3, 'stroke-opacity=".5"'), extra='clip-path="%s"' % clip)
    f_ += P('M33 36C34 29 39 24 46 21', 'none', WHITE, 2.6, 'stroke-opacity=".5"')
    f_ += P(cap, 'none', OUT, SW)
    return '', f_


def b_strawberry(c):
    g = c.lin('gBerry', [(0, '#FF8F95'), (1, '#E5454F')])
    body = 'M31 28C31 19 38 14.5 47 17C54 19 66 19 73 17C82 14.5 89 19 89 28C89 41 76 53 60 58C44 53 31 41 31 28Z'
    clip = c.clip('berryclip', '<path d="%s"/>' % body)
    seeds = ''
    for sx, sy, r in ((43, 35, 22), (51, 40, 10), (60, 36, 0), (69, 40, -10), (77, 35, -22),
                      (47.5, 29.5, 16), (72.5, 29.5, -16)):
        seeds += E(sx, sy, 1.5, 2.4, '#FFE7A0', rot=r)
    f_ = P(body, g) + G(seeds, extra='clip-path="%s"' % clip)
    f_ += P('M38 31C38.3 27 40.8 24 45 22.5', 'none', WHITE, 2.6, 'stroke-opacity=".55"')
    f_ += P(body, 'none', OUT, SW)
    cx, cy = 60, 21
    f_ += stem('M60 21C60 16.5 61.5 12.5 65 9.5', core=3.6)
    dark = (LEAF_D, LEAF)
    for flip in (False, True):
        f_ += leaf(cx, cy, 19, 7.2, -48, flip=flip, col=dark)
    for flip in (False, True):
        f_ += leaf(cx, cy, 26, 8.4, 15, flip=flip, col=dark)
    f_ += C(cx, cy, 3.8, LEAF_D, OUT, SWD)
    return f_, ''


def b_star(c):
    g = c.lin('gStar', [(0, '#FFEA8A'), (1, '#FFC93C')])
    b = stem('M60 50C60 45 61 40 60 30')
    b += leaf(60, 40, 16, 6.4, -28, flip=True)
    b += P(star_path(60, 20.5, 15, 7.6), g, OUT, SWA)
    b += C(54.6, 16.8, 1.7, WHITE, extra='fill-opacity=".85"')
    b += sparkle(89, 27, 8.5, SPARK_L) + sparkle(32, 22, 6.4, SPARK_L)
    return b, ''


def b_moon(c):
    g = c.lin('gNight', [(0, '#A9B5F8'), (1, '#7684E0')])
    gm = c.lin('gMoon', [(0, '#FFF3B0'), (1, '#FFD65A')])
    cap = 'M23 46C21 27 38 11 60 11C79 11 95 22 100 40C93 38 86 40 82 45Z'
    band = 'M22 44Q60 56 98 44'
    f_ = hat_shadow(c, band, dy=3.0, band=11.5)
    f_ += P(cap, g, OUT, SW)
    f_ += P(crescent_path(47, 28, 10, 8.2, 4.2, -20), gm, OUT, SWD)
    f_ += C(99, 42, 6, CREAM, OUT, SWA)
    f_ += P(band, 'none', OUT, 11.5)
    f_ += P(band, 'none', '#FFFBF2', 6.4)
    return '', f_


def b_drop(c):
    g = c.lin('gDrop', [(0, '#B4E4FF'), (1, '#5DB8F2')])
    b = leaf(60, 42, 30, 10, -28) + leaf(60, 42, 30, 10, -28, flip=True)
    drop = 'M60 5C60 5 44.5 21 44.5 28.5C44.5 37 51.4 43 60 43C68.6 43 75.5 37 75.5 28.5C75.5 21 60 5 60 5Z'
    f_ = P(drop, g, OUT, SWA)
    f_ += P('M50.8 29.5C50.8 34.2 53.6 38.2 58 39.4', 'none', WHITE, 2.6, 'stroke-opacity=".85"')
    f_ += E(52.4, 24.6, 1.5, 3.1, WHITE, rot=24, extra='fill-opacity=".85"')
    return b, f_


def b_cactus(c):
    g = c.lin('gCactus', [(0, '#A6E07F'), (1, '#68BC52')])
    gp = c.lin('gFlower', [(0, '#FFC4D6'), (1, '#FF98B6')])
    b = E(60, 30, 15.5, 13.5, g, OUT, SWA)
    b += P('M53 18.5C49 25 49 35 53 42', 'none', LEAF_D, 1.8, 'stroke-opacity=".7"')
    b += P('M67 18.5C71 25 71 35 67 42', 'none', LEAF_D, 1.8, 'stroke-opacity=".7"')
    b += P('M60 17V43', 'none', LEAF_D, 1.8, 'stroke-opacity=".7"')
    for (sx, sy) in ((56.5, 24), (63.5, 24), (56.5, 33), (63.5, 33), (51, 29), (69, 29)):
        b += P('M%s %sl2 -1.4' % (f(sx - 1), f(sy)), 'none', '#FFF7D6', 1.3)
    fx, fy = 60, 14.5
    for k in range(5):
        b += E(fx, fy - 4.6, 3.2, 4.2, gp, OUT, 1.8, rot=(k * 72, fx, fy))
    b += C(fx, fy, 2.5, '#FFD45E', OUT, 1.6)
    return b, ''


# ----------------------------------------------------------------------------
# the set (order chosen so neighbours differ in colour and silhouette)
# ----------------------------------------------------------------------------
AVATARS = [
    dict(id='sprout', name_ja='ふたば', bg='#CFE8FB', face='normal', build=b_sprout),
    dict(id='cactus', name_ja='サボテン', bg='#F8E4C8', face='happy', build=b_cactus),
    dict(id='star', name_ja='ほし', bg='#D6DEFA', face='wink', build=b_star),
    dict(id='mushroom', name_ja='きのこ', bg='#D4F1E0', face='normal', build=b_mushroom, gloss='hat'),
    dict(id='clover', name_ja='クローバー', bg='#FFE1D2', face='wink', build=b_clover),
    dict(id='moon', name_ja='つき', bg='#E2DBFA', face='sleep', build=b_moon, gloss='hat'),
    dict(id='tulip', name_ja='チューリップ', bg='#FFF2C2', face='happy', build=b_tulip),
    dict(id='sunflower', name_ja='ひまわり', bg='#EFDDF6', face='normal', build=b_sunflower),
    dict(id='acorn', name_ja='どんぐり', bg='#E6F2C6', face='normal', dx=3.5, look=1.5, build=b_acorn, gloss='hat'),
    dict(id='sakura', name_ja='さくら', bg='#C9EEEE', face='happy', build=b_sakura),
    dict(id='strawberry', name_ja='いちご', bg='#FFDCE6', face='happy', build=b_strawberry),
    dict(id='drop', name_ja='しずく', bg='#FFE4B8', face='normal', build=b_drop),
]


def build_svg(spec):
    c = Ctx(spec['id'])
    bg = c.rad('gBg', [(0, mix(spec['bg'], WHITE, .55)), (1, spec['bg'])], .5, .32, .75)
    head = c.lin('gHead', [(0, '#FFFBF2'), (.55, '#FFF1DC'), (1, '#F6D9B6')])
    behind, front = spec['build'](c)
    pot_svg = pot(c)
    ring = ('<circle cx="60" cy="60" r="59.2" fill="none" stroke="%s" stroke-width="1.6" stroke-opacity=".55"/>'
            % mix(spec['bg'], '#8B6B55', .28))
    body = ('<circle cx="60" cy="60" r="60" fill="%s"/>' % bg + ring + behind +
            P(HEAD_D, head, OUT, SW) + gloss(spec.get('gloss', 'std')) +
            face(spec['face'], spec.get('dx', 0.0), spec.get('look', 0.0)) + front + pot_svg + hands())
    clip_id = '%s_clip' % spec['id']
    defs = '<clipPath id="%s"><circle cx="60" cy="60" r="60"/></clipPath>' % clip_id + ''.join(c.defs)
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="120" height="120" viewBox="0 0 120 120">\n'
            '<defs>%s</defs>\n<g clip-path="url(#%s)">%s</g>\n</svg>\n' % (defs, clip_id, body))


# ----------------------------------------------------------------------------
# outputs
# ----------------------------------------------------------------------------
def write_text(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding='utf-8')


def jdump(obj):
    return json.dumps(obj, indent=2, ensure_ascii=False) + '\n'


def write_catalog(svgs):
    assert XC_DIR.name == 'AvatarAssets.xcassets' and XC_DIR.resolve().parent == ROOT.resolve()
    if XC_DIR.exists():
        shutil.rmtree(str(XC_DIR))
    XC_DIR.mkdir(parents=True)
    write_text(XC_DIR / 'Contents.json', jdump({'info': {'author': 'xcode', 'version': 1}}))
    for spec in AVATARS:
        name = 'avatar_%s' % spec['id']
        d = XC_DIR / (name + '.imageset')
        write_text(d / (name + '.svg'), svgs[spec['id']])
        write_text(d / 'Contents.json', jdump({
            'images': [{'filename': name + '.svg', 'idiom': 'universal'}],
            'info': {'author': 'xcode', 'version': 1},
            'properties': {'preserves-vector-representation': True, 'template-rendering-intent': 'original'},
        }))


FONT = '-apple-system,"Hiragino Sans","Hiragino Kaku Gothic ProN",sans-serif'


def html_sheet():
    cells = ''.join(
        '<div class="c"><img src="../svg/avatar_%s.svg" width="200" height="200">'
        '<div class="n">%s<span>%s</span></div></div>' % (s['id'], s['name_ja'], s['id']) for s in AVATARS)
    return ('<!doctype html><html><head><meta charset="utf-8"><style>'
            'html,body{margin:0;background:#fff}body{padding:20px;font-family:%s}'
            '.g{display:grid;grid-template-columns:repeat(4,200px);gap:22px 32px}'
            '.c{text-align:center}img{display:block}'
            '.n{font-size:15px;color:#4A3428;margin-top:7px;font-weight:600}'
            '.n span{font-weight:400;color:#9a8a80;margin-left:6px;font-size:12px}'
            '</style></head><body><div class="g">%s</div></body></html>' % (FONT, cells))


def html_small():
    def panel(bg, fg):
        rows = ''
        for size in (56, 44, 28):
            imgs = ''.join('<img src="../svg/avatar_%s.svg" width="%d" height="%d">' % (s['id'], size, size)
                           for s in AVATARS)
            rows += '<div class="r"><span class="l">%d</span>%s</div>' % (size, imgs)
        return '<div class="p" style="background:%s;color:%s">%s</div>' % (bg, fg, rows)

    return ('<!doctype html><html><head><meta charset="utf-8"><style>'
            'html,body{margin:0;background:#1C1C1E}body{font-family:%s}'
            '.p{padding:12px 14px}.r{display:flex;align-items:center;gap:8px;margin:6px 0}'
            '.l{width:22px;font-size:11px;opacity:.55}img{display:block;flex:none}'
            '</style></head><body>%s%s</body></html>' % (FONT, panel('#FFFFFF', '#4A3428'), panel('#1C1C1E', '#E5E5E5')))


def png_size(path):
    with open(str(path), 'rb') as fh:
        head = fh.read(24)
    return int.from_bytes(head[16:20], 'big'), int.from_bytes(head[20:24], 'big')


def shoot(html_path, png_path, w, h, scale=1):
    prof = tempfile.mkdtemp(prefix='lien_avatar_chrome_')
    try:
        subprocess.run([CHROME, '--headless=new', '--disable-gpu', '--hide-scrollbars',
                        '--user-data-dir=' + prof, '--default-background-color=FFFFFFFF',
                        '--window-size=%d,%d' % (w, h), '--force-device-scale-factor=%d' % scale,
                        '--screenshot=' + str(png_path), html_path.resolve().as_uri()],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120)
    finally:
        if prof.startswith(tempfile.gettempdir()) and 'lien_avatar_chrome_' in prof:
            shutil.rmtree(prof, ignore_errors=True)
    print('  %s  %dx%d' % (png_path.name, png_size(png_path)[0], png_size(png_path)[1]))


def main():
    svgs = {s['id']: build_svg(s) for s in AVATARS}
    SVG_DIR.mkdir(parents=True, exist_ok=True)
    for p in SVG_DIR.glob('avatar_*.svg'):
        p.unlink()
    for s in AVATARS:
        write_text(SVG_DIR / ('avatar_%s.svg' % s['id']), svgs[s['id']])
    write_text(ROOT / 'avatars.json', jdump([{'id': s['id'], 'name_ja': s['name_ja']} for s in AVATARS]))
    write_catalog(svgs)
    print('wrote %d svgs, avatars.json, AvatarAssets.xcassets' % len(AVATARS))
    if '--no-preview' in sys.argv:
        return
    if not Path(CHROME).exists():
        print('Chrome not found; skipped previews')
        return
    write_text(PREV_DIR / 'sheet.html', html_sheet())
    write_text(PREV_DIR / 'sheet_small.html', html_small())
    shoot(PREV_DIR / 'sheet.html', PREV_DIR / 'sheet.png', 940, 790, 1)
    shoot(PREV_DIR / 'sheet_small.html', PREV_DIR / 'sheet_small.png', 860, 356, 2)


if __name__ == '__main__':
    main()
