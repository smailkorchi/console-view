#!/usr/bin/env python3
"""Write and verify the approved Finder layout without driving the Finder UI."""

import argparse
import ctypes
from pathlib import Path

from ds_store import DSStore
from mac_alias import Alias


POSITIONS = {"Console View.app": (215, 266), "Applications": (553, 266)}
WINDOW = {
    "WindowBounds": "{{160, 100}, {768, 512}}",
    "ShowStatusBar": False,
    "ContainerShowSidebar": False,
    "PreviewPaneVisibility": False,
    "SidebarWidth": 0,
    "ShowTabView": False,
    "ShowToolbar": False,
    "ShowPathbar": False,
    "ShowSidebar": False,
}
ICON_VIEW = {
    "viewOptionsVersion": 1,
    "backgroundType": 2,
    "backgroundColorRed": 0.1,
    "backgroundColorGreen": 0.1,
    "backgroundColorBlue": 0.1,
    "gridOffsetX": 0.0,
    "gridOffsetY": 0.0,
    "gridSpacing": 64.0,
    "arrangeBy": "none",
    "showIconPreview": False,
    "showItemInfo": False,
    "labelOnBottom": True,
    "textSize": 13.0,
    "iconSize": 128.0,
    "scrollPositionX": 0.0,
    "scrollPositionY": 0.0,
}


def resolved_alias_path(data):
    """Resolve through macOS without opening UI or mounting other volumes."""
    cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    pointer = ctypes.c_void_p
    declarations = {
        "CFDataCreate": ([pointer, pointer, ctypes.c_long], pointer),
        "CFURLCreateBookmarkDataFromAliasRecord": ([pointer, pointer], pointer),
        "CFURLCreateByResolvingBookmarkData": (
            [pointer, pointer, ctypes.c_ulong, pointer, pointer,
             ctypes.POINTER(ctypes.c_ubyte), ctypes.POINTER(pointer)], pointer),
        "CFURLGetFileSystemRepresentation": (
            [pointer, ctypes.c_ubyte, pointer, ctypes.c_long], ctypes.c_ubyte),
        "CFRelease": ([pointer], None),
    }
    for name, (arguments, result) in declarations.items():
        function = getattr(cf, name)
        function.argtypes = arguments
        function.restype = result
    references = []
    try:
        record = cf.CFDataCreate(None, ctypes.create_string_buffer(data), len(data))
        references.append(record)
        bookmark = cf.CFURLCreateBookmarkDataFromAliasRecord(None, record)
        assert bookmark, "macOS cannot decode the background alias"
        references.append(bookmark)
        stale, error = ctypes.c_ubyte(), pointer()
        url = cf.CFURLCreateByResolvingBookmarkData(
            None, bookmark, (1 << 8) | (1 << 9), None, None,
            ctypes.byref(stale), ctypes.byref(error))
        references.extend([url, error.value])
        assert url, "macOS cannot resolve the background alias"
        path = ctypes.create_string_buffer(4096)
        assert cf.CFURLGetFileSystemRepresentation(url, True, path, len(path))
        return Path(path.value.decode())
    finally:
        for reference in reversed(references):
            if reference:
                cf.CFRelease(reference)


def verify(volume):
    with DSStore.open(str(volume / ".DS_Store"), "r") as store:
        assert store["."]["bwsp"] == WINDOW, "Finder window settings differ"
        icon_view = store["."]["icvp"]
        assert all(icon_view[key] == value for key, value in ICON_VIEW.items())
        assert store["."]["icvl"] == (b"type", b"icnv"), "Icon view is not selected"
        for filename, position in POSITIONS.items():
            assert store[filename]["Iloc"] == position, f"Wrong position: {filename}"
        alias = Alias.from_bytes(icon_view["backgroundImageAlias"])
        assert alias.volume.name == "Console View", "Wrong background volume"
        assert alias.volume.posix_path.startswith("/Volumes/"), "Background has no public volume hint"
        assert alias.target.posix_path == "/.background/background.tiff"
        assert alias.target.cnid == (volume / ".background/background.tiff").stat().st_ino
        resolved = resolved_alias_path(icon_view["backgroundImageAlias"])
        assert resolved.samefile(volume / ".background/background.tiff"), f"Background resolves to {resolved}"
    data = (volume / ".DS_Store").read_bytes()
    assert b"/Users/" not in data and b"/private/" not in data, "Private path in metadata"
    print("Finder layout verified: 768x512, 128pt icons, hidden chrome, volume-relative background")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("volume", type=Path)
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    if not args.verify:
        alias = Alias.for_file(str(args.volume / ".background/background.tiff"))
        # Keep the factory's public mount hint: Finder needs it to resolve the file.
        with DSStore.open(str(args.volume / ".DS_Store"), "w+") as store:
            store["."]["vSrn"] = ("long", 1)
            store["."]["bwsp"] = WINDOW
            store["."]["icvp"] = {**ICON_VIEW, "backgroundImageAlias": alias.to_bytes()}
            store["."]["icvl"] = ("type", b"icnv")
            for filename, position in POSITIONS.items():
                store[filename]["Iloc"] = position
    verify(args.volume)


if __name__ == "__main__":
    main()
