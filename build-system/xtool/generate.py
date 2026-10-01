#!/usr/bin/env python3
"""Run portable source generators from the exported application graph.

Output paths are contained in build/xtool/generated. Apple-only generators
and cross-compiled codec archives require their own adapters and fail clearly.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys

from graph import Graph, canonical
from prepare import ROOT


PORTABLE = {
    "GeneratedPresentationStrings", "VersionInfoPlist", "empty",
    "copy_ssl_headers", "copy_opus_headers", "generate_field_trials_header",
    "copy_public_headers", "GenerateModels",
}


class Generator:
    def __init__(self, graph, output, jobs):
        self.graph = graph
        self.output = output.resolve()
        self.generated = self.output / "generated"
        self.jobs = jobs
        self.visiting = set()
        self.completed = set()

    def flatc(self):
        """Build the exact schema compiler version required by this repository."""
        source = self.output / "host-tools/flatbuffers-24.12.23"
        build = self.output / "host-tools/flatbuffers-build"
        binary = build / "flatc"
        if binary.is_file():
            return binary
        archive = self.output / "host-tools/flatbuffers-24.12.23.tar.gz"
        archive.parent.mkdir(parents=True, exist_ok=True)
        if not archive.exists():
            subprocess.run([
                "curl", "-fL", "--silent", "--show-error",
                "https://github.com/google/flatbuffers/archive/refs/tags/v24.12.23.tar.gz",
                "-o", str(archive),
            ], check=True)
        if not source.exists():
            # The upstream tag is fixed, and the archive is extracted only into
            # the disposable host-tools directory, never the source tree.
            subprocess.run(["tar", "-xzf", str(archive), "-C", str(archive.parent)], check=True)
        environment = os.environ | {"CC": "/usr/bin/cc", "CXX": "/usr/bin/c++"}
        subprocess.run([
            "cmake", "-S", str(source), "-B", str(build), "-G", "Ninja",
            "-DCMAKE_BUILD_TYPE=Release", "-DFLATBUFFERS_BUILD_TESTS=OFF",
            "-DFLATBUFFERS_BUILD_FLATLIB=OFF", "-DFLATBUFFERS_BUILD_FLATHASH=OFF",
            "-DFLATBUFFERS_INSTALL=OFF",
        ], env=environment, check=True)
        subprocess.run(["cmake", "--build", str(build), "--target", "flatc", "-j", str(self.jobs)], env=environment, check=True)
        return binary

    def file(self, label):
        label = canonical(label)
        if label == "//third-party/flatc:flatc_bin":
            return self.flatc()
        path = self.graph.source_path(label, self.generated)
        generator = self.graph.outputs.get(label)
        if generator and not path.exists():
            self.generate(generator)
        if not path.exists():
            raise ValueError(f"Required generator input does not exist: {label} ({path})")
        return path

    def relative(self, path):
        # Several existing commands prepend $(pwd) to location/RULEDIR, so
        # substitutions must remain relative to the execution working directory.
        return os.path.relpath(path, ROOT)

    def generate(self, label):
        label = canonical(label)
        if label in self.completed:
            return
        if label in self.visiting:
            raise ValueError(f"Generator dependency cycle: {label}")
        self.visiting.add(label)
        rule = self.graph.rules[label]
        attrs = self.graph.attrs(label)
        name = attrs["name"]
        if rule["kind"] != "genrule" or not (name in PORTABLE or name.startswith("Localizable_")):
            raise ValueError(f"Generator adapter not implemented: {label} ({rule['kind']})")
        package = rule["package"]
        outputs = [self.graph.source_path(canonical(x, package), self.generated) for x in attrs["outs"]]
        for path in outputs:
            path.parent.mkdir(parents=True, exist_ok=True)
        command = attrs.get("cmd_bash") or attrs.get("cmd")
        if not command:
            raise ValueError(f"Missing generator command for {label}")
        inputs = []

        def expand(match):
            expression = match.group(1)
            if expression == "OUTS":
                return " ".join(shlex.quote(self.relative(p)) for p in outputs)
            if expression == "SRCS":
                paths = [self.file(f) for x in attrs.get("srcs", []) for f in self.graph.files(canonical(x, package))]
                inputs.extend(paths)
                return " ".join(shlex.quote(self.relative(p)) for p in paths)
            if expression in ("RULEDIR", "@D"):
                path = self.generated / package.removeprefix("//")
                if expression == "@D" and len(outputs) == 1:
                    path = outputs[0].parent
                path.mkdir(parents=True, exist_ok=True)
                return self.relative(path)
            if expression == "TARGET_CPU":
                return "ios_arm64"
            if expression.startswith(("location ", "locations ")):
                multiple, reference = expression.split(" ", 1)
                reference = canonical(reference, package)
                paths = []
                for f in self.graph.files(reference):
                    if f in self.graph.outputs and self.graph.outputs[f] == label:
                        p = self.graph.source_path(f, self.generated)
                    else:
                        p = self.file(f)
                        inputs.append(p)
                    paths.append(self.relative(p))
                if multiple == "location" and len(paths) != 1:
                    raise ValueError(f"Expected one location for {reference}, got {len(paths)}")
                # Existing genrules sometimes quote $(location) themselves;
                # location paths here contain no whitespace. Do not add a
                # second layer of shell quoting.
                if any(re.search(r"[^A-Za-z0-9_./+:-]", p) for p in paths):
                    raise ValueError("Generator path needs explicit whitespace-safe adaptation")
                return " ".join(paths)
            raise ValueError(f"Unsupported Bazel command substitution: $({expression})")

        # Protect shell substitutions written as $$(...) before expanding Bazel
        # substitutions. Bash receives exactly one dollar afterwards.
        command = command.replace("$$", "\x00")
        command = re.sub(r"\$\(([^()]*)\)", expand, command)
        if len(outputs) == 1:
            command = command.replace("$@", self.relative(outputs[0]))
        command = command.replace("\x00", "$")
        stamp_dir = self.output / "generator-stamps"
        stamp_dir.mkdir(exist_ok=True)
        stamp = stamp_dir / (hashlib.sha256(label.encode()).hexdigest() + ".json")
        fingerprints = {str(p): {"size": p.stat().st_size, "mtimeNs": p.stat().st_mtime_ns} for p in inputs}
        signature = {"command": command, "inputs": fingerprints}
        if stamp.exists() and json.loads(stamp.read_text()) == signature and all(p.exists() for p in outputs):
            self.completed.add(label)
            self.visiting.remove(label)
            return
        print(f"Generating {label}", flush=True)
        log_dir = self.output / "logs"
        log_dir.mkdir(exist_ok=True)
        log = log_dir / (re.sub(r"[^a-zA-Z0-9_.-]", "_", label) + ".log")
        with log.open("w") as stream:
            result = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", command], cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT)
        if result.returncode:
            raise ValueError(f"Generator failed: {label}; see {log}")
        missing = [str(p) for p in outputs if not p.exists()]
        if missing:
            raise ValueError(f"Generator did not produce declared outputs: {missing}")
        stamp.write_text(json.dumps(signature, indent=2) + "\n")
        self.completed.add(label)
        self.visiting.remove(label)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bazel", default=os.environ.get("BAZEL", "bazel"))
    parser.add_argument("--output", type=Path, default=ROOT / "build/xtool")
    parser.add_argument("--query-file", type=Path)
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("labels", nargs="*")
    args = parser.parse_args()
    base = subprocess.run([args.bazel, "info", "output_base"], cwd=ROOT, check=True, capture_output=True, text=True).stdout.strip()
    query = args.query_file or args.output / "rules.star"
    graph = Graph(query.read_text(), ROOT, Path(base))
    generator = Generator(graph, args.output, args.jobs)
    report = json.loads((args.output / "preparation-report.json").read_text())
    labels = args.labels or [x for x in report["requiredGenerators"] if graph.attrs(x)["name"] in PORTABLE]
    failures = []
    for label in labels:
        try:
            generator.generate(label)
        except ValueError as error:
            failures.append(str(error))
            generator.visiting.clear()
    for message in failures:
        print(message, file=sys.stderr)
    if failures:
        sys.exit(1)
    print(f"Verified {len(generator.completed)} portable generators.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, subprocess.CalledProcessError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
