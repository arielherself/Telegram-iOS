#!/usr/bin/env python3
"""Translate the subset of xcrun used by codec build scripts to Linux LLVM.

This never attempts to emulate Xcode resource compilers. Unsupported tools
fail explicitly instead of producing incomplete resources.
"""

import os
from pathlib import Path
import re
import shutil
import sys


def main():
    arguments = sys.argv[1:]
    while arguments and arguments[0] in ("--sdk", "-sdk"):
        platform = arguments[1]
        if not platform.startswith("iphoneos"):
            raise ValueError(f"Only the iPhoneOS device SDK is configured: {platform}")
        arguments = arguments[2:]
    sysroot = Path(os.environ["SDKROOT"])
    if arguments == ["--show-sdk-path"]:
        print(sysroot)
        return
    if arguments == ["--show-sdk-version"]:
        match = re.fullmatch(r"iPhoneOS([0-9.]+)\.sdk", sysroot.name)
        if not match:
            raise ValueError("Cannot identify the installed SDK version")
        print(match.group(1))
        return
    find = arguments and arguments[0] in ("--find", "-find", "-f")
    if find:
        arguments = arguments[1:]
    if not arguments:
        raise ValueError("A tool name is required")
    tool = arguments[0]
    aliases = {"clang": "clang", "clang++": "clang++", "ar": "ar", "ranlib": "ranlib", "as": "ios-as", "ld": "clang++", "nm": "llvm-nm", "strip": "llvm-strip", "lipo": "llvm-lipo"}
    if tool not in aliases:
        raise ValueError(f"No Linux adapter for Xcode tool '{tool}'")
    executable = shutil.which(aliases[tool])
    if not executable:
        raise ValueError(f"LLVM tool not installed: {aliases[tool]}")
    if find:
        print(executable)
    else:
        os.execv(executable, [executable] + arguments[1:])


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, IndexError) as error:
        print(f"xcrun compatibility: {error}", file=sys.stderr)
        sys.exit(1)
