#!/usr/bin/env python3
"""Export the full application graph for xtool without Apple Bazel toolchains.

Generated files and Package.swift live under build/xtool. Missing generators
are reported explicitly; preparation never substitutes empty implementation
files or silently removes an application extension.
"""

from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import subprocess
import sys

from graph import Graph, canonical
from runtime import adapt, METAL_HELPER


ROOT = Path(__file__).resolve().parents[2]
LIBRARIES = {"swift_library", "objc_library", "cc_library", "apple_static_xcframework_import"}
COMPILE_SUFFIXES = {".swift", ".m", ".mm", ".c", ".cc", ".cpp", ".cxx", ".s", ".S"}


def run(command, **kwargs):
    return subprocess.run(command, check=True, text=True, **kwargs)


def symlink(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    target = os.path.relpath(source, destination.parent)
    if destination.is_symlink() and os.readlink(destination) == target:
        return
    if destination.exists() and not destination.is_symlink():
        raise ValueError(f"Refusing to replace an existing file: {destination}")
    destination.unlink(missing_ok=True)
    destination.symlink_to(target)


def write_text_if_changed(path, content):
    if not path.exists() or path.read_text() != content:
        path.write_text(content)


def swift(value):
    return json.dumps(value, ensure_ascii=False)


class Exporter:
    def __init__(self, graph, output, root_label):
        self.graph = graph
        self.output = output.resolve()
        self.generated = self.output / "generated"
        self.root_label = root_label
        root_attrs = graph.attrs(root_label)
        self.apps = [root_label]
        if graph.rules[root_label]["kind"] == "ios_application":
            self.apps += root_attrs.get("extensions", [])
        self.closure = graph.closure(self.apps)
        self.names = {}
        for label in self.closure:
            rule = graph.rules[label]
            if rule["kind"] not in LIBRARIES:
                continue
            attrs = graph.attrs(label)
            name = attrs.get("module_name") or attrs["name"]
            name = re.sub(r"[^A-Za-z0-9_]", "_", name)
            if name in self.names.values():
                raise ValueError(f"Conflicting module name {name}: {label}")
            self.names[label] = name
        self.entry_names = {name for app in self.apps for name in self.dependencies(app)}
        self.missing = {}
        self.generators = set()
        self.resources = set()
        self.unsupported = set()

    def files(self, references, package):
        result = []
        for reference in references:
            label = canonical(reference, package)
            if self.graph.rules.get(label, {}).get("kind") == "apple_intent_library":
                intent_rule = self.graph.rules[label]
                self.generators.add(label)
                intent_path = self.generated / intent_rule["package"].removeprefix("//") / self.graph.attrs(label)["name"]
                intent_sources = sorted(intent_path.glob("*.swift"))
                if intent_sources:
                    result.extend((intent_rule["package"] + ":" + self.graph.attrs(label)["name"] + "/" + p.name, p) for p in intent_sources)
                else:
                    self.unsupported.add(f"Apple intentbuilderc sources have not been generated: {label}")
                continue
            try:
                expanded = self.graph.files(label)
            except ValueError as error:
                self.unsupported.add(str(error))
                continue
            for f in expanded:
                path = self.graph.source_path(f, self.generated)
                generator = self.graph.outputs.get(f)
                if generator:
                    self.generators.add(generator)
                if not path.exists():
                    self.missing[f] = generator
                result.append((f, path))
        return list(dict.fromkeys(result))

    def dependencies(self, label, seen=None):
        seen = set() if seen is None else seen
        if label in seen:
            raise ValueError(f"Dependency cycle through {label}")
        result = []
        for dep in self.graph.dependencies(label):
            if dep in self.names:
                result.append(self.names[dep])
            else:
                result.extend(self.dependencies(dep, seen | {label}))
        return sorted(set(result))

    def flag(self, flag):
        # Bazel's string-valued -D flags are shell-escaped. SwiftPM executes
        # clang directly; retain literal quotes, not the shell escape layers.
        while '\\"' in flag:
            flag = flag.replace('\\"', '"')
        if flag.startswith("-I") and len(flag) > 2 and not flag[2:].startswith("/"):
            return "-I" + str(ROOT / flag[2:])
        return flag

    def target(self, label):
        rule = self.graph.rules[label]
        attrs = self.graph.attrs(label)
        name = self.names[label]
        if rule["kind"] == "apple_static_xcframework_import":
            files = self.files(attrs.get("xcframework_imports", []), rule["package"])
            frameworks = {str(p).split(".xcframework/", 1)[0] + ".xcframework" for _, p in files if ".xcframework/" in str(p)}
            if len(frameworks) != 1:
                raise ValueError(f"Expected one XCFramework for {label}")
            destination = self.output / "Binaries" / (name + ".xcframework")
            symlink(Path(next(iter(frameworks))), destination)
            return f".binaryTarget(name: {swift(name)}, path: {swift(str(destination.relative_to(self.output)))})"

        target_dir = self.output / "Sources" / name
        target_dir.mkdir(parents=True, exist_ok=True)
        sources = self.files(attrs.get("srcs", []) + attrs.get("non_arc_srcs", []), rule["package"])
        if name == "absl":
            for relative in ("absl/hash/internal/low_level_hash.cc", "absl/synchronization/internal/kernel_timeout.cc", "absl/synchronization/mutex.cc", "absl/synchronization/internal/waiter_base.cc", "absl/synchronization/internal/pthread_waiter.cc", "absl/synchronization/internal/stdcpp_waiter.cc", "absl/synchronization/internal/sem_waiter.cc", "absl/synchronization/internal/futex_waiter.cc", "absl/flags/reflection.cc", "absl/flags/commandlineflag.cc", "absl/flags/internal/private_handle_accessor.cc"):
                source = ROOT / "third-party/webrtc/absl" / relative
                if source.is_file():
                    sources.append((rule["package"] + ":" + relative, source))
        headers = self.files(attrs.get("hdrs", []) + attrs.get("textual_hdrs", []), rule["package"])
        compile_files = []
        metal_adapter = False
        archives = []
        for source_label, source in sources + headers:
            # Preserve relative paths and segregate files from other packages.
            source_package, source_name = source_label.split(":", 1)
            relative = Path("ApplicationEntry.m") if label == "//Telegram:Main" and source_name.endswith("/main.m") else Path(source_name) if source_package == rule["package"] else Path("Foreign") / source_package.replace("//", "/").removeprefix("/") / source_name
            destination = target_dir / "Files" / relative
            metal_adapter = adapt(source, destination) or metal_adapter
            if not destination.exists():
                symlink(source, destination)
            if source.suffix in COMPILE_SUFFIXES and (source_label, source) in sources:
                if name == "OpusBinding" and source.suffix == ".c" and ("/Sources/ogg/" in str(source) or "/Sources/opusfile/" in str(source)):
                    continue
                if name == "webrtc_objc" and source.name == "gcd_helpers.m":
                    continue
                compile_files.append(str(destination.relative_to(target_dir)))
            if source.suffix == ".a":
                archives.append(str(source))

        if metal_adapter:
            write_text_if_changed(target_dir / "XToolMetal.swift", METAL_HELPER)
            compile_files.append("XToolMetal.swift")

        dependencies = self.dependencies(label)
        if name == "OpusBinding":
            dependencies = sorted(set(dependencies + ["ogg", "opusfile"]))
        if name == "webrtc_objc":
            dependencies = sorted(set(dependencies + ["webrtc_platform_helpers"]))
        args = [f"name: {swift(name)}", "dependencies: [" + ", ".join(swift(d) for d in dependencies) + "]", f"path: {swift(str(target_dir.relative_to(self.output)))}"]
        if compile_files:
            args.append("sources: [" + ", ".join(swift(x) for x in sorted(set(compile_files))) + "]")
        elif rule["kind"] == "swift_library":
            # A missing Apple source generator must not be replaced by a C
            # module with the same name: that would hide absent implementation.
            old_stub = target_dir / "archive.c"
            old_stub.unlink(missing_ok=True)
            args.append('sources: []')
            self.unsupported.add(f"No Swift sources exported for {label}")
        else:
            # Header/archive-only libraries need a real translation unit for
            # SwiftPM. The unit contains no replacement application behavior.
            write_text_if_changed(target_dir / "archive.c", "/* Header/archive-only Bazel library. */\n")
            args.append('sources: ["archive.c"]')

        flags = [self.flag(f) for f in attrs.get("copts", []) if f not in ("-warnings-as-errors", "-Werror")]
        if rule["kind"] == "swift_library":
            definitions = [f".define({swift(d)})" for d in attrs.get("defines", [])]
            if flags:
                definitions.append(".unsafeFlags(" + swift(flags) + ")")
            args.append("swiftSettings: [" + ", ".join(definitions) + "]")
            if attrs.get("generates_header"):
                self.unsupported.add(f"Swift Objective-C header emission needs an adapter: {label}")
        else:
            include_dir = target_dir / "include"
            include_dir.mkdir(exist_ok=True)
            existing_headers = {p for p in include_dir.rglob("*") if p.is_symlink()}
            desired_headers = set()
            public_headers = []
            for header_label, source in headers:
                source_name = header_label.split(":", 1)[1]
                relative = None
                for include in attrs.get("includes", []):
                    if include == ".":
                        relative = source_name
                        break
                    prefix = include.rstrip("/") + "/"
                    if source_name.startswith(prefix):
                        relative = source_name[len(prefix):]
                        break
                if relative is None:
                    relative = source_name
                    if source_name.startswith("PublicHeaders/"):
                        relative = source_name.removeprefix("PublicHeaders/")
                destination = include_dir / relative
                desired_headers.add(destination)
                symlink(source, destination)
                public_headers.append(relative)
            for obsolete in existing_headers - desired_headers:
                obsolete.unlink()
            if public_headers:
                module_attribute = " [extern_c]" if name in ("vpx", "opus", "webp", "mozjpeg", "dav1d", "ffmpeg") else ""
                header_kind = "textual header" if rule["kind"] == "cc_library" else "header"
                modulemap = f"module {name}{module_attribute} {{\n" + "".join(f"    {header_kind} {swift(h)}\n" for h in sorted(set(public_headers))) + "    export *\n}\n"
                write_text_if_changed(include_dir / "module.modulemap", modulemap)
            args.append('publicHeadersPath: "include"')
            flags += ["-I" + str(ROOT), "-I" + str(self.generated)]
            if rule["kind"] == "cc_library" or name == "SubcodecObjC":
                flags += ["-fno-modules"]
            for dependency_label in self.graph.closure([label]):
                dependency_rule = self.graph.rules[dependency_label]
                if dependency_rule["package"].startswith("@"):
                    continue
                pkg = dependency_rule["package"].split("//", 1)[1]
                for include in self.graph.attrs(dependency_label).get("includes", []):
                    flags += ["-I" + str(ROOT / pkg / include), "-I" + str(self.generated / pkg / include)]
            if rule["kind"] == "objc_library" and not attrs.get("non_arc_srcs"):
                flags += ["-fobjc-arc"]
            if attrs.get("non_arc_srcs"):
                self.unsupported.add(f"Mixed ARC/non-ARC sources need separate targets: {label}")
            definitions = []
            for define in attrs.get("defines", []) + attrs.get("local_defines", []):
                key, separator, value = define.partition("=")
                definitions.append(f".define({swift(key)}" + (f", to: {swift(value)}" if separator else "") + ")")
            settings = definitions + [".unsafeFlags(" + swift(flags) + ")"]
            args.append("cSettings: [" + ", ".join(settings) + "]")
            cxx_flags = [self.flag(x) for x in attrs.get("cxxopts", [])]
            if not any(x.startswith("-std=") for x in flags + cxx_flags):
                cxx_flags += ["-std=c++17"]
            args.append("cxxSettings: [" + ", ".join(definitions + [".unsafeFlags(" + swift(flags + cxx_flags) + ")"]) + "]")

        linker = [f".linkedFramework({swift("UIKit" if f == "UIKIt" else f)})" for f in attrs.get("sdk_frameworks", [])]
        linker += [f".linkedLibrary({swift(lib.removeprefix('lib'))})" for lib in attrs.get("sdk_dylibs", [])]
        weak = [arg for f in attrs.get("weak_sdk_frameworks", []) for arg in ["-Xlinker", "-weak_framework", "-Xlinker", f]]
        link_flags = archives + weak
        for option in attrs.get("linkopts", []):
            tokens = shlex.split(option)
            if tokens == ["-pthread"]:
                # Darwin pthread symbols live in libSystem; this is a Clang
                # driver option, not a Swift/ld64 linker option.
                continue
            if tokens and tokens[0] == "-framework" and len(tokens) == 2:
                linker.append(f".linkedFramework({swift(tokens[1])})")
            elif tokens and tokens[0] == "-weak_framework" and len(tokens) == 2:
                link_flags += ["-Xlinker", "-weak_framework", "-Xlinker", tokens[1]]
            else:
                link_flags += tokens
        if name in self.entry_names:
            # UIKit and extension loaders use Objective-C class names from
            # plists. Retain those class registration records in each product.
            runtime = Path.home() / ".swiftpm/swift-sdks/darwin.artifactbundle/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/17/lib/darwin/libclang_rt.ios.a"
            if not runtime.is_file():
                raise ValueError(f"Missing Apple iOS compiler runtime: {runtime}")
            link_flags += ["-Xlinker", "-ObjC", "-Xlinker", str(runtime), "-Xlinker", "--error-limit=0"]
        if link_flags:
            linker.append(".unsafeFlags(" + swift(link_flags) + ")")
        if linker:
            args.append("linkerSettings: [" + ", ".join(linker) + "]")
        self.resources.update(canonical(x, rule["package"]) for x in attrs.get("data", []))
        return ".target(\n            " + ",\n            ".join(args) + "\n        )"

    def info(self, label):
        rule = self.graph.rules[label]
        result = {}
        for reference in self.graph.attrs(label).get("infoplists", []):
            key = canonical(reference, rule["package"])
            fragment = self.graph.rules.get(key)
            if fragment and fragment["kind"] == "plist_fragment":
                attrs = self.graph.attrs(key)
                template = attrs["template"]
                for name, value in attrs.get("defaults", {}).items():
                    template = template.replace("{" + name + "}", str(value))
                content = ("<plist version=\"1.0\"><dict>" + template + "</dict></plist>").encode()
                result.update(plistlib.loads(content))
            else:
                files = self.files([reference], rule["package"])
                for f, path in files:
                    if path.exists():
                        result.update(plistlib.loads(path.read_bytes()))
        result["CFBundleIdentifier"] = self.graph.attrs(label)["bundle_id"]
        result.setdefault("CFBundleVersion", "1")
        result.setdefault("CFBundleShortVersionString", json.loads((ROOT / "versions.json").read_text())["app"])
        return result

    def export(self):
        self.output.mkdir(parents=True, exist_ok=True)
        targets = [self.target(label) for label in sorted(self.names)]
        products = []
        app_configs = []
        if self.graph.rules[self.root_label]["kind"] == "ios_application":
            for app in self.apps:
                attrs = self.graph.attrs(app)
                name = attrs["name"]
                products.append(f".library(name: {swift(name)}, targets: {swift(self.dependencies(app))})")
                info_path = name + "-Info.plist"
                (self.output / info_path).write_bytes(plistlib.dumps(self.info(app)))
                self.resources.update(canonical(x, self.graph.rules[app]["package"]) for x in attrs.get("data", []))
                app_config = {"product": name, "infoPath": info_path, "bundleID": attrs["bundle_id"]}
                entitlement_label = attrs.get("entitlements")
                if entitlement_label:
                    fragment_label = canonical(entitlement_label, self.graph.rules[app]["package"]).removesuffix(".entitlements")
                    if self.graph.rules.get(fragment_label, {}).get("kind") == "plist_fragment":
                        body = self.graph.attrs(fragment_label)["template"]
                        entitlement_path = name + ".entitlements"
                        (self.output / entitlement_path).write_bytes(plistlib.dumps(plistlib.loads(('<plist version="1.0"><dict>' + body + '</dict></plist>').encode())))
                        app_config["entitlementsPath"] = entitlement_path
                app_configs.append(app_config)
            config = {"version": 1, "bundleID": self.graph.attrs(self.root_label)["bundle_id"], **app_configs[0], "extensions": app_configs[1:]}
            # JSON is a subset of YAML; no third-party Python YAML package needed.
            (self.output / "xtool.yml").write_text(json.dumps(config, indent=2) + "\n")
        else:
            products = [f".library(name: {swift(self.names[self.root_label])}, targets: [{swift(self.names[self.root_label])}])"]
        manifest = "// swift-tools-version: 6.0\nimport PackageDescription\n\nlet package = Package(\n    name: \"SwiftgramXTool\",\n    platforms: [.iOS(.v13)],\n    products: [\n        " + ",\n        ".join(products) + "\n    ],\n    targets: [\n        " + ",\n        ".join(targets) + "\n    ],\n    swiftLanguageModes: [.v5]\n)\n"
        write_text_if_changed(self.output / "Package.swift", manifest)
        report = {
            "root": self.root_label, "configuration": "release_arm64", "ipaGenerated": False,
            "targets": len(self.names), "rules": dict(Counter(self.graph.rules[x]["kind"] for x in self.closure)),
            "missingFiles": self.missing, "requiredGenerators": sorted(self.generators),
            "resourceRules": sorted(self.resources), "unsupported": sorted(self.unsupported),
            "resourcePackagingComplete": False,
        }
        (self.output / "preparation-report.json").write_text(json.dumps(report, indent=2) + "\n")
        return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bazel", default=os.environ.get("BAZEL", "bazel"))
    parser.add_argument("--root", default="//Telegram:Swiftgram")
    parser.add_argument("--output", type=Path, default=ROOT / "build/xtool")
    parser.add_argument("--query-file", type=Path)
    parser.add_argument("--without-extensions", action="store_true")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    output_base = Path(run([args.bazel, "info", "output_base"], cwd=ROOT, capture_output=True).stdout.strip())
    query_file = args.query_file or args.output / "rules.star"
    if args.query_file is None:
        with query_file.open("w") as stream:
            run([args.bazel, "query", f"deps({args.root})", "--output=build", "--noshow_progress", "--color=no"], cwd=ROOT, stdout=stream)
    graph = Graph(query_file.read_text(), ROOT, output_base, extensions=not args.without_extensions)
    exporter = Exporter(graph, args.output, args.root)
    report = exporter.export()
    print(f"Exported {report['targets']} library targets to {args.output}")
    print(f"Missing generated files: {len(report['missingFiles'])}; unsupported adapters: {len(report['unsupported'])}")
    print(f"Preparation report: {args.output / 'preparation-report.json'}")
    print("Resource packaging is incomplete. This is not yet a buildable IPA application.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, subprocess.CalledProcessError) as error:
        print(f"Preparation failed: {error}", file=sys.stderr)
        sys.exit(1)
