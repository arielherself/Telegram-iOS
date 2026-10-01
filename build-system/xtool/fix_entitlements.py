#!/usr/bin/env python3
"""Correct xtool's root-only signing mapping while preserving each bundle's identity."""
import argparse
import copy
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import zipfile

from extensions import normalize_widget


def fix(ipa, configuration, ldid, refresh_resources=False, sdk=None):
    config = json.loads(configuration.read_text())
    sdk = sdk or Path.home() / '.swiftpm/swift-sdks/darwin.artifactbundle/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk'
    sdk_version = json.loads((sdk / 'SDKSettings.json').read_text())['Version']
    with tempfile.TemporaryDirectory(prefix='arielgram-sign-', dir=ipa.parent) as temporary:
        folder = Path(temporary)
        subprocess.run(['bsdtar', '-xf', str(ipa.resolve()), '-C', str(folder)], check=True)
        host = folder / 'Payload' / (config['product'] + '.app')
        for product in [config] + config.get('extensions', []):
            bundle = host if product is config else host / 'PlugIns' / (product['product'] + '.appex')
            info = plistlib.loads((bundle / 'Info.plist').read_bytes())
            if info['CFBundleIdentifier'] != product['bundleID']:
                raise ValueError(f'Bundle ID does not match the xtool configuration: {bundle}')
            if refresh_resources:
                for reference in product.get('resources', config.get('resources', [])):
                    source = configuration.parent / reference
                    destination = bundle / source.name
                    if source.is_dir():
                        shutil.copytree(source, destination, dirs_exist_ok=True, symlinks=True)
                    else:
                        shutil.copy2(source, destination)
            permissions = (configuration.parent / product['entitlementsPath']).resolve()
            executable = bundle / info['CFBundleExecutable']
            original = executable.read_bytes()
            previous_info = plistlib.dumps(info)
            normalized = normalize_widget(info, original, sdk_version)
            if normalized != original:
                executable.write_bytes(normalized)
            if plistlib.dumps(info) != previous_info:
                (bundle / 'Info.plist').write_bytes(plistlib.dumps(info))
            subprocess.run([ldid, '-S' + str(permissions), str(bundle / info['CFBundleExecutable'])], check=True)
        # With no new entitlement file, -M keeps each binary's corrected values.
        # Deep bundle signing then regenerates the nested and host resource seals.
        subprocess.run([ldid, '-S', '-M', str(host)], check=True)
        fixed = folder / 'fixed.ipa'
        with zipfile.ZipFile(ipa) as original, zipfile.ZipFile(fixed, 'w', compression=zipfile.ZIP_STORED) as output:
            for item in original.infolist():
                path = folder / item.filename
                if item.is_dir():
                    content = b''
                elif path.is_symlink():
                    content = original.read(item)
                else:
                    content = path.read_bytes()
                output.writestr(copy.copy(item), content, compress_type=zipfile.ZIP_STORED)
        # ldid may create signature files absent from the initial archive.
        with zipfile.ZipFile(fixed, 'a', compression=zipfile.ZIP_STORED) as output:
            existing = set(output.namelist())
            for path in sorted((folder / 'Payload').rglob('*')):
                if path.is_file() and str(path.relative_to(folder)) not in existing:
                    output.write(path, str(path.relative_to(folder)))
        shutil.move(fixed, ipa)
    print('Corrected seven bundle identities and regenerated resource seals with ad hoc signing.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ipa', type=Path)
    parser.add_argument('--configuration', type=Path, required=True)
    parser.add_argument('--ldid', default=shutil.which('ldid'))
    parser.add_argument('--refresh-resources', action='store_true', help='Copy current xtool resources before regenerating signatures')
    parser.add_argument('--sdk', type=Path, help='iPhoneOS SDK directory; defaults to the xtool Darwin SDK')
    args = parser.parse_args()
    if not args.ldid:
        raise SystemExit('Install ProcursusTeam/ldid (requires libplist and OpenSSL) or pass --ldid /path/to/ldid')
    fix(args.ipa.resolve(), args.configuration.resolve(), args.ldid, args.refresh_resources, args.sdk)


if __name__ == '__main__':
    main()
