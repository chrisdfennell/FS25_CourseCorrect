"""Builds dist/FS25_CourseCorrect.zip and checks it against the GIANTS mod rules (at most 128 files, Lua files at most
0.5 MB, only known file types). Does not copy anything into the game's mods folder.

Usage:
    python build.py
"""
import hashlib
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MOD_NAME = "FS25_CourseCorrect"
EXCLUDE_TOP = {".git", ".gitignore", ".vscode", "docs", "tools", "dist", "README.md"}
ALLOWED = {".xml", ".lua", ".dds", ".png", ".i3d", ".shapes", ".ogg", ".txt", ".gdm", ".grle", ".cache", ".anim"}
MAX_FILES = 128
MAX_LUA = 512 * 1024


def main():
    files = [p for p in sorted(ROOT.rglob("*"))
             if p.is_file() and p.relative_to(ROOT).parts[0] not in EXCLUDE_TOP and "__pycache__" not in p.parts]
    problems = []
    if len(files) > MAX_FILES:
        problems.append(f"{len(files)} files, at most {MAX_FILES} allowed")
    for p in files:
        rel = p.relative_to(ROOT).as_posix()
        if p.suffix.lower() not in ALLOWED:
            problems.append(f"{rel}: file type not allowed")
        if p.suffix.lower() == ".lua" and p.stat().st_size > MAX_LUA:
            problems.append(f"{rel}: {p.stat().st_size} bytes, Lua files at most {MAX_LUA}")
    if problems:
        sys.exit("Build failed:\n  " + "\n  ".join(problems))
    out = ROOT / "dist" / f"{MOD_NAME}.zip"
    out.parent.mkdir(exist_ok=True)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
        for p in files:
            zf.write(p, p.relative_to(ROOT).as_posix())
    sha = hashlib.sha256(out.read_bytes()).hexdigest()
    print(f"Built {out} ({len(files)} files, {out.stat().st_size} bytes)\nSHA-256 {sha}")


if __name__ == "__main__":
    main()
