#!/usr/bin/env python3
"""Packs PNG images into a Windows .ico (PNG-in-ICO, supported since Windows Vista).

Standard library only. Usage:
    make_ico.py out.ico in-16.png in-32.png ... in-256.png

Each PNG becomes one icon entry; its size is read from the PNG header.
On macOS the smaller sizes can be made from the 256 px icon with `sips -z N N`.
"""
import struct
import sys


def png_size(data: bytes) -> tuple[int, int]:
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise ValueError("not a PNG")
    return struct.unpack(">II", data[16:24])


def main() -> None:
    out, inputs = sys.argv[1], sys.argv[2:]
    images = []
    for path in inputs:
        with open(path, "rb") as f:
            data = f.read()
        w, h = png_size(data)
        if w > 256 or h > 256:
            raise ValueError(f"{path}: icons are at most 256 px")
        images.append((w, h, data))
    images.sort(key=lambda i: i[0])

    header = struct.pack("<HHH", 0, 1, len(images))   # reserved, type 1 = icon, count
    offset = 6 + 16 * len(images)
    entries, blobs = b"", b""
    for w, h, data in images:
        # width/height 0 means 256; no palette; 1 plane; 32 bpp
        entries += struct.pack("<BBBBHHII", w % 256, h % 256, 0, 0, 1, 32, len(data), offset)
        blobs += data
        offset += len(data)
    with open(out, "wb") as f:
        f.write(header + entries + blobs)


if __name__ == "__main__":
    main()
