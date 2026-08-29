#!/usr/bin/env python3
"""Renders the Windows application icon of the Flutter app.

The same fork-in-the-road mark as the tray icons (scripts/make-win-tray-icons.py,
`docs/design/02-ux.md` "Menu bar icon"), but as an *app* icon rather than a
notification-area glyph: white on the accent blue of the approved prototype
(`docs/design/prototype/windows.html`), inside a rounded square, so it reads on
both the light and the dark Start menu — a monochrome glyph disappears into one
of them. The geometry and the rasteriser are imported from the tray script; only
the composition is new.

The `.ico` holds 16-256 px as uncompressed 32-bit BGRA bitmaps: `Runner.rc`
embeds it in `wayfork.exe`, which is where the taskbar, the Start menu, the
shortcut the MSI creates and `ARPPRODUCTICON` all read the icon from.

Usage: python3 scripts/make-win-app-icon.py [output.ico]
       (default: WayforkWindows/app/windows/runner/resources/app_icon.ico)
"""

from __future__ import annotations

import importlib.util
import os
import struct
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    'wayfork_tray_icons', os.path.join(_HERE, 'make-win-tray-icons.py')
)
tray = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(tray)

SIZES = (16, 20, 24, 32, 48, 64, 128, 256)
SUPERSAMPLE = 3

ACCENT = (0x0A, 0x60, 0xFF)  # the prototype's primary blue
GLYPH = (0xFF, 0xFF, 0xFF)

# Fractions of the icon's edge: the art keeps a margin so the rounded square is
# not clipped by the platform, and the glyph sits inside that square.
MARGIN = 0.055
CORNER = 0.22
GLYPH_INSET = 0.20


def rounded_square_coverage(px, py, size):
    """1.0 inside the rounded square, 0.0 outside (sampled, not analytic)."""
    margin = size * MARGIN
    radius = size * CORNER
    left, top = margin, margin
    right, bottom = size - margin, size - margin
    inner_left, inner_right = left + radius, right - radius
    inner_top, inner_bottom = top + radius, bottom - radius
    dx = max(inner_left - px, 0.0, px - inner_right)
    dy = max(inner_top - py, 0.0, py - inner_bottom)
    return 1.0 if dx * dx + dy * dy <= radius * radius else 0.0


def glyph_shapes():
    """The filled `on` mark: the app icon shows Wayfork, not a state."""
    layers = tray.variant_shapes('on')
    return [shape for shapes, _ in layers for shape in shapes]


def render(size):
    """Anti-aliased BGRA rows, top-down, straight alpha."""
    shapes = glyph_shapes()
    inset = size * GLYPH_INSET
    span = size - 2 * inset
    scale = tray.GRID / span
    rows = []
    for y in range(size):
        row = bytearray()
        for x in range(size):
            background = 0.0
            mark = 0.0
            for sy in range(SUPERSAMPLE):
                py = y + (sy + 0.5) / SUPERSAMPLE
                for sx in range(SUPERSAMPLE):
                    px = x + (sx + 0.5) / SUPERSAMPLE
                    covered = rounded_square_coverage(px, py, size)
                    background += covered
                    if not covered:
                        continue
                    gx = (px - inset) * scale
                    gy = (py - inset) * scale
                    if any(shape.covers(gx, gy) for shape in shapes):
                        mark += 1.0
            samples = SUPERSAMPLE * SUPERSAMPLE
            alpha = background / samples
            ink = (mark / background) if background else 0.0
            colour = tuple(
                int(round(ACCENT[i] * (1.0 - ink) + GLYPH[i] * ink))
                for i in range(3)
            )
            row += bytes(
                (colour[2], colour[1], colour[0], int(round(alpha * 255)))
            )
        rows.append(bytes(row))
    return rows


def write_ico(path, sizes):
    images = [tray.bitmap_entry(render(size), size) for size in sizes]
    offset = 6 + 16 * len(images)
    out = bytearray(struct.pack('<HHH', 0, 1, len(images)))
    for size, image in zip(sizes, images):
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
    root = os.path.dirname(_HERE)
    target = (
        sys.argv[1]
        if len(sys.argv) > 1
        else os.path.join(
            root,
            'WayforkWindows',
            'app',
            'windows',
            'runner',
            'resources',
            'app_icon.ico',
        )
    )
    write_ico(target, SIZES)
    print(f'{os.path.relpath(target, root)}  {os.path.getsize(target)} bytes')


if __name__ == '__main__':
    main()
