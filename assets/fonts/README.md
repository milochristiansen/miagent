# Bundled emoji font

`NotoEmoji-Regular.ttf` is a monochrome emoji fallback used by the GUI when a
text font has no glyph for an emoji codepoint.

It is derived from Google's Noto Emoji variable font:

- Source: https://github.com/google/fonts/tree/main/ofl/notoemoji
- License: SIL Open Font License 1.1 (see `OFL.txt`)
- Modifications: instantiated at weight 400 and subset to symbol/emoji ranges.

Noto Color Emoji is not bundled because current releases are CBDT bitmap fonts
with a single fixed 109px strike. ImGui's rasterizer cannot scale that strike to
normal UI sizes, so a scalable outline font is used instead.
