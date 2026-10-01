import ast
import struct
from pathlib import Path
import tempfile
import unittest

from clang_compat import arguments
from graph import Graph, canonical, literal
from linux_resources import LinuxResources
from runtime import adapt
from extensions import inspect, normalize_widget, validate_extension


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

class ExtensionEntryTests(unittest.TestCase):
    def widget_binary(self):
        data = bytearray(512)
        struct.pack_into('<8I', data, 0, 0xfeedfacf, 0x100000c, 0, 2, 4, 152, 0, 0)
        struct.pack_into('<II16sQQQQIIII', data, 32, 0x19, 72, b'__TEXT', 0x100000000, 512, 0, 512, 7, 5, 0, 0)
        struct.pack_into('<IIQQ', data, 104, 0x80000028, 24, 128, 0)
        struct.pack_into('<8I', data, 128, 0x32, 32, 2, 13 << 16, 13 << 16, 1, 3, 21 << 16)
        struct.pack_into('<6I', data, 160, 2, 24, 192, 1, 208, 7)
        struct.pack_into('<IBBHQ', data, 192, 1, 0xf, 1, 0, 0x100000100)
        data[208:215] = b'\0_main\0'
        return bytes(data)

    def widget_info(self):
        return {'MinimumOSVersion': '13.0', 'NSExtension': {'NSExtensionPointIdentifier': 'com.apple.widgetkit-extension'}}

    def test_previous_widget_package_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'iOS 14'):
            validate_extension(self.widget_info(), self.widget_binary())

    def test_widget_uses_real_swift_main_and_modern_sdk(self):
        info = self.widget_info()
        data = normalize_widget(info, self.widget_binary())
        parsed = inspect(data)
        self.assertEqual(parsed['entryOffset'], 256)
        self.assertEqual(parsed['minimum'], 14 << 16)
        self.assertEqual(parsed['sdk'], (26 << 16) | (2 << 8))
        self.assertEqual(info['MinimumOSVersion'], '14.0')
        self.assertTrue(struct.unpack_from('<I', data, 24)[0] & 0x02000000)
        validate_extension(info, data)
        self.assertEqual(normalize_widget(info, data), data)

    def test_widget_without_compiled_swift_main_is_rejected(self):
        data = self.widget_binary().replace(b'_main', b'_none')
        with self.assertRaisesRegex(ValueError, 'mainOffset'):
            normalize_widget(self.widget_info(), data)

    def test_class_based_extension_requires_string_entry(self):
        info = {'NSExtension': {'NSExtensionPointIdentifier': 'com.apple.share-services'}}
        with self.assertRaisesRegex(ValueError, 'principal class'):
            validate_extension(info, b'')
        info['NSExtension']['NSExtensionPrincipalClass'] = 'ShareRootController'
        validate_extension(info, b'')


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
