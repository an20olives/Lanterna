#!/usr/bin/env python3
"""Draws Lanterna's app icons and writes the asset catalogs. Needs Pillow (pip install pillow).

tvOS: a three-layer parallax stack, back to front: ink-to-aubergine gradient, soft amber light cone, aperture mark.
iOS: the same three layers flattened into one 1024 square (iOS applies the corner mask itself).
Run from the repo root:  python3 scripts/make-icons.py
"""
import json, math, os
from PIL import Image, ImageDraw, ImageFilter

AMBER = (232, 162, 60)
INK = (11, 9, 20)
AUBERGINE = (52, 20, 58)
GLOW = (255, 226, 168)


def back(w, h):
    img = Image.new("RGB", (w, h))
    px = img.load()
    for y in range(h):
        t = y / (h - 1)
        c = tuple(round(INK[i] + (AUBERGINE[i] - INK[i]) * t ** 1.2) for i in range(3))
        for x in range(w):
            px[x, y] = c
    return img


def cone(w, h):
    """A soft cone of light falling from the top centre."""
    scale = 2
    layer = Image.new("RGBA", (w * scale, h * scale), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    top = (w * scale / 2, -h * scale * 0.05)
    spread = w * scale * 0.42
    d.polygon([(top[0] - w * scale * 0.04, top[1]), (top[0] + w * scale * 0.04, top[1]),
               (top[0] + spread, h * scale), (top[0] - spread, h * scale)], fill=AMBER + (120,))
    layer = layer.filter(ImageFilter.GaussianBlur(w * scale * 0.035))
    # Fade towards the bottom so it reads as light, not a shape.
    mask = Image.new("L", layer.size)
    mp = mask.load()
    for y in range(layer.size[1]):
        v = round(255 * max(0.0, 1 - (y / layer.size[1]) * 0.85))
        for x in range(layer.size[0]):
            mp[x, y] = v
    alpha = Image.eval(layer.split()[3], lambda a: a)
    layer.putalpha(Image.composite(alpha, Image.new("L", layer.size, 0), mask))
    return layer.resize((w, h), Image.LANCZOS)


def aperture(w, h, radius_fraction):
    scale = 3
    W, H = w * scale, h * scale
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    cx, cy = W / 2, H * 0.52
    R = min(W, H) * radius_fraction
    r = R * 0.36
    # soft glow behind the mark
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse([cx - R * 1.25, cy - R * 1.25, cx + R * 1.25, cy + R * 1.25], fill=AMBER + (70,))
    layer = Image.alpha_composite(layer, glow.filter(ImageFilter.GaussianBlur(R * 0.35)))
    d = ImageDraw.Draw(layer)
    ring = R * 0.07
    d.ellipse([cx - R, cy - R, cx + R, cy + R], outline=AMBER + (255,), width=round(ring))
    verts = [(cx + r * math.cos(math.radians(60 * k - 90)), cy + r * math.sin(math.radians(60 * k - 90))) for k in range(6)]
    blade = R * 0.045
    for k in range(6):
        a, b = verts[k], verts[(k + 1) % 6]
        dx, dy = b[0] - a[0], b[1] - a[1]
        n = math.hypot(dx, dy)
        dx, dy = dx / n, dy / n
        # extend from b along the edge until it meets the ring (|p - c| = R * 0.93)
        px, py = b[0] - cx, b[1] - cy
        target = R * 0.93
        bq = px * dx + py * dy
        cq = px * px + py * py - target * target
        t = -bq + math.sqrt(bq * bq - cq)
        end = (b[0] + dx * t, b[1] + dy * t)
        d.line([a, end], fill=AMBER + (255,), width=round(blade))
        for p in (a, end):
            d.ellipse([p[0] - blade / 2, p[1] - blade / 2, p[0] + blade / 2, p[1] + blade / 2], fill=AMBER + (255,))
    d.polygon(verts, fill=GLOW + (255,))
    inner = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(inner).polygon(verts, fill=GLOW + (160,))
    layer = Image.alpha_composite(layer, inner.filter(ImageFilter.GaussianBlur(R * 0.05)))
    return layer.resize((w, h), Image.LANCZOS)


def write(path, image):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    image.save(path)


def info():
    return {"author": "xcode", "version": 1}


def dump(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(obj, f, indent=2)


def tvos(root):
    brand = os.path.join(root, "App Icon & Top Shelf Image.brandassets")
    dump(os.path.join(root, "Contents.json"), {"info": info()})
    dump(os.path.join(brand, "Contents.json"), {
        "assets": [
            {"filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"},
            {"filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"},
        ],
        "info": info(),
    })
    layers = [("Front", lambda w, h: aperture(w, h, 0.30)), ("Middle", cone), ("Back", back)]

    def stack(name, sizes):
        base = os.path.join(brand, name + ".imagestack")
        dump(os.path.join(base, "Contents.json"), {"info": info(), "layers": [{"filename": f"{n}.imagestacklayer"} for n, _ in layers]})
        for layer_name, draw in layers:
            layer_dir = os.path.join(base, f"{layer_name}.imagestacklayer")
            dump(os.path.join(layer_dir, "Contents.json"), {"info": info()})
            images = []
            for scale, (w, h) in sizes:
                fname = f"{layer_name.lower()}{'' if scale == '1x' else '@2x'}.png"
                write(os.path.join(layer_dir, "Content.imageset", fname), draw(w, h))
                images.append({"idiom": "tv", "filename": fname, "scale": scale})
            dump(os.path.join(layer_dir, "Content.imageset", "Contents.json"), {"images": images, "info": info()})

    stack("App Icon - App Store", [("1x", (1280, 768))])
    stack("App Icon", [("1x", (400, 240)), ("2x", (800, 480))])


def ios(root):
    dump(os.path.join(root, "Contents.json"), {"info": info()})
    size = 1024
    img = back(size, size).convert("RGBA")
    img = Image.alpha_composite(img, cone(size, size))
    img = Image.alpha_composite(img, aperture(size, size, 0.34))
    icon_dir = os.path.join(root, "AppIcon.appiconset")
    write(os.path.join(icon_dir, "icon-1024.png"), img.convert("RGB"))
    dump(os.path.join(icon_dir, "Contents.json"), {
        "images": [{"filename": "icon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
        "info": info(),
    })


if __name__ == "__main__":
    tvos("Apps/tvOS/Assets.xcassets")
    ios("Apps/iOS/Assets.xcassets")
    print("icons written")
