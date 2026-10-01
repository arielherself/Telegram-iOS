import ast
import ctypes
from pathlib import Path
import plistlib
import struct
import subprocess
import tempfile
import unittest

from clang_compat import arguments
from graph import Graph, canonical, literal
from linux_resources import LinuxResources
from runtime import adapt
from extensions import build_version, normalize_bundle, normalize_widget, validate_build_metadata, validate_extension


class MessageHistoryDiffTests(unittest.TestCase):
    def test_full_text_unicode_and_diff_projections(self):
        root = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            main = folder / 'main.swift'
            main.write_text((Path(__file__).parent / 'tests/message_history_diff.swift').read_text())
            subprocess.run(['swiftc', str(root / 'submodules/TelegramCore/Sources/Utils/ArielgramTextDiff.swift'), str(main), '-o', str(folder / 'tests')], check=True, capture_output=True)
            subprocess.run([str(folder / 'tests')], check=True, capture_output=True)


class ExtensionMetadataTests(unittest.TestCase):
    def binary(self):
        data = bytearray(128)
        struct.pack_into('<8I', data, 0, 0xfeedfacf, 0x100000c, 0, 2, 2, 56, 0, 0)
        struct.pack_into('<IIQQ', data, 32, 0x80000028, 24, 96, 0)
        struct.pack_into('<8I', data, 56, 0x32, 32, 2, 13 << 16, 13 << 16, 1, 3, 21 << 16)
        return bytes(data)

    def info(self):
        return {'MinimumOSVersion': '13.0', 'NSExtension': {'NSExtensionPointIdentifier': 'com.apple.widgetkit-extension'}}

    def test_metadata_correction_preserves_entry_point_and_flags(self):
        original = self.binary()
        info = self.info()
        fixed = normalize_widget(info, original, '26.2')
        self.assertEqual(fixed[:68], original[:68])
        self.assertEqual(fixed[76:], original[76:])
        self.assertEqual(build_version(fixed)[2:], (14 << 16, (26 << 16) | (2 << 8)))
        self.assertEqual(info['MinimumOSVersion'], '14.0')
        self.assertEqual(info['DTSDKName'], 'iphoneos26.2')
        validate_extension(info, fixed, widget=True)
        self.assertEqual(normalize_widget(info, fixed, '26.2'), fixed)

    def test_old_widget_metadata_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'iOS 14'):
            validate_extension(self.info(), self.binary(), widget=True)

    def test_host_sdk_correction_preserves_minimum_and_executable(self):
        original = self.binary()
        info = {'MinimumOSVersion': '13.0', 'CFBundleIdentifier': 'xyz.arielherself.Arielgram'}
        fixed = normalize_bundle(info, original, '26.2')
        self.assertEqual(fixed[:72], original[:72])
        self.assertEqual(fixed[76:], original[76:])
        self.assertEqual(build_version(fixed)[2:], (13 << 16, (26 << 16) | (2 << 8)))
        self.assertEqual(info['CFBundleIdentifier'], 'xyz.arielherself.Arielgram')
        self.assertEqual(validate_build_metadata(info, fixed, '26.2'), {'minimumOSVersion': '13.0', 'linkedSDKVersion': '26.2'})
        self.assertEqual(normalize_bundle(info, fixed, '26.2'), fixed)

    def test_class_based_extension_keeps_its_entry_and_higher_minimum(self):
        original = bytearray(self.binary())
        struct.pack_into('<I', original, 68, 17 << 16)
        info = {'NSExtension': {'NSExtensionPointIdentifier': 'com.apple.share-services', 'NSExtensionPrincipalClass': 'ShareRootController'}}
        fixed = normalize_bundle(info, bytes(original), '26.2')
        self.assertEqual(info['MinimumOSVersion'], '17.0')
        self.assertEqual(build_version(fixed)[2], 17 << 16)
        validate_extension(info, fixed)
        validate_build_metadata(info, fixed, '26.2')

    def test_build_validation_rejects_wrong_or_inconsistent_sdk(self):
        info = {}
        fixed = normalize_bundle(info, self.binary(), '26.2')
        old_info = {}
        old_binary = normalize_bundle(old_info, self.binary(), '13.0')
        with self.assertRaisesRegex(ValueError, 'build SDK'):
            validate_build_metadata(old_info, old_binary, '26.2')
        with self.assertRaises(ValueError):
            validate_build_metadata({**info, 'DTSDKName': 'iphoneos13.0'}, fixed)
        with self.assertRaises(ValueError):
            validate_build_metadata({**info, 'MinimumOSVersion': '14.0'}, fixed)

    def test_non_ios_or_older_sdk_is_rejected(self):
        original = bytearray(self.binary())
        struct.pack_into('<I', original, 64, 7)
        with self.assertRaisesRegex(ValueError, 'target iOS'):
            normalize_bundle({}, bytes(original), '26.2')
        with self.assertRaisesRegex(ValueError, 'older than'):
            normalize_bundle({}, self.binary(), '12.0')

    def test_today_extension_cannot_replace_widgetkit(self):
        info = {'NSExtension': {'NSExtensionPointIdentifier': 'com.apple.widget-extension', 'NSExtensionPrincipalClass': 'TodayViewController'}}
        with self.assertRaisesRegex(ValueError, 'WidgetKit extension point'):
            validate_extension(info, self.binary(), widget=True)

    def test_class_based_extension_requires_string_entry(self):
        info = {'NSExtension': {'NSExtensionPointIdentifier': 'com.apple.share-services'}}
        with self.assertRaisesRegex(ValueError, 'principal class'):
            validate_extension(info, b'')
        info['NSExtension']['NSExtensionPrincipalClass'] = 'ShareRootController'
        validate_extension(info, b'')


class SignedEntitlementsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        folder = Path(cls.directory.name)
        header = Path(__file__).resolve().parents[2] / 'submodules/BuildConfig/PublicHeaders/BuildConfig/SignedEntitlements.h'
        source = folder / 'reader.c'
        source.write_text('#include "SignedEntitlements.h"\nconst unsigned char *read_entitlements(const unsigned char *bytes, size_t length, size_t *xmlLength) { return BCSignedEntitlements(bytes, length, xmlLength); }\n')
        subprocess.run(['cc', '-shared', '-fPIC', '-Wall', '-Wextra', '-Werror', '-I' + str(header.parent), str(source), '-o', str(folder / 'reader.so')], check=True)
        cls.library = ctypes.CDLL(str(folder / 'reader.so'))
        cls.read = cls.library.read_entitlements
        cls.read.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]
        cls.read.restype = ctypes.c_void_p

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def binary(self, permissions):
        xml = plistlib.dumps(permissions)
        signature = struct.pack('>5I', 0xfade0cc0, 28 + len(xml), 1, 5, 20) + struct.pack('>2I', 0xfade7171, 8 + len(xml)) + xml
        header = struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 2, 1, 16, 0, 0)
        return header + struct.pack('<4I', 0x1d, 16, 48, len(signature)) + signature

    def parse(self, data):
        length = ctypes.c_size_t()
        xml = self.read(data, len(data), ctypes.byref(length))
        return plistlib.loads(ctypes.string_at(xml, length.value)) if xml else None

    def test_capabilities_come_from_current_signature(self):
        cloud = {'com.apple.developer.icloud-services': ['CloudKit'], 'com.apple.developer.icloud-container-identifiers': ['iCloud.xyz.arielherself.Arielgram']}
        self.assertEqual(self.parse(self.binary(cloud)), cloud)
        self.assertEqual(self.parse(self.binary({'application-identifier': 'TEAM.xyz.arielherself.Arielgram'})), {'application-identifier': 'TEAM.xyz.arielherself.Arielgram'})

    def test_truncated_or_out_of_bounds_signature_is_rejected(self):
        binary = self.binary({})
        for size in range(len(binary)):
            self.assertIsNone(self.parse(binary[:size]))
        for offset, format in ((20, '<I'), (36, '<I'), (40, '<I'), (52, '>I'), (56, '>I'), (64, '>I'), (72, '>I')):
            corrupt = bytearray(binary)
            struct.pack_into(format, corrupt, offset, 0xffffffff)
            self.assertIsNone(self.parse(bytes(corrupt)), f'offset {offset}')


class GraphTests(unittest.TestCase):
    def graph(self, rules):
        return Graph('# /tmp/project/BUILD:1:1\n' + rules, Path('/tmp/project'), Path('/tmp/bazel'))

    def test_device_release_select(self):
        graph = self.graph('''
config_setting(name="release", values={"compilation_mode": "opt", "cpu": "ios_arm64"})
config_setting(name="debug", values={"compilation_mode": "dbg"})
swift_library(name="Main", srcs=["base.swift"] + select({"//:release": ["device.swift"], "//:debug": ["debug.swift"]}))
''')
        self.assertEqual(graph.attrs('//:Main')['srcs'], ['base.swift', 'device.swift'])

    def test_ambiguous_selection_rejected(self):
        graph = self.graph('''
config_setting(name="arm", values={"cpu": "ios_arm64"})
config_setting(name="release", values={"compilation_mode": "opt"})
swift_library(name="Main", srcs=select({"//:arm": ["a.swift"], "//:release": ["b.swift"]}))
''')
        with self.assertRaisesRegex(ValueError, 'Ambiguous'):
            graph.attrs('//:Main')

    def test_query_cannot_execute_code(self):
        with self.assertRaises(ValueError):
            literal(ast.parse('__import__("os").system("true")', mode='eval').body)

    def test_canonical_repository_identity(self):
        self.assertEqual(canonical('@@rules_swift+//swift:swift'), '@rules_swift//swift:swift')
        self.assertNotEqual(canonical('@@rules_swift++a+repo//:x'), canonical('@@rules_swift++b+repo//:x'))


class ShaderTests(unittest.TestCase):
    def test_shared_header_inlined_once_and_nv12_types_separated(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            (folder / 'shared.h').write_text('#pragma once\nstruct Shared {};\n')
            files = []
            for name in ('I420VideoShaders.metal', 'NV12VideoShaders.metal'):
                path = folder / name
                path.write_text('#include "shared.h"\ntypedef struct { int x; } Vertex;\n')
                files.append(path)
            source = LinuxResources.shader_source(None, files)
            self.assertEqual(source.count('struct Shared'), 1)
            self.assertIn('NV12Vertex;', source)
            self.assertNotIn('#include "', source)

class ResourceCopyTests(unittest.TestCase):
    def resource(self):
        resource = object.__new__(LinuxResources)
        resource.alternate_icons = {}
        return resource

    def test_changed_resource_replaces_previous_build(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            source = folder / 'source.txt'
            target = folder / 'output'
            source.write_text('old brand')
            resource = self.resource()
            resource.pack_files([source], target)
            source.write_text('new brand')
            resource.pack_files([source], target)
            self.assertEqual((target / source.name).read_text(), 'new brand')

    def test_conflicting_inputs_still_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            sources = []
            for name in ('a', 'b'):
                source = folder / name / 'same.txt'
                source.parent.mkdir()
                source.write_text(name)
                sources.append(source)
            with self.assertRaisesRegex(ValueError, 'Resource collision'):
                self.resource().pack_files(sources, folder / 'output')


class RuntimeTests(unittest.TestCase):
    def test_application_branch_and_incremental_output(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'source.swift'
            target = Path(directory) / 'export.swift'
            source.write_text('#if SWIFT_PACKAGE\nlet preview = true\n#else\nlet app = true\n#endif\n')
            adapt(source, target)
            self.assertIn('#if false', target.read_text())
            timestamp = target.stat().st_mtime_ns
            adapt(source, target)
            self.assertEqual(timestamp, target.stat().st_mtime_ns)

    def test_endianness_uses_target_compiler_macros(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'stream.m'
            target = Path(directory) / 'export.m'
            source.write_text('#import <endian.h>\n#if __BYTE_ORDER == __LITTLE_ENDIAN\n#endif\n')
            adapt(source, target)
            self.assertIn('machine/endian.h', target.read_text())
            self.assertIn('__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__', target.read_text())

class CompilerArgumentsTests(unittest.TestCase):
    def test_mixed_language_dialects(self):
        for extension in ('.c', '.m'):
            result = arguments(['-std=c++17', '-DTEST=1', '-c', 'source' + extension])
            self.assertNotIn('-std=c++17', result)
            self.assertIn('-DTEST=1', result)
        for extension in ('.cpp', '.mm'):
            self.assertIn('-std=c++2b', arguments(['-std=c++2b', '-c', 'source' + extension]))

    def test_response_file_quoting(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'args.rsp'
            path.write_text('-std=c++17 -I"folder with spaces" -c source.m')
            result = arguments(['@' + str(path)])
            self.assertIn('-Ifolder with spaces', result)
            self.assertNotIn('-std=c++17', result)

    def test_module_scanning_flags_retained(self):
        self.assertEqual(arguments(['-std=c++2b', '-fsyntax-only', 'header.h']), ['-std=c++2b', '-fsyntax-only', 'header.h'])

if __name__ == '__main__':
    unittest.main()
