"""Which input devices Glideball may touch (port of DeviceSupport.swift).

The Expert Mouse is always supported. Kensington's other trackballs are
supported only with the Beta program on. Everything else (other brands'
mice and trackballs, touchpads, our own virtual device) is never opened for
grabbing.
"""

from __future__ import annotations

KENSINGTON_VENDOR_ID = 0x047D
EXPERT_MOUSE_PRODUCT_ID = 0x1020
VIRTUAL_DEVICE_NAME = "Glideball Virtual Pointer"

EXPERT, OTHER_KENSINGTON, OTHER = "expertMouse", "otherKensington", "other"


def kind(vendor: int, product: int, name: str = "") -> str:
    if vendor != KENSINGTON_VENDOR_ID:
        return OTHER
    if product == EXPERT_MOUSE_PRODUCT_ID or "expert mouse" in (name or "").lower():
        return EXPERT
    return OTHER_KENSINGTON


def is_supported(vendor: int, product: int, name: str = "", beta: bool = False) -> bool:
    if VIRTUAL_DEVICE_NAME.lower() in (name or "").lower():
        return False
    k = kind(vendor, product, name)
    return k == EXPERT or (k == OTHER_KENSINGTON and beta)


def display_name(vendor: int, product: int, name: str = "") -> str:
    trimmed = (name or "").strip()
    if trimmed:
        if vendor == KENSINGTON_VENDOR_ID and "kensington" not in trimmed.lower():
            return "Kensington " + trimmed
        return trimmed
    return "Kensington Expert Mouse" if kind(vendor, product, name) == EXPERT else "Kensington trackball"


def is_pointer(capabilities: dict) -> bool:
    """A relative pointer node: REL_X, REL_Y and BTN_LEFT.

    `capabilities` is python-evdev's ``device.capabilities()`` (ints)."""
    EV_KEY, EV_REL = 0x01, 0x02
    rel = capabilities.get(EV_REL, [])
    keys = capabilities.get(EV_KEY, [])
    return 0x00 in rel and 0x01 in rel and 0x110 in keys
