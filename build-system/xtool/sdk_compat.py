#!/usr/bin/env python3
"""Pair Darwin Swift libraries with the host compiler's builtin C headers."""
import argparse
import json
from pathlib import Path
import subprocess
import shutil
import os


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk', type=Path, default=Path.home() / '.swiftpm/swift-sdks/darwin.artifactbundle')
    parser.add_argument('--clang-resources', type=Path, required=True)
    args = parser.parse_args()
    if not (args.clang_resources / 'include/arm_neon.h').is_file():
        raise SystemExit('Clang resource directory has no ARM NEON headers')
    path = args.sdk / 'swift-sdk.json'
    config = json.loads(path.read_text())
    triple = config['targetTriples']['arm64-apple-ios']
    original = args.sdk / 'Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift'
    overlay = args.sdk / 'linux-swift-resources'
    overlay.mkdir(exist_ok=True)
    for source in original.iterdir():
        target = overlay / source.name
        intended = args.clang_resources.resolve() if source.name == 'clang' else source.resolve()
        if target.is_symlink():
            target.unlink()
        elif target.exists():
            raise SystemExit(f'Refusing to replace {target}')
        target.symlink_to(intended)
    backup = path.with_suffix('.json.xtool-original')
    if not backup.exists():
        backup.write_bytes(path.read_bytes())
    triple['swiftResourcesPath'] = 'linux-swift-resources'
    path.write_text(json.dumps(config, indent=2) + '\n')
    compiler = args.clang_resources.resolve().parents[2] / 'bin/clang'
    if not compiler.is_file():
        raise SystemExit(f'Matching host Clang not found: {compiler}')
    wrapper = args.sdk / 'toolset/bin/clang-compatible'
    shutil.copy2(Path(__file__).with_name('clang_compat.py'), wrapper)
    wrapper.chmod(0o755)
    wrapper.with_name('clang-host-path').write_text(str(compiler) + '\n')
    toolset_path = args.sdk / 'toolset.json'
    toolset_backup = toolset_path.with_suffix('.json.xtool-original')
    if not toolset_backup.exists():
        toolset_backup.write_bytes(toolset_path.read_bytes())
    toolset = json.loads(toolset_path.read_text())
    for key in ('cCompiler', 'cxxCompiler'):
        toolset[key] = {'path': str(wrapper.resolve())}
    toolset_path.write_text(json.dumps(toolset, indent=2) + '\n')
    print('Darwin libraries retained; Clang builtins now match the Linux Swift compiler.')

if __name__ == '__main__':
    main()
