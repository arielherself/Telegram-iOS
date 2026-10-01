import ast
from pathlib import Path
import tempfile
import unittest

from clang_compat import arguments
from graph import Graph, canonical, literal
from linux_resources import LinuxResources
from runtime import adapt


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
