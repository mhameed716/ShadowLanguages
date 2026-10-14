#!/usr/bin/env python3
"""Generate the Android launcher icons and store assets from the master artwork.

Usage:
    python3 -m pip install pillow numpy
    python3 tool/gen_icons.py

The master artwork (assets/branding/app_icon_source.png) is centred on a light
canvas: the script isolates the dark icon, makes the surrounding canvas
transparent and writes every density the Android launcher needs.
"""
from __future__ import annotations

import os
from PIL import Image
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "assets", "branding", "app_icon_source.png")
RES = os.path.join(ROOT, "android", "app", "src", "main", "res")
BRANDING = os.path.join(ROOT, "assets", "branding")

MIPMAPS = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}
BACKGROUND = (13, 13, 13, 255)  # #0D0D0D carbon black


def load_icon() -> Image.Image:
    """Crop the centred icon out of the master artwork and return it on transparent ground."""
    im = Image.open(SRC).convert("RGB")
    w, h = im.size
    side = min(w, h)
    left, top = (w - side) // 2, (h - side) // 2
    im = im.crop((left, top, left + side, top + side))

    a = np.asarray(im).astype(np.int16)
    # background colour = median of the four corners
    corners = np.vstack([
        a[:40, :40].reshape(-1, 3), a[:40, -40:].reshape(-1, 3),
        a[-40:, :40].reshape(-1, 3), a[-40:, -40:].reshape(-1, 3),
    ])
    bg = np.median(corners, axis=0)
    bg_luma = float(0.299 * bg[0] + 0.587 * bg[1] + 0.114 * bg[2])

    luma = 0.299 * a[:, :, 0] + 0.587 * a[:, :, 1] + 0.114 * a[:, :, 2]
    dist = np.abs(luma - bg_luma)
    # keep a soft edge so the neon glow survives, hard-clip the flat background
    alpha = np.clip((dist - 6.0) / 26.0, 0.0, 1.0) ** 0.85
    alpha[dist < 4] = 0.0
    rgba = np.dstack([a, (alpha * 255).astype(np.uint8)]).astype(np.uint8)
    out = Image.fromarray(rgba, "RGBA")

    bbox = out.getbbox()
    if bbox:
        out = out.crop(bbox)
    # make it square again (pad with transparency) so scaling keeps the aspect
    w, h = out.size
    side = max(w, h)
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.paste(out, ((side - w) // 2, (side - h) // 2))
    return canvas


def write_square(icon: Image.Image, size: int, path: str, background=BACKGROUND) -> None:
    canvas = Image.new("RGBA", (size, size), background)
    body = icon.resize((size, size), Image.LANCZOS)
    canvas.alpha_composite(body)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    canvas.convert("RGB").save(path)


def write_foreground(icon: Image.Image, size: int, path: str) -> None:
    """Adaptive icon foreground: the artwork occupies the middle 66% (safe zone)."""
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    inner = int(size * 66 / 108)
    body = icon.resize((inner, inner), Image.LANCZOS)
    canvas.alpha_composite(body, ((size - inner) // 2, (size - inner) // 2))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    canvas.save(path)


def main() -> None:
    icon = load_icon()
    for folder, size in MIPMAPS.items():
        write_square(icon, size, os.path.join(RES, folder, "ic_launcher.png"))
        write_square(icon, size, os.path.join(RES, folder, "ic_launcher_round.png"))
        write_foreground(icon, size, os.path.join(RES, folder, "ic_launcher_foreground.png"))
    write_square(icon, 512, os.path.join(BRANDING, "app_icon_512.png"))
    write_square(icon, 1024, os.path.join(BRANDING, "app_icon_1024.png"))
    write_square(icon, 1024, os.path.join(BRANDING, "app_icon_1024_black.png"))
    icon.resize((256, 256), Image.LANCZOS).save(os.path.join(BRANDING, "app_icon_transparent_256.png"))
    print("icons written")


if __name__ == "__main__":
    main()
