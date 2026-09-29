#!/usr/bin/env python3
"""Generate Resources/AppIcon.png (1024x1024, RGBA) for SuperNotch.

Pure Python 3 standard library (zlib + struct); no Pillow, no numpy. Deterministic output.

Design: macOS-style rounded square ("squircle") with a glassy violet -> blue -> teal gradient, a soft sheen,
and a black "notch pill" hanging from the top edge with three small traffic-light dots (the Claude Code
states: red = needs you, yellow = working, green = done).

Usage:
    python3 Scripts/make_icon.py [output.png]      # default: Resources/AppIcon.png next to this script's repo

Scripts/package_app.sh turns the PNG into AppIcon.icns with sips + iconutil.
"""

from __future__ import annotations

import math
import os
import struct
import sys
import zlib

SIZE = 1024
CENTER = SIZE / 2.0

# macOS icon grid: the artwork body is 824 x 824 inside the 1024 canvas (100 px transparent margin for the shadow).
BODY_HALF = 412.0
BODY_EXP = 5.0  # superellipse exponent; ~5 approximates Apple's continuous corner

# Notch pill (anchored above the top edge and clipped by the body, so it is flush with the icon's top).
PILL_CX = CENTER
PILL_HALF_W = 250.0
PILL_TOP = 60.0
PILL_BOTTOM = 290.0
PILL_R_BOTTOM = 96.0

# Traffic-light dots inside the pill.
DOT_CY = 182.0
DOT_R = 27.0
DOT_SPACING = 88.0
DOTS = (
    (255, 92, 84),  # red   - needs you
    (255, 196, 46),  # yellow - working
    (52, 208, 120),  # green - done
)

# "Now playing" glass card under the notch (echoes the expanded notch: cover, title, progress).
CARD = (CENTER, 566.0, 300.0, 116.0, 58.0)  # cx, cy, half width, half height, corner radius
CARD_ELEMENTS = (
    # (cx, cy, half w, half h, radius, alpha)
    (296.0, 566.0, 62.0, 62.0, 26.0, 0.34),  # album cover
    (532.0, 536.0, 128.0, 13.0, 6.5, 0.80),  # title
    (496.0, 572.0, 92.0, 10.0, 5.0, 0.46),  # artist
    (594.0, 616.0, 200.0, 6.0, 3.0, 0.26),  # progress track
    (494.0, 616.0, 100.0, 6.0, 3.0, 0.90),  # progress fill
)

# Gradient stops (t along the top-left -> bottom-right diagonal).
STOPS = (
    (0.00, (146, 120, 255)),
    (0.50, (66, 122, 255)),
    (1.00, (28, 206, 196)),
)


def clamp01(v: float) -> float:
    return 0.0 if v < 0.0 else (1.0 if v > 1.0 else v)


def smoothstep(e0: float, e1: float, x: float) -> float:
    t = clamp01((x - e0) / (e1 - e0))
    return t * t * (3.0 - 2.0 * t)


def body_sdf(x: float, y: float) -> float:
    """Approximate signed distance (px, negative inside) to the superellipse body."""
    u = abs(x - CENTER) / BODY_HALF
    v = abs(y - CENTER) / BODY_HALF
    n = BODY_EXP
    un1 = u ** (n - 1.0)
    vn1 = v ** (n - 1.0)
    f = un1 * u + vn1 * v
    grad = (n / BODY_HALF) * math.sqrt(un1 * un1 + vn1 * vn1)
    if grad < 1e-9:
        return -BODY_HALF
    return (f - 1.0) / grad


def pill_sdf(x: float, y: float, dy: float = 0.0) -> float:
    """Signed distance to the notch pill (square top corners, rounded bottom corners)."""
    cy = (PILL_TOP + PILL_BOTTOM) / 2.0 + dy
    hh = (PILL_BOTTOM - PILL_TOP) / 2.0
    px = abs(x - PILL_CX)
    py = y - cy
    r = PILL_R_BOTTOM if py > 0 else 0.0
    qx = px - (PILL_HALF_W - r)
    qy = abs(py) - (hh - r)
    outside = math.hypot(max(qx, 0.0), max(qy, 0.0))
    inside = min(max(qx, qy), 0.0)
    return outside + inside - r


def rr_sdf(x: float, y: float, cx: float, cy: float, hw: float, hh: float, r: float) -> float:
    """Signed distance to a rounded rectangle centred at (cx, cy) with half sizes hw x hh and corner radius r."""
    qx = abs(x - cx) - (hw - r)
    qy = abs(y - cy) - (hh - r)
    return math.hypot(max(qx, 0.0), max(qy, 0.0)) + min(max(qx, qy), 0.0) - r


def gradient(t: float) -> tuple[float, float, float]:
    t = clamp01(t)
    for (t0, c0), (t1, c1) in zip(STOPS, STOPS[1:]):
        if t <= t1:
            k = (t - t0) / (t1 - t0)
            return (c0[0] + (c1[0] - c0[0]) * k, c0[1] + (c1[1] - c0[1]) * k, c0[2] + (c1[2] - c0[2]) * k)
    return tuple(float(c) for c in STOPS[-1][1])  # type: ignore[return-value]


def render() -> bytearray:
    raw = bytearray()
    dot_xs = [PILL_CX + (i - 1) * DOT_SPACING for i in range(3)]

    for py in range(SIZE):
        y = py + 0.5
        row = bytearray(1 + SIZE * 4)  # filter byte 0 + RGBA
        for px in range(SIZE):
            x = px + 0.5

            # Accumulators: premultiplied colour + alpha ("over" compositing, back to front).
            ar = ag = ab = aa = 0.0

            d_body = body_sdf(x, y)

            # 1. Icon drop shadow (soft, offset downwards), only outside/near the body.
            if d_body > -30.0:
                d_sh = body_sdf(x, y - 16.0)
                if d_sh < 34.0:
                    sh = 0.34 * (1.0 - smoothstep(-6.0, 34.0, d_sh))
                    ar, ag, ab, aa = 0.0, 0.0, 0.0, sh

            cov = clamp01(0.5 - d_body)
            if cov > 0.0:
                # 2. Body gradient.
                t = ((x - 100.0) + (y - 100.0)) / (2.0 * 824.0)
                r, g, b = gradient(t)

                # Big soft highlight at the top-left, subtle depth darkening at the bottom.
                hl = math.hypot(x - 300.0, y - 210.0)
                k = 0.30 * (1.0 - smoothstep(0.0, 620.0, hl))
                r += (255.0 - r) * k
                g += (255.0 - g) * k
                b += (255.0 - b) * k
                dark = 0.16 * smoothstep(0.45, 1.0, (y - 100.0) / 824.0)
                r *= 1.0 - dark
                g *= 1.0 - dark
                b *= 1.0 - dark

                # Glass sheen: a lighter cap bounded by a large circle arc.
                sheen_d = math.hypot(x - CENTER, y - (100.0 - 620.0)) - 1010.0  # < 0 inside the cap
                sheen = 0.11 * (1.0 - smoothstep(-40.0, 40.0, sheen_d))
                r += (255.0 - r) * sheen
                g += (255.0 - g) * sheen
                b += (255.0 - b) * sheen

                # Inner rim light: bright at the top edge, faint at the bottom.
                if d_body > -7.0:
                    rim_k = smoothstep(-7.0, -0.5, d_body)  # 0 inside .. 1 at the edge
                    rim = rim_k * (0.10 + 0.32 * (1.0 - (y - 100.0) / 824.0))
                    r += (255.0 - r) * rim
                    g += (255.0 - g) * rim
                    b += (255.0 - b) * rim


                # 2b. Glass card: soft shadow, translucent fill, rim light and a few "now playing" details.
                ccx, ccy, chw, chh, cr_ = CARD
                d_card = rr_sdf(x, y, ccx, ccy, chw, chh, cr_)
                if d_card < 52.0:
                    cs = 0.20 * (1.0 - smoothstep(-4.0, 34.0, rr_sdf(x, y, ccx, ccy + 14.0, chw, chh, cr_)))
                    r *= 1.0 - cs
                    g *= 1.0 - cs
                    b *= 1.0 - cs
                    cc = clamp01(0.5 - d_card)
                    if cc > 0.0:
                        vt = 1.0 - clamp01((y - (ccy - chh)) / (2.0 * chh))
                        fill = 0.13 + 0.10 * vt
                        if d_card > -3.0:
                            fill += smoothstep(-3.0, -0.5, d_card) * (0.10 + 0.22 * vt)
                        fill *= cc
                        r += (255.0 - r) * fill
                        g += (255.0 - g) * fill
                        b += (255.0 - b) * fill
                        # Album cover, title, artist, progress track and progress fill.
                        for ex, ey, ehw, ehh, er, ea in CARD_ELEMENTS:
                            ec = clamp01(0.5 - rr_sdf(x, y, ex, ey, ehw, ehh, er)) * ea
                            if ec > 0.0:
                                r += (255.0 - r) * ec
                                g += (255.0 - g) * ec
                                b += (255.0 - b) * ec

                # 3. Pill shadow (cast on the gradient, clipped to the body).
                d_ps = pill_sdf(x, y, 18.0)
                if d_ps < 40.0:
                    ps = 0.42 * (1.0 - smoothstep(-4.0, 40.0, d_ps))
                    r *= 1.0 - ps
                    g *= 1.0 - ps
                    b *= 1.0 - ps

                # 4. The notch pill itself.
                d_pill = pill_sdf(x, y)
                pc = clamp01(0.5 - d_pill)
                if pc > 0.0:
                    # Near-black with a very faint vertical lift so it reads as glass, not a hole.
                    base = 6.0 + 10.0 * clamp01((y - PILL_TOP) / (PILL_BOTTOM - PILL_TOP))
                    pr = pg = base
                    pb = base + 3.0
                    # Thin bottom rim highlight inside the pill.
                    if d_pill > -4.0:
                        rk = smoothstep(-4.0, -0.5, d_pill) * 0.22 * smoothstep(PILL_TOP + 90.0, PILL_BOTTOM, y)
                        pr += (255.0 - pr) * rk
                        pg += (255.0 - pg) * rk
                        pb += (255.0 - pb) * rk
                    # Traffic-light dots.
                    for dx, (cr, cg, cb) in zip(dot_xs, DOTS):
                        dd = math.hypot(x - dx, y - DOT_CY)
                        if dd < DOT_R + 46.0:
                            glow = 0.30 * (1.0 - smoothstep(DOT_R - 4.0, DOT_R + 46.0, dd))
                            pr += (cr - pr) * glow
                            pg += (cg - pg) * glow
                            pb += (cb - pb) * glow
                            dc = clamp01(DOT_R + 0.5 - dd)
                            if dc > 0.0:
                                # Slight radial shading + specular highlight.
                                shade = 1.0 - 0.22 * smoothstep(0.0, DOT_R, dd)
                                spec = 0.45 * (1.0 - smoothstep(0.0, DOT_R * 0.75, math.hypot(x - dx + 8.0, y - DOT_CY + 9.0)))
                                dr = min(255.0, cr * shade + (255.0 - cr) * spec)
                                dg = min(255.0, cg * shade + (255.0 - cg) * spec)
                                db = min(255.0, cb * shade + (255.0 - cb) * spec)
                                pr += (dr - pr) * dc
                                pg += (dg - pg) * dc
                                pb += (db - pb) * dc
                    r += (pr - r) * pc
                    g += (pg - g) * pc
                    b += (pb - b) * pc

                # Composite the body over the shadow.
                inv = 1.0 - cov
                ar = r * cov + ar * inv
                ag = g * cov + ag * inv
                ab = b * cov + ab * inv
                aa = cov + aa * inv

            if aa <= 0.0:
                continue  # fully transparent pixel: row already zeroed

            # Un-premultiply and dither (breaks up 8-bit gradient banding deterministically).
            noise = (((px * 73856093) ^ (py * 19349663)) & 255) / 255.0 - 0.5
            base_i = 1 + px * 4
            row[base_i] = int(min(255.0, max(0.0, ar / aa + noise)) + 0.5)
            row[base_i + 1] = int(min(255.0, max(0.0, ag / aa + noise)) + 0.5)
            row[base_i + 2] = int(min(255.0, max(0.0, ab / aa + noise)) + 0.5)
            row[base_i + 3] = int(min(255.0, aa * 255.0) + 0.5)
        raw += row
    return raw


def write_png(path: str, raw: bytes) -> None:
    def chunk(tag: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0)  # 8-bit RGBA, no interlace
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "wb") as fh:
        fh.write(png)


def main() -> int:
    default_out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Resources", "AppIcon.png")
    out = os.path.normpath(sys.argv[1] if len(sys.argv) > 1 else default_out)
    print(f"Rendering {SIZE}x{SIZE} icon ...", file=sys.stderr)
    write_png(out, render())
    print(f"Wrote {out} ({os.path.getsize(out)} bytes)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
