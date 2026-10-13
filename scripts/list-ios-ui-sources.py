#!/usr/bin/env python3
"""list-ios-ui-sources.py — the client's side libraries that meson builds as
their own static_library targets (own flags, no engine PCH), as meson would
compile them for an SDL3 Vulkan client (D-116).

    scripts/list-ios-ui-sources.py <tree> <subprojects-dir>

Prints one line per source: <group>\t<absolute path>. Groups:
  retained  openQ4's static_library('openq4-retained-ui', ...) in meson.build
  rmlui     RmlUi core (packagefiles/rmlui/meson.build rmlui_sources)
  jsoncpp   JsonCpp (its packagefile meson.build)
  tess2     libtess2 (C; its packagefile meson.build)
  glslang   glslang 15.1.0 (packagefile meson.build glslang_sources + Unix ossource)
  matcomp   static_library('openq4-material-compiler', ...)   (links glslang)
  vkdevsel  static_library('openq4-vulkan-device-selection', ...)
  textin    static_library('openq4-text-ingress', ...)
  nativeq   static_library('openq4-native-queue', ...)

The lists are read out of the pinned meson files, not copied here, so a pin
bump that adds a retained-UI file or moves a wrap carries itself. Every list
must be non-empty and every file must exist, or this fails loudly.
"""

from __future__ import annotations

import configparser
import re
import sys
from pathlib import Path

QUOTED = re.compile(r"'([^']+\.(?:cpp|c))'")


def fatal(msg: str) -> None:
    print(f"FATAL: {msg}", file=sys.stderr)
    sys.exit(1)


def block(text: str, start_pat: str, end_pat: str, what: str) -> str:
    m = re.search(start_pat, text)
    if not m:
        fatal(f"could not find {what}")
    end = text.find(end_pat, m.end())
    if end < 0:
        fatal(f"could not find the end of {what}")
    return text[m.end():end]


def wrap_dir(tree: Path, subprojects: Path, name: str) -> Path:
    cp = configparser.ConfigParser(interpolation=None)
    cp.read(tree / "subprojects" / f"{name}.wrap")
    d = subprojects / cp["wrap-file"]["directory"]
    if not d.is_dir():
        fatal(f"{d} is not staged — run scripts/sync-overlay.sh")
    return d


def emit(group: str, root: Path, rels: list[str]) -> None:
    if not rels:
        fatal(f"no {group} sources found")
    for rel in rels:
        p = root / rel
        if not p.is_file():
            fatal(f"{group}: {p} does not exist")
        print(f"{group}\t{p}")


def main() -> None:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        sys.exit(1)
    tree = Path(sys.argv[1]).resolve()
    subprojects = Path(sys.argv[2]).resolve()

    meson = (tree / "meson.build").read_text()
    retained = block(meson, r"static_library\(\s*'openq4-retained-ui',", "dependencies:",
                     "static_library('openq4-retained-ui') in meson.build")
    emit("retained", tree, QUOTED.findall(retained))

    rml = wrap_dir(tree, subprojects, "rmlui")
    rml_meson = (rml / "meson.build").read_text()
    emit("rmlui", rml, QUOTED.findall(block(rml_meson, r"rmlui_sources\s*=\s*files\(", ")", "rmlui_sources")))

    js = wrap_dir(tree, subprojects, "jsoncpp")
    emit("jsoncpp", js, QUOTED.findall(block((js / "meson.build").read_text(),
                                             r"static_library\('jsoncpp',", "include_directories", "jsoncpp sources")))

    def lib(meson_name: str, group: str) -> None:
        body = block(meson, r"static_library\(\s*'" + re.escape(meson_name) + r"',",
                     "install:", f"static_library('{meson_name}') in meson.build")
        emit(group, tree, QUOTED.findall(body))

    lib("openq4-material-compiler", "matcomp")
    lib("openq4-vulkan-device-selection", "vkdevsel")
    lib("openq4-text-ingress", "textin")
    lib("openq4-native-queue", "nativeq")

    gl = wrap_dir(tree, subprojects, "glslang")
    gl_meson = (gl / "meson.build").read_text()
    emit("glslang", gl, QUOTED.findall(block(gl_meson, r"glslang_sources\s*=\s*files\(", ")", "glslang_sources"))
         + ["glslang/OSDependent/Unix/ossource.cpp"])

    tess = wrap_dir(tree, subprojects, "libtess2")
    emit("tess2", tess, QUOTED.findall(block((tess / "meson.build").read_text(),
                                             r"static_library\('tess2',", "include_directories", "libtess2 sources")))


if __name__ == "__main__":
    main()
