#!/usr/bin/env python3
"""Export approved raster masters to the native and StepX resource formats.

Requires Pillow. This only fits, sizes, composites icon backgrounds and exports
template masks; character and logo artwork live in assets/brand/*-source.png.
"""
from pathlib import Path
import hashlib
import json
import subprocess
import tempfile

from PIL import Image, ImageDraw, ImageOps

ROOT = Path(__file__).resolve().parents[1]
BRAND = ROOT / 'assets/brand'
INFO = {'author': 'xcode', 'version': 1}


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def content(name):
    image = Image.open(BRAND / name).convert('RGBA')
    alpha = image.getchannel('A')
    assert alpha.getextrema() == (0, 255), f'{name}: expected real transparency'
    # Ignore nearly transparent generator margins when locating the artwork.
    box = alpha.point(lambda value: 255 if value > 192 else 0).getbbox()
    assert box, f'{name}: empty image'
    left, top, right, bottom = box
    return image.crop((max(0, left-3), max(0, top-3), min(image.width, right+3), min(image.height, bottom+3)))


def fit(image, size, fraction=0.9, background=(0, 0, 0, 0)):
    canvas = Image.new('RGBA', (size, size), background)
    inside = ImageOps.contain(image, (round(size*fraction), round(size*fraction)), Image.Resampling.LANCZOS)
    canvas.alpha_composite(inside, ((size-inside.width)//2, (size-inside.height)//2))
    return canvas


def save(image, path, **kwargs):
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, **kwargs)


def image_set(catalog, name, image):
    folder = catalog / f'{name}.imageset'
    save(image, folder / f'{name}.png')
    write_json(folder / 'Contents.json', {'images': [{'filename': f'{name}.png', 'idiom': 'universal'}], 'info': INFO})


def main():
    logo, agent = content('logo-source.png'), content('agent-source.png')
    icon = fit(logo, 1024, 0.72, (255, 255, 255, 255)).convert('RGB')
    logo_png, agent_png = fit(logo, 512, 0.88), fit(agent, 512, 0.9)
    save(icon, BRAND / 'app-icon.png')
    save(logo_png, BRAND / 'logo.png')
    save(agent_png, BRAND / 'agent.png')

    for target, platform in [('GrowthApp', 'ios'), ('GrowthWatch', 'watchos')]:
        catalog = ROOT / 'ios' / target / 'Assets.xcassets'
        if not (catalog / 'Contents.json').exists():
            write_json(catalog / 'Contents.json', {'info': INFO})
        folder = catalog / 'AppIcon.appiconset'
        save(icon, folder / 'AppIcon.png')
        write_json(folder / 'Contents.json', {'images': [{'filename': 'AppIcon.png', 'idiom': 'universal', 'platform': platform, 'size': '1024x1024'}], 'info': INFO})
    catalog = ROOT / 'ios/GrowthApp/Assets.xcassets'
    image_set(catalog, 'AptAgent', agent_png)
    image_set(catalog, 'AptLogo', logo_png)

    mac = ROOT / 'mac/ime/Brand'
    save(agent_png, mac / 'APTAgent.png')
    save(logo_png, mac / 'APTLogo.png')
    mac_icon = Image.new('RGBA', (1024, 1024), (0, 0, 0, 0))
    ImageDraw.Draw(mac_icon).rounded_rectangle((56, 56, 968, 968), radius=202, fill='white')
    mac_icon.alpha_composite(fit(logo, 1024, 0.65))
    save(mac_icon, mac / 'APTAppIcon.icns', format='ICNS')
    # Real 1x/2x TIFF representations at the same 18pt logical size.
    template = Image.new('RGBA', logo_png.size, (0, 0, 0, 0))
    template.putalpha(logo_png.getchannel('A'))
    with tempfile.TemporaryDirectory(prefix='apt-menu-icon-') as scratch:
        paths = []
        for scale in (1, 2):
            path = Path(scratch) / f'menu-{scale}.tiff'
            fit(template, 18*scale, 0.94).save(path, dpi=(72*scale, 72*scale))
            paths.append(str(path))
        subprocess.run(['/usr/bin/tiffutil', '-cat', *paths, '-out', str(mac / 'APTMenuIconTemplate.tiff')], check=True)

    for image, name in [(logo_png, 'apt-logo.png'), (agent_png, 'apt-agent.png'), (icon, 'apt-app-icon.png')]:
        save(image, ROOT / 'stepx-client/brand' / name)
    manifest = {name: hashlib.sha256((BRAND/name).read_bytes()).hexdigest() for name in ('logo-source.png', 'agent-source.png', 'logo.png', 'agent.png', 'app-icon.png')}
    write_json(BRAND / 'exports.json', {'sha256': manifest, 'appIcon': 'opaque RGB 1024px; platform applies its mask', 'menuIcon': 'black alpha template, 18pt at 1x/2x'})
    print('APT brand resources exported for iOS, watchOS, StepX and macOS')


if __name__ == '__main__':
    main()
