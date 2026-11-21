"""Creates icon.png, icon.ico (PC app) and icon_foreground.png (Android adaptive icon).
build.bat runs this automatically if icon.ico is missing. Edit draw() to change the design."""
from PIL import Image, ImageDraw


def draw(size=1024):
    s = size / 64
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    blue = (88, 101, 242, 255)
    r = lambda *v: tuple(int(x * s) for x in v)  # noqa: E731
    d.rounded_rectangle(r(4, 10, 60, 46), radius=int(6 * s), fill=blue)
    d.rounded_rectangle(r(9, 15, 55, 41), radius=int(3 * s), fill=(22, 26, 51, 255))
    d.rectangle(r(27, 46, 37, 53), fill=blue)
    d.rounded_rectangle(r(18, 53, 46, 58), radius=int(2 * s), fill=blue)
    return img


img = draw()
img.save("icon.png")
img.save("icon.ico", sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])

# Android adaptive icon: same picture, shrunk, so the round/squircle mask doesn't crop it
fg = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
small = img.resize((620, 620), Image.LANCZOS)
fg.paste(small, (202, 202), small)
fg.save("icon_foreground.png")
print("Created icon.png, icon.ico, icon_foreground.png")
