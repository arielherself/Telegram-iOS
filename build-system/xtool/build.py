#!/usr/bin/env python3
"""Run the complete local Linux → xtool pipeline (no remote writes)."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bazel', default=shutil.which('bazel'))
    parser.add_argument('--query-file', type=Path)
    parser.add_argument('--skip-native', action='store_true', help='Reuse already-generated native archives')
    args = parser.parse_args()
    if not args.bazel:
        raise SystemExit('Pass --bazel /path/to/bazel')
    os.chdir(ROOT)
    lottie = ROOT / 'submodules/LottieCpp/lottiecpp'
    patch = SCRIPTS / 'patches/lottie-vector3d.patch'
    already_applied = subprocess.run(['git', 'apply', '--reverse', '--check', str(patch)], cwd=lottie, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    if not already_applied:
        subprocess.run(['git', 'apply', '--check', str(patch)], cwd=lottie, check=True)
        subprocess.run(['git', 'apply', str(patch)], cwd=lottie, check=True)
    sdk = Path.home() / '.swiftpm/swift-sdks/darwin.artifactbundle'
    info = json.loads(subprocess.check_output(['swiftc', '-print-target-info'], text=True))
    compiler = Path(info['paths']['runtimeResourcePath']).parents[1] / 'bin/clang'
    clang_resources = subprocess.check_output([str(compiler), '-print-resource-dir'], text=True).strip()
    def run(script, *arguments):
        subprocess.run([sys.executable, str(SCRIPTS / script), *map(str, arguments)], check=True)
    run('sdk_compat.py', '--sdk', sdk, '--clang-resources', clang_resources)
    if not (ROOT / 'build-input/configuration-repository/variables.bzl').exists():
        run('bootstrap.py', '--bazel', args.bazel)
    common = ['--bazel', args.bazel]
    if args.query_file:
        common += ['--query-file', args.query_file.resolve()]
    run('prepare.py', *common)
    query = args.query_file.resolve() if args.query_file else ROOT / 'build/xtool/rules.star'
    saved = ['--bazel', args.bazel, '--query-file', query]
    run('generate.py', *saved)
    if not args.skip_native:
        run('native.py', *saved, '--toolchain', compiler.parent, 'opus', 'webp', 'mozjpeg', 'dav1d', 'vpx', 'ffmpeg', 'td')
    run('intents.py')
    run('prepare.py', *saved)
    report = json.loads((ROOT / 'build/xtool/preparation-report.json').read_text())
    if report['missingFiles'] or report['unsupported']:
        raise SystemExit('Source preparation incomplete; see build/xtool/preparation-report.json')
    run('linux_resources.py', *saved)
    for path in (ROOT / 'build/xtool/.build/release.yaml', ROOT / 'build/xtool/.build/arm64-apple-ios/release/description.json'):
        path.unlink(missing_ok=True)
    environment = dict(os.environ, CC=str(sdk / 'toolset/bin/clang-compatible'))
    if not shutil.which('zip'):
        pack_tools = ROOT / 'build/xtool/pack-tools'
        pack_tools.mkdir(exist_ok=True)
        zip_tool = pack_tools / 'zip'
        shutil.copy2(SCRIPTS / 'zip_compat.py', zip_tool)
        zip_tool.chmod(0o755)
        environment['PATH'] = str(pack_tools) + os.pathsep + environment['PATH']
    subprocess.run(['xtool', 'dev', 'build', '--ipa', '--configuration', 'release'], cwd=ROOT / 'build/xtool', env=environment, check=True)
    run('fix_entitlements.py', ROOT / 'build/xtool/xtool/Arielgram.ipa', '--configuration', ROOT / 'build/xtool/xtool.yml')
    sdk_version = json.loads((sdk / 'Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/SDKSettings.json').read_text())['Version']
    run('validate_identity.py', ROOT / 'build/xtool/xtool/Arielgram.ipa', '--sdk-version', sdk_version, '--report', ROOT / 'build/xtool/identity-validation.json')

if __name__ == '__main__':
    main()
