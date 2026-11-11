"""Preview of the composite "shown with the current set" icon, built from the
game's pictures the same way the XAML does it. For tuning sizes by eye."""
import glob
import sys
from PIL import Image, ImageFilter

OUT = sys.argv[1]
S = 8  # preview scale


def load(name):
    f = [p for p in glob.glob("vanilla/Assets/**/*.DDS", recursive=True) if p.replace("\\", "/").endswith("/" + name)][0]
    return Image.open(f).convert("RGBA")


frame, eye = load("toggle_visibility_d_active.DDS"), load("ico_visibility_d.DDS")
sword, cross = load("c_ico_equipment_meleeSet_h.DDS"), load("c_ico_equipment_rangedSet_h.DDS")


def compose(mark, size, angle, blur, strength):
    w = 44 * S
    canvas = Image.new("RGBA", (w, w), (0, 0, 0, 0))
    canvas.alpha_composite(frame.resize((w, w), Image.LANCZOS))
    canvas.alpha_composite(eye.resize((40 * S, 40 * S), Image.LANCZOS), (2 * S, 2 * S))
    m = mark.resize((size * S, size * S), Image.LANCZOS).rotate(-angle, resample=Image.BICUBIC, expand=True)
    pad = int(blur * S * 3)
    a = Image.new("L", (m.width + 2 * pad, m.height + 2 * pad), 0)
    a.paste(m.split()[3], (pad, pad))
    halo = a.filter(ImageFilter.GaussianBlur(blur * S)).point(lambda v: min(255, int(v * strength)))
    black = Image.new("RGBA", halo.size, (0, 0, 0, 255))
    black.putalpha(halo)
    canvas.alpha_composite(black, ((w - black.width) // 2, (w - black.height) // 2))
    canvas.alpha_composite(m, ((w - m.width) // 2, (w - m.height) // 2))
    return canvas


# before -> after the user's "a little smaller, less shadow"
variants = [compose(sword, 34, -45, 2, 2.2), compose(sword, 30, -45, 1.3, 1.6),
            compose(cross, 26, 0, 2, 2.2), compose(cross, 23, 0, 1.3, 1.6)]
gap = 40
sheet = Image.new("RGBA", (len(variants) * (44 * S + gap) + gap, 44 * S + 2 * gap + 80), (58, 48, 44, 255))
for i, im in enumerate(variants):
    sheet.alpha_composite(im, (gap + i * (44 * S + gap), gap))
    sheet.alpha_composite(im.resize((44, 44), Image.LANCZOS), (gap + i * (44 * S + gap) + 22 * S - 22, 44 * S + gap + 20))
sheet.convert("RGB").save(OUT)
