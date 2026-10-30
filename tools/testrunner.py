"""Runs GIANTS' TestRunner (the ModHub checker, a download from the GIANTS Developer Network) on the built zip and
prints what it found, in short. The program isn't in the repo: it is looked for in the TESTRUNNER environment
variable, else on the Desktop; the game in the Steam folder; the GIANTS Editor (it insists on one) the newest
installed.

Usage:
    python testrunner.py [zip]          (default dist/FS25_CourseCorrect.zip)
"""
import glob
import os
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HOME = Path(os.environ.get("USERPROFILE", str(Path.home())))
CANDIDATES = [os.environ.get("TESTRUNNER", ""),
              str(HOME / "OneDrive" / "Desktop" / "TestRunner_public.exe"),
              str(HOME / "Desktop" / "TestRunner_public.exe")]
GAMES = [r"C:\Program Files (x86)\Steam\steamapps\common\Farming Simulator 25", r"C:\Program Files\Farming Simulator 2025"]


def main():
    zip_path = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "dist" / "FS25_CourseCorrect.zip"
    exe = next((c for c in CANDIDATES if c and Path(c).is_file()), None)
    if exe is None:
        print("TestRunner_public.exe not found (set TESTRUNNER to it)")
        sys.exit(2)
    game = next((g for g in GAMES if Path(g).is_dir()), None)
    editors = sorted(glob.glob(r"C:\Program Files\GIANTS Software\GIANTS_Editor_*\editor.exe"))
    out = Path(tempfile.mkdtemp(prefix="testrunner_"))
    cmd = [exe, str(zip_path), "--noPause", "--disableAutoOpen", "--skipGuiPrograms", "--outputPath", str(out),
           "--logPath", str(out)]
    if game:
        cmd += ["-g", game]
    if editors:
        cmd += ["-e", editors[-1]]
    subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=900)
    results = sorted(out.glob("testResult_*.xml"))
    if not results:
        print("no result written; log:", out / "TestRunner.log")
        sys.exit(2)
    # (its file has a few tags that aren't XML, "<393:1:[Long-Line]... />": those lines dropped)
    text = results[-1].read_text(encoding="utf-8", errors="replace")
    clean = "\n".join(line for line in text.splitlines() if not line.strip().startswith(("<0", "<1", "<2", "<3", "<4",
                                                                                         "<5", "<6", "<7", "<8", "<9")))
    root = ET.fromstring(clean)
    outcome = root.find("results").get("testrunOutcome")
    print(f"TestRunner: {outcome}  ({results[-1].name})")
    for group in root.iter("testGroup"):
        if group.get("passed") == "False":
            print(f"  {group.get('name')}: FAIL")
            lines = [e.text.strip() for e in group.iter() if e.tag in ("error", "requires") and e.text]
            for f in group.iter("faultyFile"):
                for v in f.iter("violation"):
                    lines.append(f"{f.get('file').split('/', 1)[-1]}: {v.text.strip()}")
            for line in dict.fromkeys(lines):
                print("    -", line)
    sys.exit(0 if outcome == "PASS" else 1)


if __name__ == "__main__":
    main()
