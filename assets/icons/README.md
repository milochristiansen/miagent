# Application icons

The desktop entry uses the icon name `miagent`. This directory is a hicolor
icon theme tree, and `install.sh` installs it into the user's hicolor theme:

- `hicolor/scalable/apps/miagent.svg` is the source SVG;
- the PNGs under `hicolor/<size>x<size>/apps/` are installed at their matching
  hicolor sizes.

The PNGs are pre-rendered so installing does not require SVG tooling. After
editing the SVG, regenerate them with `rsvg-convert` (from librsvg), from the
repository root:

```sh
for size in 16 24 32 48 64 128 256 512; do
    dir="assets/icons/hicolor/${size}x${size}/apps"
    mkdir -p "$dir"
    rsvg-convert -w "$size" -h "$size" -o "$dir/miagent.png" \
        assets/icons/hicolor/scalable/apps/miagent.svg
done
```
