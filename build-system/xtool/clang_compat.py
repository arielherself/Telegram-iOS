#!/usr/bin/env python3
"""SwiftPM merges C++ unsafe flags into mixed-target C/ObjC compilations.

Retain each Bazel C++ dialect, filtering C++ -std only for C/Objective-C inputs.
"""
import signal
signal.signal(signal.SIGINT, signal.SIG_DFL)
import os
from pathlib import Path
import shlex
import sys


def arguments(args):
    expanded = []
    for arg in args:
        if arg.startswith('@') and Path(arg[1:]).is_file():
            expanded.extend(shlex.split(Path(arg[1:]).read_text()))
        else:
            expanded.append(arg)
    # Module scanning and linking have no source language to adjust.
    if '-c' in expanded:
        index = expanded.index('-c')
        if index + 1 < len(expanded) and Path(expanded[index + 1]).suffix in ('.c', '.m'):
            expanded = [arg for arg in expanded if not (arg.startswith('-std=') and '++' in arg)]
    return expanded

if __name__ == '__main__':
    compiler = Path(__file__).with_name('clang-host-path').read_text().strip()
    os.execv(compiler, [compiler] + arguments(sys.argv[1:]))
