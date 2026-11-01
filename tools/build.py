"""Builds dist/FS25_CourseCorrect.zip and checks it against the GIANTS mod rules (at most 128 files, Lua files at most
0.5 MB, only known file types), and that the mod hangs together: every XML file valid, every file modDesc names there
and every script in it named, the icon there, the translations complete (tools/check_translations.py). Does not copy
anything into the game's mods folder.

Usage:
    python build.py
"""
import hashlib
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MOD_NAME = "FS25_CourseCorrect"
EXCLUDE_TOP = {".claude", ".git", ".gitignore", ".gitattributes", ".github", ".vscode", "docs", "tools", "dist", "README.md",
               "LICENSE"}
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
        # the panel's textures need their transparency (DXT1 has none: a black square round the shape in the game)
        if rel.startswith("textures/") and p.suffix.lower() == ".dds" and p.read_bytes()[84:88] != b"DXT5":
            problems.append(f"{rel}: not DXT5 (no transparency)")
    # the mod hangs together
    for p in files:
        if p.suffix.lower() == ".xml":
            try:
                ET.parse(p)
            except ET.ParseError as e:
                problems.append(f"{p.relative_to(ROOT).as_posix()}: not valid XML ({e})")
    desc = ET.parse(ROOT / "modDesc.xml").getroot()
    named = set()
    for e in desc.iter():
        f = e.get("filename")
        if f and e.tag in ("sourceFile", "specialization"):
            named.add(f)
            if not (ROOT / f).exists():
                problems.append(f"modDesc names {f}, which isn't there")
    for p in files:
        rel = p.relative_to(ROOT).as_posix()
        if p.suffix.lower() == ".lua" and rel not in named:
            problems.append(f"{rel}: not named in modDesc (never loaded)")
    icon = desc.findtext("iconFilename")
    if not icon or not (ROOT / icon).exists():
        problems.append(f"icon {icon} isn't there")
    check = subprocess.run([sys.executable, str(ROOT / "tools" / "check_translations.py")], capture_output=True, text=True)
    if check.returncode != 0:
        problems.append("translations: " + "; ".join(l for l in check.stdout.splitlines() if "FAILED" in l))
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
