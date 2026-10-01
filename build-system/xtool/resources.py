#!/usr/bin/env python3
"""Compile the application's Apple resources without compiling application code.

This step requires macOS/Xcode's actool, ibtool, metal and intentbuilderc. The
result is a portable archive consumed by the Linux xtool preparation step.
"""

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

from generate import Generator
from graph import Graph, canonical
from prepare import Exporter, ROOT


class Resources:
    def __init__(self, graph, output):
        self.graph = graph
        self.output = output.resolve()
        self.exporter = Exporter(graph, output, "//Telegram:Swiftgram")
        self.generator = Generator(graph, output, 4)
        self.inputs = set()
        self.tools = set()

    def files(self, label):
        label = canonical(label)
        if label in self.graph.outputs:
            path = self.generator.file(label)
            self.inputs.add(path)
            return [path]
        rule = self.graph.rules.get(label)
        if rule and rule["kind"] in ("filegroup", "apple_resource_group"):
            attrs = self.graph.attrs(label)
            return [p for field in ("srcs", "resources") for reference in attrs.get(field, []) for p in self.files(canonical(reference, rule["package"]))]
        if rule:
            raise ValueError(f"Unhandled resource rule: {label} ({rule['kind']})")
        path = self.graph.source_path(label, self.output / "generated")
        if not path.exists():
            raise ValueError(f"Missing resource input: {path}")
        self.inputs.add(path)
        return [path]

    def plan(self):
        references = set()
        for label in self.exporter.closure:
            rule = self.graph.rules[label]
            attrs = self.graph.attrs(label)
            for attr in ("data", "resources", "strings", "app_icons", "alternate_icons"):
                references.update(canonical(x, rule["package"]) for x in attrs.get(attr, []))
        bundles = {}
        files = []
        for label in sorted(references):
            rule = self.graph.rules.get(label)
            if rule and rule["kind"] == "apple_resource_bundle":
                attrs = self.graph.attrs(label)
                bundles[label] = [p for reference in attrs.get("resources", []) for p in self.files(canonical(reference, rule["package"]))]
            else:
                files.extend(self.files(label))
        for label in self.exporter.closure:
            rule = self.graph.rules[label]
            for reference in self.graph.attrs(label).get("srcs", []):
                reference = canonical(reference, rule["package"])
                if self.graph.rules.get(reference, {}).get("kind") == "apple_intent_library":
                    attrs = self.graph.attrs(reference)
                    source = self.graph.source_path(canonical(attrs["src"], self.graph.rules[reference]["package"]), self.output / "generated")
                    self.inputs.add(source)
                    self.tools.add("intentbuilderc")
        for path in files + [p for collection in bundles.values() for p in collection]:
            if ".xcassets/" in str(path) or ".icon/" in str(path):
                self.tools.add("actool")
            if path.suffix == ".metal":
                self.tools.update(["metal", "metallib"])
            if path.suffix in (".xib", ".storyboard"):
                self.tools.add("ibtool")
        return bundles, sorted(set(files))

    def command(self, tool, arguments):
        subprocess.run(["xcrun", "--sdk", "iphoneos", tool] + [str(x) for x in arguments], check=True)

    def pack_files(self, files, destination, name=None):
        destination.mkdir(parents=True, exist_ok=True)
        catalogs = set()
        metal = []
        for source in files:
            text = str(source)
            for suffix in (".xcassets", ".icon"):
                if suffix + "/" in text:
                    catalogs.add(Path(text.split(suffix + "/", 1)[0] + suffix))
                    break
            else:
                if source.suffix == ".metal":
                    metal.append(source)
                    continue
                locale = next((part for part in source.parts if part.endswith(".lproj")), None)
                folder = destination / locale if locale else destination
                folder.mkdir(exist_ok=True)
                if source.suffix in (".xib", ".storyboard"):
                    extension = ".nib" if source.suffix == ".xib" else ".storyboardc"
                    self.command("ibtool", ["--compile", folder / (source.stem + extension), "--minimum-deployment-target", "13.0", "--target-device", "iphone", "--target-device", "ipad", source])
                else:
                    target = folder / source.name
                    if target.exists() and target.read_bytes() != source.read_bytes():
                        raise ValueError(f"Resource basename collision: {source} -> {target}")
                    shutil.copy2(source, target)
        if catalogs:
            partial = destination / "asset-info.plist"
            args = ["--compile", destination, "--platform", "iphoneos", "--minimum-deployment-target", "13.0", "--target-device", "iphone", "--target-device", "ipad", "--output-partial-info-plist", partial]
            if name:
                args += ["--app-icon", name]
            self.command("actool", args + sorted(catalogs))
        if metal:
            intermediates = self.output / "metal-intermediates" / destination.name
            intermediates.mkdir(parents=True, exist_ok=True)
            objects = []
            for source in sorted(set(metal)):
                obj = intermediates / (hashlib.sha256(str(source).encode()).hexdigest() + ".air")
                self.command("metal", ["-c", "-target", "air64-apple-ios13.0", "-ffast-math", "-o", obj, source])
                objects.append(obj)
            self.command("metallib", ["-o", destination / "default.metallib"] + objects)

    def compile(self, bundles, files):
        for tool in sorted(self.tools):
            if shutil.which("xcrun") is None:
                raise ValueError(f"Apple resource compiler required: {tool}. This step needs macOS/Xcode.")
            subprocess.run(["xcrun", "--sdk", "iphoneos", "--find", tool], check=True, stdout=subprocess.DEVNULL)
        resources = self.output / "resources"
        if resources.exists():
            # This is a generated output owned by this adapter.
            shutil.rmtree(resources)
        resources.mkdir()
        icons = self.graph.attrs("//Telegram:Swiftgram").get("app_icons", [])
        icon_name = None
        if icons:
            candidates = [p for x in icons for p in self.files(canonical(x, "//Telegram"))]
            icon_names = {Path(str(p).split(".icon/", 1)[0]).stem for p in candidates if ".icon/" in str(p)}
            if len(icon_names) == 1:
                icon_name = next(iter(icon_names))
        self.pack_files(files, resources, icon_name)
        for label, collection in bundles.items():
            rule = self.graph.rules[label]
            attrs = self.graph.attrs(label)
            directory = resources / (attrs["name"] + ".bundle")
            self.pack_files(collection, directory)
            info = {"CFBundlePackageType": "BNDL", "CFBundleName": attrs["name"]}
            for reference in attrs.get("infoplists", []):
                fragment = self.graph.attrs(canonical(reference, rule["package"]))
                info.update(plistlib.loads(("<plist version=\"1.0\"><dict>" + fragment["template"] + "</dict></plist>").encode()))
            (directory / "Info.plist").write_bytes(plistlib.dumps(info))
        for label in self.exporter.closure:
            rule = self.graph.rules[label]
            for reference in self.graph.attrs(label).get("srcs", []):
                reference = canonical(reference, rule["package"])
                intent_rule = self.graph.rules.get(reference)
                if not intent_rule or intent_rule["kind"] != "apple_intent_library":
                    continue
                attrs = self.graph.attrs(reference)
                source = self.graph.source_path(canonical(attrs["src"], intent_rule["package"]), self.output / "generated")
                destination = self.output / "generated" / intent_rule["package"].removeprefix("//") / attrs["name"]
                destination.mkdir(parents=True, exist_ok=True)
                self.command("intentbuilderc", ["generate", "-input", source, "-language", "Swift", "-classPrefix", attrs.get("class_prefix", ""), "-swiftVersion", "5.0", "-visibility", "public", "-output", destination])
        # The source-input hashes make a downloaded resource archive reviewable
        # and allow the Linux importer to reject assets from a different tree.
        fingerprints = {p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(self.inputs)}
        (self.output / "resource-status.json").write_text(json.dumps({"complete": True, "inputs": fingerprints, "tools": sorted(self.tools)}, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bazel", required=True)
    parser.add_argument("--output", type=Path, default=ROOT / "build/xtool")
    parser.add_argument("--query-file", type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    base = subprocess.run([args.bazel, "info", "output_base"], cwd=ROOT, check=True, capture_output=True, text=True).stdout.strip()
    graph = Graph((args.query_file or args.output / "rules.star").read_text(), ROOT, Path(base))
    resource = Resources(graph, args.output)
    bundles, files = resource.plan()
    print(f"Resource plan: {len(bundles)} bundles, {len(files)} top-level files")
    print("Required Apple tools: " + ", ".join(sorted(resource.tools)))
    if not args.check:
        resource.compile(bundles, files)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, subprocess.CalledProcessError) as error:
        print(f"Resource compilation failed: {error}", file=sys.stderr)
        sys.exit(1)
