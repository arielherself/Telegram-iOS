#!/usr/bin/env python3
"""Create the unsigned, query-only Bazel configuration for dependency export."""

import argparse
import json
from pathlib import Path
import shutil
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "build-system/Make"))
from BuildConfiguration import build_configuration_from_json


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bazel", required=True)
    parser.add_argument("--configuration", type=Path, default=ROOT / "build-system/appstore-configuration.json")
    args = parser.parse_args()
    config = json.loads(args.configuration.read_text())
    # Query needs the variable to evaluate BuildConfig flags, even though no
    # binary is compiled here. Production configuration must supply sg_config.
    if "sg_config" not in config:
        config["sg_config"] = "{}"
        print("Query-only sg_config placeholder; supply the real configuration before an application build.")
    path = ROOT / "build-input/configuration-repository"
    if (path / "variables.bzl").exists():
        raise SystemExit("Configuration already exists; refusing to overwrite it.")
    path.mkdir(parents=True, exist_ok=True)
    (path / "MODULE.bazel").write_text('module(name = "build_configuration")\n')
    (path / "WORKSPACE").touch()
    (path / "BUILD").touch()
    provisioning = path / "provisioning"
    provisioning.mkdir(exist_ok=True)
    for profile in (ROOT / "build-system/fake-codesigning/profiles").glob("*.mobileprovision"):
        shutil.copy2(profile, provisioning / profile.name)
    (provisioning / "BUILD").write_text('exports_files(glob(["*.mobileprovision"]))\n')
    query_config = ROOT / "build-input/xtool-export-configuration.json"
    query_config.write_text(json.dumps(config))
    build_configuration_from_json(str(query_config)).write_to_variables_file(
        str(Path(args.bazel).resolve()), True, "development", str(path / "variables.bzl")
    )
    print(f"Prepared query configuration: {path}")


if __name__ == "__main__":
    main()
