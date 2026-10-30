"""Checks the translations against English: each file is valid XML, has exactly English's keys, and every text has
the same placeholders (%s, %d, %.1f, %%...) in the same order (the game formats them with English's arguments) and
the names that stay as they are (CourseCorrect, AutoDrive, ...).

Usage:
    python check_translations.py
"""
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PLACEHOLDER = re.compile(r"%(?:%|[-+ 0#]*\d*(?:\.\d+)?[sdfiouxXeEgGc])")
KEEP = ["CourseCorrect", "AutoDrive", "Courseplay", "FS25_Guidance.zip"]


def texts(path):
    root = ET.parse(path).getroot()
    return {t.get("name"): t.get("text") or "" for t in root.iter("text")}


def main():
    en = texts(ROOT / "translations" / "translation_en.xml")
    ok = True
    for path in sorted((ROOT / "translations").glob("translation_*.xml")):
        lang = path.stem.split("_")[1]
        if lang == "en":
            continue
        problems = []
        try:
            tr = texts(path)
        except ET.ParseError as e:
            print(f"{lang}: not valid XML: {e}: FAILED")
            ok = False
            continue
        missing = [k for k in en if k not in tr]
        extra = [k for k in tr if k not in en]
        if missing:
            problems.append(f"{len(missing)} missing ({', '.join(missing[:4])})")
        if extra:
            problems.append(f"{len(extra)} not in English ({', '.join(extra[:4])})")
        for k, text in en.items():
            if k not in tr:
                continue
            if PLACEHOLDER.findall(text) != PLACEHOLDER.findall(tr[k]):
                problems.append(f"{k}: placeholders {PLACEHOLDER.findall(text)} -> {PLACEHOLDER.findall(tr[k])}")
            for name in KEEP:
                if name in text and name not in tr[k]:
                    problems.append(f"{k}: '{name}' translated")
            if text and not tr[k].strip():
                problems.append(f"{k}: empty")
        good = not problems
        ok = ok and good
        print(f"{lang}: {len(tr)} texts{'' if good else ', ' + '; '.join(problems[:6])}: {'OK' if good else 'FAILED'}")
    print("OK" if ok else "FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
