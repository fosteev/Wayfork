#!/usr/bin/env python3
"""Renders the Windows tray icons of the Flutter app.

The glyph is the fork-in-the-road mark of the approved prototype
(docs/design/prototype/windows.html, the tray header SVG) drawn on the same
18x18 grid. `docs/design/02-ux.md` ("Menu bar icon") defines the variants:
off = outline, on = filled, degraded = filled with the failing branch set
apart, error = outline with an exclamation mark; `pulse` is the dimmed twin of
`on` that the tray controller alternates with it while starting or stopping.
Windows delta: the macOS "one branch hollow" is a ring of mud at 16 px (the
notification area's size at 100 % DPI), so the branch is dimmed instead.

Two colour sets are produced because a Windows notification area follows the
system theme: `light/` carries a dark glyph for a light taskbar, `dark/` a
white one. Each `.ico` holds the sizes `LoadImage(..., SM_CXSMICON)` may ask
for (16-48 px, 100-300 % DPI) as uncompressed 32-bit BGRA bitmaps, the only
format `LoadImage` reads from a file on every Windows version.

Usage: python3 scripts/make-win-tray-icons.py [output-dir]
       (default: WayforkWindows/app/assets/tray)
"""

from __future__ import annotations

import math
import os
import struct
import sys

GRID = 18.0  # the SVG viewBox the geometry is written in
SIZES = (16, 20, 24, 32, 40, 48)
SUPERSAMPLE = 4

# Geometry on the 18x18 grid: the stem, the two branches and the three ends.
STEM = ((9.0, 16.0), (9.0, 9.5))
BRANCH_LEFT = ((9.0, 9.5), (4.0, 3.5))
BRANCH_RIGHT = ((9.0, 9.5), (14.0, 3.5))
DOT_LEFT = (4.0, 3.5)
DOT_RIGHT = (14.0, 3.5)
DOT_FOOT = (9.0, 16.0)
DOT_RADIUS = 1.9
STROKE_FILLED = 2.2
STROKE_OUTLINE = 1.6
DIM_ALPHA = 0.4

# The exclamation of the `error` variant, right of the stem.
BANG_BAR = ((15.2, 9.6), (15.2, 13.4))
BANG_DOT = (15.2, 15.8)
BANG_STROKE = 1.9
BANG_DOT_RADIUS = 1.05

COLOURS = {'light': (0x1A, 0x1A, 0x1A), 'dark': (0xFF, 0xFF, 0xFF)}
PULSE_ALPHA = 0.45


def _segment_distance(px, py, a, b):
    ax, ay = a
    bx, by = b
    dx, dy = bx - ax, by - ay
    length = dx * dx + dy * dy
    t = 0.0 if length == 0 else ((px - ax) * dx + (py - ay) * dy) / length
    t = max(0.0, min(1.0, t))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


class Shape:
    """One primitive as a signed distance test on the 18x18 grid."""

    def __init__(self, kind, *, a=None, b=None, centre=None, radius=0.0, width=0.0):
        self.kind = kind
        self.a = a
        self.b = b
        self.centre = centre
        self.radius = radius
        self.width = width

    def covers(self, px, py):
        if self.kind == 'capsule':
            return _segment_distance(px, py, self.a, self.b) <= self.width / 2
        if self.kind == 'disc':
            return math.hypot(px - self.centre[0], py - self.centre[1]) <= self.radius
        # ring
        distance = math.hypot(px - self.centre[0], py - self.centre[1])
        return abs(distance - self.radius) <= self.width / 2


def capsule(a, b, width):
    return Shape('capsule', a=a, b=b, width=width)


def disc(centre, radius):
    return Shape('disc', centre=centre, radius=radius)


def ring(centre, radius, width):
    return Shape('ring', centre=centre, radius=radius, width=width)


def variant_shapes(name):
    """The layers of one icon variant: (primitives, opacity)."""
    filled = [
        capsule(*STEM, STROKE_FILLED),
        capsule(*BRANCH_LEFT, STROKE_FILLED),
        capsule(*BRANCH_RIGHT, STROKE_FILLED),
        disc(DOT_LEFT, DOT_RADIUS),
        disc(DOT_RIGHT, DOT_RADIUS),
        disc(DOT_FOOT, DOT_RADIUS),
    ]
    outline = [
        capsule(*STEM, STROKE_OUTLINE),
        capsule(*BRANCH_LEFT, STROKE_OUTLINE),
        capsule(*BRANCH_RIGHT, STROKE_OUTLINE),
    ]
    if name in ('on', 'pulse'):
        return [(filled, 1.0)]
    if name == 'degraded':
        # The right branch and its end are the failing one.
        return [
            (
                [
                    capsule(*STEM, STROKE_FILLED),
                    capsule(*BRANCH_LEFT, STROKE_FILLED),
                    disc(DOT_LEFT, DOT_RADIUS),
                    disc(DOT_FOOT, DOT_RADIUS),
                ],
                1.0,
            ),
            (
                [
                    capsule(*BRANCH_RIGHT, STROKE_FILLED),
                    disc(DOT_RIGHT, DOT_RADIUS),
                ],
                DIM_ALPHA,
            ),
        ]
    if name == 'off':
        return [(outline, 1.0)]
    if name == 'error':
        return [
            (outline, 1.0),
            ([capsule(*BANG_BAR, BANG_STROKE), disc(BANG_DOT, BANG_DOT_RADIUS)], 1.0),
        ]
    raise ValueError(f'unknown variant {name}')


def render(layers, size, colour, alpha_scale):
    """Anti-aliased BGRA rows, top-down, straight (non-premultiplied) alpha."""
    blue, green, red = colour[2], colour[1], colour[0]
    step = GRID / (size * SUPERSAMPLE)
    rows = []
    for y in range(size):
        row = bytearray()
        for x in range(size):
            alpha = 0.0
            for shapes, opacity in layers:
                hits = 0
                for sy in range(SUPERSAMPLE):
                    py = (y * SUPERSAMPLE + sy + 0.5) * step
                    for sx in range(SUPERSAMPLE):
                        px = (x * SUPERSAMPLE + sx + 0.5) * step
                        if any(shape.covers(px, py) for shape in shapes):
                            hits += 1
                coverage = hits / (SUPERSAMPLE * SUPERSAMPLE)
                alpha = max(alpha, coverage * opacity)
            row += bytes((blue, green, red, int(round(alpha * alpha_scale * 255))))
        rows.append(bytes(row))
    return rows


def bitmap_entry(rows, size):
    """One ICO image: BITMAPINFOHEADER + bottom-up BGRA + the AND mask."""
    header = struct.pack(
        '<IiiHHIIiiII', 40, size, size * 2, 1, 32, 0, size * size * 4, 0, 0, 0, 0
    )
    pixels = b''.join(reversed(rows))
    # Fully transparent everywhere in the mask: the alpha channel is the mask
    # on 32-bit icons, but the structure still has to be present.
    mask_stride = ((size + 31) // 32) * 4
    mask = bytes(mask_stride * size)
    return header + pixels + mask


def write_ico(path, shapes, colour, alpha_scale):
    images = [
        bitmap_entry(render(shapes, size, colour, alpha_scale), size)
        for size in SIZES
    ]
    offset = 6 + 16 * len(images)
    out = bytearray(struct.pack('<HHH', 0, 1, len(images)))
    for size, image in zip(SIZES, images):
        out += struct.pack(
            '<BBBBHHII',
            0 if size >= 256 else size,
            0 if size >= 256 else size,
            0,
            0,
            1,
            32,
            len(image),
            offset,
        )
        offset += len(image)
    for image in images:
        out += image
    with open(path, 'wb') as handle:
        handle.write(bytes(out))


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    target = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        root, 'WayforkWindows', 'app', 'assets', 'tray'
    )
    for theme, colour in COLOURS.items():
        directory = os.path.join(target, theme)
        os.makedirs(directory, exist_ok=True)
        for variant in ('off', 'on', 'pulse', 'degraded', 'error'):
            alpha = PULSE_ALPHA if variant == 'pulse' else 1.0
            path = os.path.join(directory, f'{variant}.ico')
            write_ico(path, variant_shapes(variant), colour, alpha)
            print(f'{os.path.relpath(path, root)}  {os.path.getsize(path)} bytes')


if __name__ == '__main__':
    main()
