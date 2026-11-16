#!/usr/bin/env python3
"""Builds hostile update zips for scripts/update-fuzz (offline; nothing is installed).

    mkzip.py <recipe> <base.zip> <out.zip> <decoy dir>

Every recipe copies the entries of a good signed Glideball zip (<base.zip>, made by
ditto) and adds hostile ones. <decoy dir> is a folder outside the unpack folder that
must stay empty: the recipes aim at it by relative and absolute path and through links.
"""
import stat
import sys
import zipfile

recipe, base, out, decoy = sys.argv[1:5]


def entry(name, data=b"pwned", mode=0o100644):
    info = zipfile.ZipInfo(name)
    info.external_attr = mode << 16
    info.compress_type = zipfile.ZIP_DEFLATED
    return info, data


def link(name, target):
    return entry(name, target.encode(), stat.S_IFLNK | 0o777)


extra = []
if recipe == "traversal":
    extra = [entry("../escape-1.txt"), entry("../../escape-2.txt"), entry("../../../../../../../../tmp/escape-3.txt"),
             entry("Glideball.app/../../escape-4.txt"), entry("Glideball.app/Contents/../../../escape-5.txt"),
             entry(decoy + "/absolute.txt"), entry("//" + decoy + "/double-slash.txt"),
             entry("..\\escape-6.txt"), entry("./../escape-7.txt")]
elif recipe == "symlink-write":
    # a link to the decoy folder, then a file "inside" it
    extra = [link("lnk", decoy), entry("lnk/pwn.txt"),
             link("Glideball.app/Contents/lnk", decoy), entry("Glideball.app/Contents/lnk/pwn2.txt"),
             link("up", ".."), entry("up/escape-8.txt"),
             link("abs", "/"), entry("abs" + decoy + "/pwn3.txt")]
elif recipe == "symlink-loop":
    extra = [link("a", "b"), link("b", "a"), link("self", "self"), link("Glideball.app/Contents/loop", "loop")]
elif recipe == "many":
    extra = [entry("pad/%05d" % i, b"x") for i in range(20000)]
elif recipe == "long-names":
    extra = [entry("n" * 1000 + str(i), b"x") for i in range(50)] + [entry("d/" * 600 + "f")]
elif recipe == "duplicates":
    extra = [entry("Glideball.app/Contents/Info.plist", b"<plist/>"), entry("Glideball.app/Contents/Info.plist", b"junk")]
elif recipe == "bomb":
    extra = [entry("zeros.bin", b"\0" * (64 * 1024 * 1024))]
elif recipe == "app-is-symlink":
    # no real app at all: Glideball.app is a link to wherever the caller says (the decoy)
    with zipfile.ZipFile(out, "w") as z:
        z.writestr(*link("Glideball.app", decoy))
    sys.exit(0)
else:
    sys.exit("unknown recipe " + recipe)

with zipfile.ZipFile(base) as zin, zipfile.ZipFile(out, "w") as zout:
    for info in zin.infolist():
        zout.writestr(info, zin.read(info))
    for info, data in extra:
        zout.writestr(info, data)
