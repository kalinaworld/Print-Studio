#!/usr/bin/env python3
"""
Paper-free color check for P900 Print.

Renders a patch chart through the app's real color pipeline, pushes the resulting PDF through the
same macOS/Epson print filters a real job uses, but writes the result to a file instead of the printer.
Then it reads the patch colors back out and compares them with what the app converted.

Run:  python3 check_color_pipeline.py [paper-profile-file-name]
Uses no ink and no paper. Writes color-check.txt next to this script.
"""
import json
import os
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.expanduser("~/Applications/P900Print.app/Contents/MacOS/P900Print")
SYSTEM_PPD = "/etc/cups/ppd/EPSON_SC_P900_Series.ppd"
LOCAL_PPD = os.path.join(HERE, "EPSON_SC_P900_Series.ppd")
OUT = os.path.join(HERE, "selftest")
REPORT = os.path.join(HERE, "color-check.txt")
PAPER = sys.argv[1] if len(sys.argv) > 1 else "cifa_p900_ragphot310_m_bk.icc"

# The same driver options the app sends with a real job (Letter, sheet, Fine Art Matte, color management off).
JOB_OPTIONS = [
    "PageSize=Letter", "EPIJ_Size=4", "EPIJ_PSrc=2", "EPIJ_Medi=183", "EPIJ_Ink_=1",
    "EPIJ_Mode=3", "EPIJ_CMat=3", "EPIJ_PrntMode=4", "EPIJ_Qual=52", "EPIJ_Bi_D=1", "EPIJ_FDet=1",
]

lines = []


def say(text=""):
    print(text)
    lines.append(text)


def u32(buf, off, big):
    return struct.unpack((">" if big else "<") + "I", buf[off:off + 4])[0]


def load_raster(path):
    with open(path, "rb") as f:
        data = f.read()
    sync = data[:4]
    # (big endian, header size, compressed)
    table = {
        b"RaSt": (True, 420, False), b"tSaR": (False, 420, False),
        b"RaS2": (True, 1796, True), b"2SaR": (False, 1796, True),
        b"RaS3": (True, 1796, False), b"3SaR": (False, 1796, False),
    }
    if sync not in table:
        raise ValueError("not a CUPS raster stream, first bytes: %r" % (data[:16],))
    big, hsize, compressed = table[sync]
    hdr = data[4:4 + hsize]
    info = {
        "width": u32(hdr, 372, big), "height": u32(hdr, 376, big),
        "bpc": u32(hdr, 384, big), "bpp": u32(hdr, 388, big), "bpl": u32(hdr, 392, big),
        "order": u32(hdr, 396, big), "cspace": u32(hdr, 400, big),
        "hres": u32(hdr, 276, big), "vres": u32(hdr, 280, big),
        "sync": sync.decode("latin1"), "compressed": compressed,
    }
    return data, 4 + hsize, info


def iter_rows(data, pos, info):
    bpl, px, height = info["bpl"], info["bpp"] // 8, info["height"]
    y = 0
    if not info["compressed"]:
        while y < height:
            yield y, 1, data[pos:pos + bpl]
            pos += bpl
            y += 1
        return
    while y < height:
        rep = data[pos] + 1
        pos += 1
        line = bytearray()
        while len(line) < bpl:
            c = data[pos]
            pos += 1
            if c & 128:
                n = 257 - c
                line += data[pos:pos + px * n]
                pos += px * n
            else:
                line += data[pos:pos + px] * (c + 1)
                pos += px
        yield y, rep, bytes(line[:bpl])
        y += rep


def find_bbox(data, pos, info):
    px = info["bpp"] // 8
    x0, x1, y0, y1 = 10 ** 9, -1, None, None
    for y, rep, row in iter_rows(data, pos, info):
        if row.strip(b"\xff"):
            left = len(row) - len(row.lstrip(b"\xff"))
            right = len(row.rstrip(b"\xff"))
            x0 = min(x0, left // px)
            x1 = max(x1, (right - 1) // px)
            if y0 is None:
                y0 = y
            y1 = y + rep - 1
    return x0, y0, x1, y1


def grab_rows(data, pos, info, wanted):
    got = {}
    remaining = set(wanted)
    for y, rep, row in iter_rows(data, pos, info):
        for t in list(remaining):
            if y <= t < y + rep:
                got[t] = row
                remaining.discard(t)
        if not remaining:
            break
    return got


def run_variant(label, pdf, expected, ppd):
    say("--- %s ---" % label)
    cmd = ["/usr/sbin/cupsfilter", "-p", ppd, "-m", "application/vnd.cups-raster"]
    for o in JOB_OPTIONS:
        cmd += ["-o", o]
    cmd.append(pdf)
    ras = os.path.join(OUT, "%s.ras" % label)
    with open(ras, "wb") as fh:
        res = subprocess.run(cmd, stdout=fh, stderr=subprocess.PIPE)
    if res.returncode != 0 or os.path.getsize(ras) < 2000:
        say("cupsfilter failed (exit %s): %s" % (res.returncode, res.stderr.decode("utf8", "replace")[-600:]))
        return None

    data, pos, info = load_raster(ras)
    say("raster: %(width)dx%(height)d px, %(bpc)d bit/channel, %(bpp)d bit/pixel, colorspace id %(cspace)d, "
        "%(hres)dx%(vres)d dpi, stream %(sync)s" % info)
    if info["bpc"] not in (8, 16) or info["order"] != 0 or info["cspace"] not in (1, 19, 20):
        say("Unexpected raster format (not chunky 8/16-bit RGB). Send this file to Claude.")
        return None

    x0, y0, x1, y1 = find_bbox(data, pos, info)
    if y0 is None:
        say("The raster is blank, nothing was drawn.")
        return None
    say("picture found at x %d-%d, y %d-%d" % (x0, x1, y0, y1))

    cols, rows = expected["cols"], expected["rows"]
    pw, ph = x1 - x0 + 1, y1 - y0 + 1
    targets = {}
    for p in expected["patches"]:
        tx = x0 + int((p["col"] + 0.5) * pw / cols)
        ty = y0 + int((p["row"] + 0.5) * ph / rows)
        targets[p["name"]] = (tx, ty)
    rows_data = grab_rows(data, pos, info, {t[1] for t in targets.values()})
    px = info["bpp"] // 8
    step = info["bpc"] // 8

    worst = 0
    say("%-8s %-16s %-16s %-16s %s" % ("patch", "original sRGB", "app converted", "after filters", "diff"))
    for p in expected["patches"]:
        tx, ty = targets[p["name"]]
        row = rows_data[ty]
        got = [row[tx * px + i * step] for i in range(3)]
        diff = max(abs(a - b) for a, b in zip(got, p["expected"]))
        worst = max(worst, diff)
        say("%-8s %-16s %-16s %-16s %d" % (p["name"], tuple(p["src"]), tuple(p["expected"]), tuple(got), diff))
    ok = worst <= 3
    say("result: %s (largest difference %d)" % ("PASS, filters left the colors alone" if ok else "FAIL, filters changed the colors", worst))
    return ok


def main():
    if not os.path.exists(APP):
        say("P900 Print is not installed. Run ./build.sh first.")
        return
    say("Building the test chart with the app's color pipeline (paper profile: %s)..." % PAPER)
    res = subprocess.run([APP, "--selftest", OUT, PAPER], capture_output=True, text=True)
    if res.returncode != 0:
        say("self test failed: " + (res.stderr or res.stdout).strip())
        return
    with open(os.path.join(OUT, "expected.json")) as fh:
        expected = json.load(fh)
    for n in expected.get("notes", []):
        say("note: " + n)

    ppd = SYSTEM_PPD if os.access(SYSTEM_PPD, os.R_OK) else LOCAL_PPD
    results = {}
    for label, name in (("tagged", expected["pdfs"]["tagged"]), ("device", expected["pdfs"]["device"])):
        say()
        results[label] = run_variant(label, os.path.join(OUT, name), expected, ppd)

    say()
    say("=== summary ===")
    if results.get("tagged"):
        say("Keep 'Tag PDF with the paper profile' ON (default).")
    elif results.get("device"):
        say("Turn 'Tag PDF with the paper profile' OFF in Advanced.")
    else:
        say("Neither variant passed. Send color-check.txt to Claude.")

    with open(REPORT, "w") as fh:
        fh.write("\n".join(lines) + "\n")
    print("\n(saved to %s)" % REPORT)


main()
