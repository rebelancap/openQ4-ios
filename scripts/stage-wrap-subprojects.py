#!/usr/bin/env python3
"""stage-wrap-subprojects.py — materialise upstream's meson wrap-file
subprojects that the iOS engine compiles, outside meson (D-116).

    scripts/stage-wrap-subprojects.py <tree> <out-dir> <cache-dir> <name>...

From v0.14.000 the openQ4 client links a retained-UI runtime that depends on
three wrap-file subprojects (RmlUi, JsonCpp, libtess2). The iOS build does not
run meson, so this does what `meson subprojects download` would, for exactly
the named wraps:

  1. read <tree>/subprojects/<name>.wrap (directory, source_url,
     source_filename, source_hash, patch_directory, diff_files);
  2. fetch the tarball into <cache-dir> unless present, and verify its sha256
     against the wrap — a mismatch is fatal, never re-downloaded silently;
  3. extract it to <out-dir>/<directory>, copy
     <tree>/subprojects/packagefiles/<patch_directory>/ over it, and apply each
     diff file with `patch -p1 --fuzz=0` (a diff that does not apply is fatal);
  4. write a stamp (hash of the wrap, the tarball and every packagefile) so an
     unchanged pin re-stages nothing and keeps mtimes stable.

Everything comes from the PINNED tree's own wrap files, so a pin bump that
moves a wrap or its patches re-stages it automatically.
"""

from __future__ import annotations

import configparser
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tarfile
import urllib.request
from pathlib import Path


def fatal(msg: str) -> None:
    print(f"FATAL: {msg}", file=sys.stderr)
    sys.exit(1)


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def stage(tree: Path, out: Path, cache: Path, name: str) -> None:
    wrap_path = tree / "subprojects" / f"{name}.wrap"
    if not wrap_path.is_file():
        fatal(f"no wrap file {wrap_path}")
    cp = configparser.ConfigParser(interpolation=None)
    cp.read(wrap_path)
    if not cp.has_section("wrap-file"):
        fatal(f"{wrap_path} is not a [wrap-file]")
    w = cp["wrap-file"]
    directory = w.get("directory")
    url = w.get("source_url")
    filename = w.get("source_filename")
    want_hash = w.get("source_hash")
    patch_dir = w.get("patch_directory")
    diffs = [d.strip() for d in w.get("diff_files", "").split(",") if d.strip()]
    if not (directory and url and filename and want_hash):
        fatal(f"{wrap_path} lacks directory/source_url/source_filename/source_hash")

    cache.mkdir(parents=True, exist_ok=True)
    tarball = cache / filename
    if not tarball.is_file():
        print(f"    downloading {url}")
        tmp = tarball.with_suffix(tarball.suffix + ".part")
        with urllib.request.urlopen(url) as r, tmp.open("wb") as f:
            shutil.copyfileobj(r, f)
        tmp.rename(tarball)
    got = sha256_file(tarball)
    if got != want_hash:
        fatal(f"{tarball} sha256 {got} != wrap's {want_hash} (delete it to re-fetch if the wrap moved)")

    # Stamp: the wrap text, the tarball and every packagefile.
    stamp_h = hashlib.sha256()
    stamp_h.update(wrap_path.read_bytes())
    stamp_h.update(got.encode())
    pkg = tree / "subprojects" / "packagefiles" / patch_dir if patch_dir else None
    if pkg is not None:
        if not pkg.is_dir():
            fatal(f"missing packagefiles dir {pkg}")
        for p in sorted(pkg.rglob("*")):
            if p.is_file():
                stamp_h.update(str(p.relative_to(pkg)).encode())
                stamp_h.update(p.read_bytes())
    stamp = stamp_h.hexdigest()

    dest = out / directory
    stamp_file = out / f".{name}.stamp"
    if dest.is_dir() and stamp_file.is_file() and stamp_file.read_text().strip() == stamp:
        print(f"    {name}: {directory} up to date")
        return

    if dest.exists():
        shutil.rmtree(dest)
    out.mkdir(parents=True, exist_ok=True)
    with tarfile.open(tarball) as tf:
        for m in tf.getmembers():
            p = Path(m.name)
            if p.is_absolute() or ".." in p.parts:
                fatal(f"{tarball} has an unsafe member {m.name}")
            if not p.parts or p.parts[0] != directory:
                fatal(f"{tarball} member {m.name} is outside {directory}/")
        tf.extractall(out, filter="data")
    if not dest.is_dir():
        fatal(f"{tarball} did not produce {dest}")

    if pkg is not None:
        for p in sorted(pkg.rglob("*")):
            rel = p.relative_to(pkg)
            if p.is_dir():
                (dest / rel).mkdir(parents=True, exist_ok=True)
            else:  # meson copies the whole patch_directory over, diffs included
                (dest / rel).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(p, dest / rel)
    for d in diffs:
        diff = tree / "subprojects" / "packagefiles" / d
        if not diff.is_file():
            fatal(f"missing diff file {diff}")
        with diff.open("rb") as f:
            r = subprocess.run(["patch", "-p1", "--fuzz=0", "--forward", "--silent", "-d", str(dest)],
                               stdin=f)
        if r.returncode != 0:
            fatal(f"{d} does not apply to {directory}")
    if name == "glslang":
        configure_glslang_build_info(dest)
    stamp_file.write_text(stamp + "\n")
    print(f"    {name}: staged {directory} ({len(diffs)} diff(s))")


def configure_glslang_build_info(dest: Path) -> None:
    """Emulate the packagefile's configure_file: glslang/build_info.h from
    build_info.h.tmpl, with the version_info.set(...) values meson would use."""
    mb = (dest / "glslang" / "meson.build").read_text()
    values = dict(re.findall(r"version_info\.set\('(\w+)',\s*'?([^')]*)'?\)", mb))
    for key in ("major", "minor", "patch", "flavor"):
        if key not in values:
            fatal(f"glslang/meson.build sets no version_info '{key}'")
    text = (dest / "build_info.h.tmpl").read_text()
    for key, value in values.items():
        text = text.replace(f"@{key}@", value)
    if re.search(r"@\w+@", text):
        fatal("glslang build_info.h.tmpl has unsubstituted @vars@")
    (dest / "glslang" / "build_info.h").write_text(text)


def main() -> None:
    if len(sys.argv) < 5:
        print(__doc__, file=sys.stderr)
        sys.exit(1)
    tree, out, cache = (Path(a).resolve() for a in sys.argv[1:4])
    for name in sys.argv[4:]:
        stage(tree, out, cache, name)


if __name__ == "__main__":
    main()
