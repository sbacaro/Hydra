#!/usr/bin/env python3
"""Single source of truth for every Hydra icon.

The Hydra mark — a white waveform on an Apple "Space Black" gradient — is defined
exactly once here, and this script renders EVERY icon asset the project ships from
that one definition:

  • Media.xcassets/AppIcon.appiconset                       — the app icon
  • Sources/hydra-plugin-host/Assets.xcassets/AppIcon...    — the VST host helper
  • Backplane/HydraIcon.iconset + Backplane/Driver/Hydra.icns — the audio driver /
    the soundcard + bridge devices macOS shows in Audio MIDI Setup
  • docs/assets/hydra-icon.png, hydra-icon-180.png          — the website
  • Branding/HydraIcon-1024.png                             — canonical master PNG

Change the design in ONE place (the `render()` function below), then run:

    python3 Scripts/generate_icons.py

Everything regenerates consistently. (The in-app SwiftUI marks — menu-bar glyph,
toolbar brand mark — are drawn live by Sources/HydraApp/IconPack.swift, which
mirrors this same geometry. Keep the two in step if you change the wave.)

Requires Pillow:  pip install pillow
"""

from PIL import Image, ImageDraw, ImageFilter
import math
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# ── The mark, defined once ──────────────────────────────────────────────────
# Apple "Space Black": deep near-black charcoal with a faint warm undertone,
# lighter at the top, darker at the bottom. White 2.5-cycle waveform on top.
GRAD_TOP = (54, 52, 50)
GRAD_BOT = (20, 19, 18)


def _lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def render(S):
    """Render the Hydra mark at resolution S×S (RGBA, transparent corners)."""
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    margin = int(S * 0.085)
    rect = [margin, margin, S - margin, S - margin]
    radius = int((S - 2 * margin) * 0.225)

    # Space Black gradient, clipped to the rounded-rect tile.
    grad = Image.new("RGB", (S, S), GRAD_BOT)
    gd = ImageDraw.Draw(grad)
    for y in range(S):
        gd.line([(0, y), (S, y)], fill=_lerp(GRAD_TOP, GRAD_BOT, (y / S) ** 1.08))
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle(rect, radius=radius, fill=255)
    img.paste(grad, (0, 0), mask)

    # Subtle top sheen (restrained, premium).
    sheen = Image.new("L", (S, S), 0)
    ImageDraw.Draw(sheen).ellipse(
        [margin, margin - int(S * 0.24), S - margin, int(S * 0.44)], fill=55)
    sheen = sheen.filter(ImageFilter.GaussianBlur(S * 0.055))
    sheen = Image.composite(sheen, Image.new("L", (S, S), 0), mask)
    img = Image.alpha_composite(
        img, Image.merge("RGBA", (Image.new("L", (S, S), 255),) * 3 + (sheen,)))

    # Inner top hairline highlight.
    ImageDraw.Draw(img).rounded_rectangle(
        rect, radius=radius, outline=(255, 255, 255, 26), width=max(1, int(S * 0.0035)))

    # White waveform with a soft depth shadow.
    cx, cy = S // 2, S // 2
    w = int(S * 0.58)
    x0, x1 = cx - w // 2, cx + w // 2
    amp = S * 0.21

    def yy(u):
        env = 0.30 + 0.70 * (math.sin(math.pi * u) ** 0.55)
        return cy - amp * env * math.sin(2 * math.pi * 2.5 * u)

    N = 2600
    r = max(1, int(S * 0.052)) // 2
    stroke = Image.new("L", (S, S), 0)
    st = ImageDraw.Draw(stroke)
    for i in range(N + 1):
        u = i / N
        x = x0 + (x1 - x0) * u
        y = yy(u)
        st.ellipse([x - r, y - r, x + r, y + r], fill=255)

    shadow = stroke.filter(ImageFilter.GaussianBlur(S * 0.012))
    sh = Image.composite(Image.new("RGBA", (S, S), (0, 0, 0, 255)),
                         Image.new("RGBA", (S, S), (0, 0, 0, 0)),
                         shadow.point(lambda v: int(v * 0.4)))
    img = Image.alpha_composite(img, sh)
    white = Image.composite(Image.new("RGBA", (S, S), (255, 255, 255, 255)),
                            Image.new("RGBA", (S, S), (0, 0, 0, 0)), stroke)
    img = Image.alpha_composite(img, white)
    return img


# ── Targets ─────────────────────────────────────────────────────────────────
APP_ICONSET = "Media.xcassets/AppIcon.appiconset"
APP_FILES = [
    ("icon_16x16@1x.png", 16),   ("icon_16x16@2x.png", 32),
    ("icon_32x32@1x.png", 32),   ("icon_32x32@2x.png", 64),
    ("icon_128x128@1x.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256@1x.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512@1x.png", 512), ("icon_512x512@2x.png", 1024),
]

HOST_ICONSET = "Sources/hydra-plugin-host/Assets.xcassets/AppIcon.appiconset"
HOST_FILES = [("icon_%d.png" % px, px) for px in (16, 32, 64, 128, 256, 512, 1024)]

DRIVER_ICONSET = "Backplane/HydraIcon.iconset"
DRIVER_FILES = [
    ("icon_16x16.png", 16),   ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),   ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

DRIVER_ICNS = "Backplane/Driver/Hydra.icns"
DOCS = [("docs/assets/hydra-icon.png", 1024), ("docs/assets/hydra-icon-180.png", 180)]
MASTER_PNG = "Branding/HydraIcon-1024.png"


def main():
    # Supersample once, then downscale for crisp edges at every target size.
    hi = render(4096)
    master = hi.resize((1024, 1024), Image.LANCZOS)

    def write_set(folder, files):
        path = os.path.join(ROOT, folder)
        os.makedirs(path, exist_ok=True)
        for name, px in files:
            hi.resize((px, px), Image.LANCZOS).save(os.path.join(path, name))
        return len(files)

    n = 0
    n += write_set(APP_ICONSET, APP_FILES)
    n += write_set(HOST_ICONSET, HOST_FILES)
    n += write_set(DRIVER_ICONSET, DRIVER_FILES)

    os.makedirs(os.path.join(ROOT, "Branding"), exist_ok=True)
    master.save(os.path.join(ROOT, MASTER_PNG))

    # macOS device icon: a real .icns the Xcode build copies into every driver
    # bundle (the iconset above feeds the iconutil path in build_and_install.sh).
    master.save(os.path.join(ROOT, DRIVER_ICNS), format="ICNS")

    for name, px in DOCS:
        out = os.path.join(ROOT, name)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        hi.resize((px, px), Image.LANCZOS).save(out)

    print("Generated %d icon PNGs + Hydra.icns + master + %d web icons."
          % (n, len(DOCS)))
    print("Targets: app icon · plugin-host icon · driver iconset/.icns · website.")


if __name__ == "__main__":
    main()
