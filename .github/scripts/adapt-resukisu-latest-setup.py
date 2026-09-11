#!/usr/bin/env python3
from pathlib import Path
import re
import sys

sha = sys.argv[1]
build = Path("build_kernel.sh")
text = build.read_text()

old = 'curl -LSs "$KSU_SETUP_URL" | bash -s builtin'
new = (
    'curl -LSs "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh" '
    f'| bash -s builtin {sha}'
)

if old in text:
    text = text.replace(old, new, 1)
elif sha not in text:
    text2, n = re.subn(
        r'curl -LSs "[^"]+" \| bash(?: -s -- \S+)?',
        new,
        text,
        count=1,
    )
    if n != 1:
        raise SystemExit("SukiSU setup command layout changed; refusing blind patch")
    text = text2

marker = 'echo "[+] KernelSU setup finished."'
inject = (
    marker
    + "\n    chmod +x .github/scripts/adapt-resukisu-sucompat230.sh"
    + "\n    .github/scripts/adapt-resukisu-sucompat230.sh"
)
if marker not in text:
    raise SystemExit("cannot find KernelSU setup finished marker")
if "adapt-resukisu-sucompat230.sh" not in text:
    text = text.replace(marker, inject, 1)

kpm_line = '        scripts/config --file "${OUT_DIR}/.config" -d KPM || true\n'
if kpm_line not in text:
    needle = "            -e KSU_SUSFS\n"
    if needle not in text:
        raise SystemExit("cannot find -e KSU_SUSFS config line")
    text = text.replace(needle, needle + kpm_line, 1)

build.write_text(text)
print("Successfully configured SukiSU builtin setup with SHA:", sha)
