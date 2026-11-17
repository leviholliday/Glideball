#!/usr/bin/env python3
"""Builds hostile update zips for scripts/update-fuzz (offline; nothing is installed).

    mkzip.py <recipe> <base.zip> <out.zip> <decoy dir>

Every recipe copies the entries of a good signed Glideball zip (<base.zip>, made by
ditto) and adds hostile ones. <decoy dir> is a folder outside the unpack folder that
must stay empty: the recipes aim at it by relative and absolute path and through links.
"""
import stat
import struct
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


def rewrite_directory(path, tweak, zip64_end=False):
    """Rewrites the zip's central directory (its index) in place. tweak(name, fixed, extra) gets each
    entry's 46 fixed bytes (a bytearray) and extra field and returns them, changed or not: that's how an
    index is made to claim sizes the data doesn't have. zip64_end writes the zip64 end records too."""
    data = open(path, "rb").read()
    end = data.rfind(b"PK\x05\x06")
    count, size, offset = struct.unpack("<HII", data[end + 10:end + 20])
    directory, out, pos = data[offset:offset + size], [], 0
    while pos < len(directory):
        fixed = bytearray(directory[pos:pos + 46])
        name_len, extra_len, comment_len = struct.unpack("<HHH", fixed[28:34])
        name = directory[pos + 46:pos + 46 + name_len]
        extra = directory[pos + 46 + name_len:pos + 46 + name_len + extra_len]
        comment = directory[pos + 46 + name_len + extra_len:pos + 46 + name_len + extra_len + comment_len]
        pos += 46 + name_len + extra_len + comment_len
        fixed, extra = tweak(name.decode(), fixed, extra)
        fixed[30:32] = struct.pack("<H", len(extra))
        out.append(bytes(fixed) + name + extra + comment)
    new = b"".join(out)
    tail = b""
    if zip64_end:
        record_at = offset + len(new)
        tail = (b"PK\x06\x06" + struct.pack("<QHHIIQQQQ", 44, 45, 45, 0, 0, count, count, len(new), offset)
                + b"PK\x06\x07" + struct.pack("<IQI", 0, record_at, 1))
        end_record = b"PK\x05\x06" + struct.pack("<HHHHIIH", 0, 0, 0xFFFF, 0xFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0)
    else:
        end_record = b"PK\x05\x06" + struct.pack("<HHHHIIH", 0, 0, count, count, len(new), offset, 0)
    open(path, "wb").write(data[:offset] + new + tail + end_record)


def claim(unc, comp, zip64=False):
    """A tweak that makes entries whose name starts with 'big' claim these sizes."""
    def tweak(name, fixed, extra):
        if not name.startswith("big"):
            return fixed, extra
        if zip64:
            fixed[20:24] = fixed[24:28] = struct.pack("<I", 0xFFFFFFFF)
            extra = struct.pack("<HHQQ", 1, 16, unc, comp)
        else:
            fixed[20:24], fixed[24:28] = struct.pack("<I", comp), struct.pack("<I", unc)
        return fixed, extra
    return tweak


extra = []
patch = None
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
    extra = [entry("pad/%05d" % i, b"x") for i in range(25000)]
elif recipe == "many-ok":
    extra = [entry("pad/%05d" % i, b"x") for i in range(19000)]
elif recipe == "long-names":
    extra = [entry("n" * 1000 + str(i), b"x") for i in range(50)] + [entry("d/" * 600 + "f")]
elif recipe == "duplicates":
    extra = [entry("Glideball.app/Contents/Info.plist", b"<plist/>"), entry("Glideball.app/Contents/Info.plist", b"junk")]
elif recipe == "bomb":
    extra = [entry("zeros.bin", b"\0" * (64 * 1024 * 1024))]   # 64 MB squeezed to ~64 KB: a ratio of about 1000:1
elif recipe == "bomb-small":
    extra = [entry("zeros.bin", b"\0" * (8 * 1024 * 1024))]    # a high ratio, but under the size where it counts
elif recipe == "lying-total":
    # three 'stored' entries whose index claims 200 MB each (600 MB in all, ratio 1:1): no unpacking needed to refuse
    extra = [(i, d) for i, d in [entry("big1.bin", b"abc"), entry("big2.bin", b"abc"), entry("big3.bin", b"abc")]]
    for i, _ in extra: i.compress_type = zipfile.ZIP_STORED
    patch = (claim(200_000_000, 200_000_000), False)
elif recipe == "lying-total-zip64":
    extra = [(i, d) for i, d in [entry("big1.bin", b"abc"), entry("big2.bin", b"abc")]]
    for i, _ in extra: i.compress_type = zipfile.ZIP_STORED
    patch = (claim(6_000_000_000, 6_000_000_000, zip64=True), True)   # 6 GB each, claimed in zip64 fields
elif recipe == "zip64-plain":
    patch = (lambda name, fixed, extra: (fixed, extra), True)     # the good zip, with zip64 end records
elif recipe == "lying-bomb":
    # the index says 1 KB; the data inflates to 64 MB. Only watching the unpack folder catches this
    extra = [entry("big1.bin", b"\0" * (64 * 1024 * 1024))]
    patch = (claim(1000, 500), False)
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
if patch:
    rewrite_directory(out, patch[0], zip64_end=patch[1])
