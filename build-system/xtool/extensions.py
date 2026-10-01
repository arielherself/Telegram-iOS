"""Normalize bundle SDK metadata without changing linked entry points."""
import struct

WIDGET_POINT = 'com.apple.widgetkit-extension'
IOS_14 = 14 << 16


def build_version(data):
    if len(data) < 32:
        raise ValueError('Truncated Mach-O header')
    magic, cpu, _, kind, count, _, _, _ = struct.unpack_from('<8I', data)
    if (magic, cpu, kind) != (0xfeedfacf, 0x100000c, 2):
        raise ValueError('Expected arm64 Mach-O executable')
    offset = 32
    for _ in range(count):
        command, size = struct.unpack_from('<II', data, offset)
        if size < 8 or offset + size > len(data):
            raise ValueError('Malformed Mach-O load command')
        if command == 0x32:
            if size < 24:
                raise ValueError('Malformed LC_BUILD_VERSION')
            platform, minimum, sdk = struct.unpack_from('<III', data, offset + 8)
            return offset, platform, minimum, sdk
        offset += size
    raise ValueError('Missing LC_BUILD_VERSION')


def encoded_version(version):
    parts = [int(p) for p in version.split('.')]
    if not 1 <= len(parts) <= 3 or not 0 <= parts[0] <= 65535 or any(not 0 <= p <= 255 for p in parts[1:]):
        raise ValueError('Invalid SDK version')
    parts += [0] * (3 - len(parts))
    return (parts[0] << 16) | (parts[1] << 8) | parts[2]


def version_string(version):
    return f'{version >> 16}.{(version >> 8) & 255}' + (f'.{version & 255}' if version & 255 else '')


def normalize_bundle(info, data, sdk_version):
    offset, platform, minimum, _ = build_version(data)
    if platform != 2:
        raise ValueError('Bundle executable must target iOS')
    sdk = encoded_version(sdk_version)
    if info.get('NSExtension', {}).get('NSExtensionPointIdentifier') == WIDGET_POINT:
        minimum = max(minimum, IOS_14)
    if sdk < minimum:
        raise ValueError('Linked SDK is older than deployment minimum')
    patched = bytearray(data)
    struct.pack_into('<II', patched, offset + 12, minimum, sdk)
    info['MinimumOSVersion'] = version_string(minimum)
    info['DTSDKName'] = 'iphoneos' + sdk_version
    info['DTPlatformName'] = 'iphoneos'
    info['DTPlatformVersion'] = sdk_version
    info['CFBundleSupportedPlatforms'] = ['iPhoneOS']
    return bytes(patched)


def normalize_widget(info, data, sdk_version):
    if info.get('NSExtension', {}).get('NSExtensionPointIdentifier') != WIDGET_POINT:
        return data
    return normalize_bundle(info, data, sdk_version)


def validate_build_metadata(info, data, expected_sdk_version=None):
    _, platform, minimum, sdk = build_version(data)
    if platform != 2 or sdk < minimum:
        raise ValueError('Invalid iOS build version')
    if encoded_version(info.get('MinimumOSVersion', '0')) != minimum:
        raise ValueError('Deployment minimum differs between Info.plist and Mach-O')
    sdk_name = info.get('DTSDKName', '')
    if not sdk_name.startswith('iphoneos') or encoded_version(sdk_name.removeprefix('iphoneos')) != sdk:
        raise ValueError('Linked SDK differs between Info.plist and Mach-O')
    if encoded_version(info.get('DTPlatformVersion', '0')) != sdk:
        raise ValueError('Platform SDK differs between Info.plist and Mach-O')
    if info.get('DTPlatformName') != 'iphoneos' or info.get('CFBundleSupportedPlatforms') != ['iPhoneOS']:
        raise ValueError('Missing iPhoneOS platform metadata')
    if expected_sdk_version is not None and sdk != encoded_version(expected_sdk_version):
        raise ValueError('Linked SDK differs from the build SDK')
    return {'minimumOSVersion': version_string(minimum), 'linkedSDKVersion': version_string(sdk)}


def validate_extension(info, data, widget=False):
    declaration = info.get('NSExtension')
    if not isinstance(declaration, dict):
        raise ValueError('Missing NSExtension dictionary')
    point = declaration.get('NSExtensionPointIdentifier')
    if not isinstance(point, str) or not point:
        raise ValueError('Missing extension point identifier')
    if widget and point != WIDGET_POINT:
        raise ValueError('Widget must use the WidgetKit extension point')
    if point == WIDGET_POINT:
        _, platform, minimum, sdk = build_version(data)
        if platform != 2 or minimum < IOS_14 or sdk < IOS_14:
            raise ValueError('WidgetKit must declare iOS 14+ minimum and linked SDK')
        if tuple(map(int, info.get('MinimumOSVersion', '0').split('.'))) < (14, 0):
            raise ValueError('WidgetKit Info.plist must require iOS 14+')
        if info.get('DTPlatformName') != 'iphoneos' or info.get('CFBundleSupportedPlatforms') != ['iPhoneOS']:
            raise ValueError('Missing WidgetKit iPhoneOS platform metadata')
    elif not any(isinstance(declaration.get(key), str) and declaration[key].strip() for key in ('NSExtensionPrincipalClass', 'NSExtensionMainStoryboard')):
        raise ValueError('Extension has no principal class or main storyboard')
