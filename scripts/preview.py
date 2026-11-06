#!/usr/bin/env python3
"""Coarse ASCII preview + color probes for a screenshot (dev aid)."""
import subprocess, sys

path = sys.argv[1]
cols = int(sys.argv[2]) if len(sys.argv) > 2 else 100
rows = int(sys.argv[3]) if len(sys.argv) > 3 else 46

w, h = map(int, subprocess.check_output(["magick", "identify", "-format", "%w %h", path]).split())
raw = subprocess.check_output(["magick", path, "-resize", f"{cols}x{rows}!", "-depth", "8", "ppm:-"])
# parse P6
idx = 0
def token():
    global idx
    while raw[idx:idx+1].isspace(): idx += 1
    if raw[idx:idx+1] == b'#':
        while raw[idx:idx+1] != b'\n': idx += 1
        return token()
    start = idx
    while not raw[idx:idx+1].isspace(): idx += 1
    return raw[start:idx]
assert token() == b'P6'
w2, h2, maxv = int(token()), int(token()), int(token())
idx += 1
pix = raw[idx:idx+w2*h2*3]
ramp = " .:-=+*#%@"
out = []
for y in range(h2):
    line = ""
    for x in range(w2):
        i = (y*w2+x)*3
        r, g, b = pix[i], pix[i+1], pix[i+2]
        lum = (0.2126*r + 0.7152*g + 0.0722*b) / 255
        ch = ramp[min(len(ramp)-1, int(lum * len(ramp) ** 1.5))]
        line += ch
    out.append(line)
print("\n".join(out))
print(f"\nsource {w}x{h}")

def probe(name, fx, fy):
    x, y = int(fx*w), int(fy*h)
    fmt = "%[pixel:p{{{:d},{:d}}}]".format(x, y)
    px = subprocess.check_output(["magick", path, "-format", fmt, "info:"]).decode()
    print(f"{name:24s} ({fx:.2f},{fy:.2f}) {px}")

print("\nprobes:")
for spec in sys.argv[4:]:
    name, fx, fy = spec.split(",")
    probe(name, float(fx), float(fy))
