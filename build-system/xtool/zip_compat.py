#!/usr/bin/env python3
"""Translate xtool's ZIP-store command to the locally available libarchive."""
import os
from pathlib import Path
import shutil
import sys

if len(sys.argv) != 4 or sys.argv[1] != '-yqru0' or Path(sys.argv[2]).exists():
    raise SystemExit('Unsupported xtool zip invocation')
archive = shutil.which('bsdtar')
if not archive:
    raise SystemExit('Install zip or bsdtar to package the IPA')
os.execv(archive, [archive, '--format=zip', '--options', 'zip:compression=store', '-cf', sys.argv[2], sys.argv[3]])
