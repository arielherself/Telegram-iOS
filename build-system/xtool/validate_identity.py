#!/usr/bin/env python3
"""Verify identifiers and embedded entitlements in the completed Arielgram IPA."""
import argparse
import json
from pathlib import Path
import plistlib
import struct
import zipfile

from extensions import validate_extension

BUNDLE_ID = 'xyz.arielherself.Arielgram'
EXTENSIONS = {'Share', 'NotificationContent', 'NotificationService', 'SiriIntents', 'Widget', 'BroadcastUpload'}


def entitlements(data):
    """Read the XML entitlements from an arm64 Mach-O code-signature superblob."""
    magic, cpu, _, filetype, count, _, _, _ = struct.unpack_from('<8I', data)
    if magic != 0xfeedfacf or cpu != 0x100000c or filetype != 2:
        raise ValueError('Expected an arm64 Mach-O executable')
    offset = 32
    for _ in range(count):
        command, size = struct.unpack_from('<II', data, offset)
        if size < 8 or offset + size > len(data):
            raise ValueError('Invalid Mach-O load command')
        if command == 0x1d:
            start, length = struct.unpack_from('<II', data, offset + 8)
            signature = data[start:start + length]
            sig_magic, sig_length, slots = struct.unpack_from('>III', signature)
            if sig_magic != 0xfade0cc0 or sig_length > len(signature):
                raise ValueError('Invalid code-signature superblob')
            for index in range(slots):
                _, blob_offset = struct.unpack_from('>II', signature, 12 + index * 8)
                blob_magic, blob_length = struct.unpack_from('>II', signature, blob_offset)
                if blob_magic == 0xfade7171:
                    return plistlib.loads(signature[blob_offset + 8:blob_offset + blob_length])
            raise ValueError('Code signature has no XML entitlements')
        offset += size
    raise ValueError('Executable has no code signature')


def validate(path):
    products = []
    localized_files = 0
    with zipfile.ZipFile(path) as archive:
        damaged = archive.testzip()
        if damaged:
            raise ValueError(f'ZIP CRC check failed: {damaged}')
        names = archive.namelist()
        main_roots = sorted({n.split('/')[1] for n in names if n.startswith('Payload/') and n.split('/')[1].endswith('.app')})
        if main_roots != ['Arielgram.app']:
            raise ValueError(f'Unexpected application bundles: {main_roots}')
        host = 'Payload/Arielgram.app'
        roots = [host] + sorted({n.rsplit('/Info.plist', 1)[0] for n in names if n.startswith(host + '/PlugIns/') and n.endswith('.appex/Info.plist')})
        expected_ids = {BUNDLE_ID} | {BUNDLE_ID + '.' + suffix for suffix in EXTENSIONS}
        for product in roots:
            info = plistlib.loads(archive.read(product + '/Info.plist'))
            bundle = info['CFBundleIdentifier']
            if bundle not in expected_ids or any(p['bundleID'] == bundle for p in products):
                raise ValueError(f'Unexpected or duplicated Bundle ID: {bundle}')
            if info['CFBundleName'] != 'Arielgram':
                raise ValueError(f'Unexpected bundle name in {product}')
            executable = archive.read(product + '/' + info['CFBundleExecutable'])
            if product != host:
                validate_extension(info, executable, widget=bundle == BUNDLE_ID + '.Widget')
            permissions = entitlements(executable)
            identifier = permissions.get('application-identifier', '')
            if not identifier.endswith('.' + bundle):
                raise ValueError(f'Application identifier does not match {bundle}')
            team = identifier[:-len(bundle) - 1]
            if not team or '.' in team:
                raise ValueError(f'Invalid signing team prefix: {identifier}')
            if permissions.get('com.apple.security.application-groups') != ['group.' + BUNDLE_ID]:
                raise ValueError(f'App Group is not isolated: {bundle}')
            if permissions.get('keychain-access-groups') != [team + '.' + BUNDLE_ID]:
                raise ValueError(f'Keychain group is not isolated: {bundle}')
            if 'swiftgram' in json.dumps(permissions).lower() or 'ph.telegra.Telegraph' in json.dumps(permissions):
                raise ValueError(f'Upstream identifier in entitlements: {bundle}')
            if product == host:
                schemes = [scheme for item in info.get('CFBundleURLTypes', []) for scheme in item.get('CFBundleURLSchemes', [])]
                if schemes != ['arielgram']:
                    raise ValueError(f'URL schemes are not isolated: {schemes}')
                if info['CFBundleDisplayName'] != 'Arielgram':
                    raise ValueError('Unexpected application display name')
                containers = permissions.get('com.apple.developer.icloud-container-identifiers', [])
                if containers and containers != ['iCloud.' + BUNDLE_ID]:
                    raise ValueError(f'iCloud container is not isolated: {containers}')
                kvstore = permissions.get('com.apple.developer.ubiquity-kvstore-identifier')
                if kvstore and kvstore != team + '.' + BUNDLE_ID:
                    raise ValueError(f'iCloud key-value store is not isolated: {kvstore}')
            products.append({'bundleID': bundle, 'executable': info['CFBundleExecutable'], 'entitlements': permissions})
        if {p['bundleID'] for p in products} != expected_ids:
            raise ValueError('Missing application or extension')
        for name in names:
            if name.endswith('.strings'):
                data = archive.read(name)
                if data.startswith((b'\xff\xfe', b'\xfe\xff')):
                    text = data.decode('utf-16')
                elif data.startswith(b'bplist'):
                    text = json.dumps(plistlib.loads(data), ensure_ascii=False)
                else:
                    text = data.decode('utf-8-sig')
                if 'swiftgram' in text.lower():
                    raise ValueError(f'Upstream name in localized UI resource: {name}')
                localized_files += 1
    return {'ipa': str(path.resolve()), 'bundleID': BUNDLE_ID, 'displayName': 'Arielgram', 'products': products, 'localizedFilesChecked': localized_files, 'zipCRCValid': True, 'deviceTested': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ipa', type=Path)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    report = validate(args.ipa)
    if args.report:
        args.report.write_text(json.dumps(report, indent=2) + '\n')
    print(f"Verified Arielgram host + six extensions, signed identifiers, isolated groups, URL scheme, and {report['localizedFilesChecked']} localization resources.")


if __name__ == '__main__':
    main()
