"""Normalize WidgetKit's Swift entry point and deployment metadata after xtool linking."""
import struct

WIDGET_POINT = 'com.apple.widgetkit-extension'
IOS_14 = 14 << 16
IOS_SDK = (26 << 16) | (2 << 8)


def inspect(data):
    magic, cpu, _, kind, count, _, _, _ = struct.unpack_from('<8I', data)
    if (magic, cpu, kind) != (0xfeedfacf, 0x100000c, 2):
        raise ValueError('Expected arm64 Mach-O executable')
    offset = 32
    result = {}
    for _ in range(count):
        command, size = struct.unpack_from('<II', data, offset)
        if size < 8 or offset + size > len(data):
            raise ValueError('Malformed Mach-O load command')
        if command == 0x19:
            name = data[offset + 8:offset + 24].split(b'\0')[0]
            if name == b'__TEXT':
                result['textVM'], _, result['textFile'] = struct.unpack_from('<QQQ', data, offset + 24)
        elif command == 0x80000028:
            result['entryCommand'] = offset
            result['entryOffset'] = struct.unpack_from('<Q', data, offset + 8)[0]
        elif command == 0x32:
            result['buildCommand'] = offset
            result['platform'], result['minimum'], result['sdk'] = struct.unpack_from('<III', data, offset + 8)
        elif command == 0x2:
            result['symbols'] = struct.unpack_from('<IIII', data, offset + 8)
        offset += size
    if 'symbols' in result:
        symbols, count, strings, length = result['symbols']
        for i in range(count):
            index, symbol_type, _, _, address = struct.unpack_from('<IBBHQ', data, symbols + 16 * i)
            if index >= length:
                raise ValueError('Invalid Mach-O symbol string index')
            end = data.find(b'\0', strings + index, strings + length)
            if data[strings + index:end] == b'_main' and symbol_type & 0xe == 0xe:
                result['mainOffset'] = address - result['textVM'] + result['textFile']
                break
    return result


def normalize_widget(info, data):
    if info.get('NSExtension', {}).get('NSExtensionPointIdentifier') != WIDGET_POINT:
        return data
    parsed = inspect(data)
    for key in ('mainOffset', 'entryCommand', 'buildCommand'):
        if key not in parsed:
            raise ValueError(f'WidgetKit executable missing {key}')
    if parsed['platform'] != 2:
        raise ValueError('WidgetKit executable must target iOS')
    patched = bytearray(data)
    struct.pack_into('<Q', patched, parsed['entryCommand'] + 8, parsed['mainOffset'])
    struct.pack_into('<II', patched, parsed['buildCommand'] + 12, max(parsed['minimum'], IOS_14), IOS_SDK)
    # The binary is an application extension, not a host application.
    flags = struct.unpack_from('<I', patched, 24)[0]
    struct.pack_into('<I', patched, 24, flags | 0x02000000)
    info['MinimumOSVersion'] = '14.0'
    info['DTSDKName'] = 'iphoneos26.2'
    info['DTPlatformName'] = 'iphoneos'
    info['DTPlatformVersion'] = '26.2'
    info['CFBundleSupportedPlatforms'] = ['iPhoneOS']
    return bytes(patched)


def validate_extension(info, data):
    declaration = info.get('NSExtension')
    if not isinstance(declaration, dict):
        raise ValueError('Missing NSExtension dictionary')
    point = declaration.get('NSExtensionPointIdentifier')
    if not isinstance(point, str) or not point:
        raise ValueError('Missing extension point identifier')
    if point == WIDGET_POINT:
        parsed = inspect(data)
        if parsed.get('minimum', 0) < IOS_14 or parsed.get('sdk', 0) < IOS_14:
            raise ValueError('WidgetKit must declare iOS 14+ minimum and linked SDK')
        if tuple(map(int, info.get('MinimumOSVersion', '0').split('.'))) < (14, 0):
            raise ValueError('WidgetKit Info.plist must require iOS 14+')
        if 'mainOffset' not in parsed or parsed.get('entryOffset') != parsed['mainOffset']:
            raise ValueError('WidgetKit must launch its Swift @main entry point')
    elif not any(isinstance(declaration.get(key), str) and declaration[key].strip() for key in ('NSExtensionPrincipalClass', 'NSExtensionMainStoryboard')):
        raise ValueError('Extension has no principal class or main storyboard')
