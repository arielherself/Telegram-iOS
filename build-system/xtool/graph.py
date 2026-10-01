"""Read Bazel's unconfigured BUILD output without executing Starlark.

The iOS toolchain is intentionally not needed: query expands macros and globs,
and this module resolves select() against the requested device configuration.
"""

from __future__ import annotations

import ast
from dataclasses import dataclass
from pathlib import Path
import re


@dataclass
class Select:
    choices: dict


@dataclass
class Addition:
    left: object
    right: object


def literal(node):
    if isinstance(node, ast.Constant):
        return node.value
    if isinstance(node, (ast.List, ast.Tuple)):
        return [literal(item) for item in node.elts]
    if isinstance(node, ast.Dict):
        return {literal(k): literal(v) for k, v in zip(node.keys, node.values)}
    if isinstance(node, ast.Name) and node.id in ("null", "true", "false"):
        return {"null": None, "true": True, "false": False}[node.id]
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "select":
        return Select(literal(node.args[0]))
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
        return Addition(literal(node.left), literal(node.right))
    if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.USub):
        return -literal(node.operand)
    raise ValueError(f"Unsupported query expression: {ast.dump(node)[:160]}")


def canonical(label: str, package: str = "//") -> str:
    if label.startswith("@@"):
        repo, rest = label[2:].split("//", 1)
        # Bzlmod canonical repository names have a trailing + and may include
        # extension identifiers. Keep those identifiers to prevent collisions.
        label = "@" + repo.rstrip("+") + "//" + rest
    for alias, repo in {
        "build_bazel_rules_apple": "rules_apple",
        "build_bazel_rules_swift": "rules_swift",
        "build_bazel_apple_support": "apple_support",
    }.items():
        label = label.replace("@" + alias + "//", "@" + repo + "//", 1)
    if label.startswith(("//", "@")):
        if ":" not in label:
            label += ":" + label.rsplit("/", 1)[-1]
        return label
    return package + ":" + label.removeprefix(":")


class Graph:
    def __init__(self, source: str, root: Path, output_base: Path, *, extensions=True):
        self.root = root.resolve()
        self.output_base = output_base
        self.rules = {}
        self.repo_paths = {}
        self.values = {
            "compilation_mode": "opt", "cpu": "ios_arm64", "ios_cpu": "arm64",
            "apple_platform_type": "ios",
        }
        self.flag_values = {
            "//Telegram:disableProvisioningProfiles": "true",
            "//Telegram:disableExtensions": "false" if extensions else "true",
            "//Telegram:embedWatchApp": "false",
            "//Telegram:disableStripping": "false",
        }
        self.defines = {"telegram_build_number": "1"}
        lines = source.splitlines()
        origins = {}
        current = None
        for i, line in enumerate(lines, 1):
            match = re.match(r"# (/.+):\d+:\d+$", line)
            if match:
                current = Path(match.group(1)).parent
            origins[i] = current
        for statement in ast.parse(source).body:
            if not isinstance(statement, ast.Expr) or not isinstance(statement.value, ast.Call):
                continue
            call = statement.value
            if not isinstance(call.func, ast.Name):
                raise ValueError("Unexpected query rule function")
            origin = origins[statement.lineno]
            if origin is None:
                raise ValueError(f"Missing origin at query line {statement.lineno}")
            if origin.is_relative_to(self.root):
                package = "//" + ("" if origin == self.root else origin.relative_to(self.root).as_posix())
            elif "/external/" in str(origin):
                repo_and_package = str(origin).split("/external/", 1)[1]
                repo, _, subdir = repo_and_package.partition("/")
                self.repo_paths[repo.rstrip("+")] = self.output_base / "external" / repo
                package = "@" + repo.rstrip("+") + "//" + subdir
            else:
                raise ValueError(f"Cannot identify package for {origin}")
            attrs = {kw.arg: literal(kw.value) for kw in call.keywords}
            label = package + ":" + attrs["name"]
            self.rules[label] = {"kind": call.func.id, "package": package, "attrs": attrs}
        self.outputs = {}
        for label, rule in self.rules.items():
            for out in self.resolve(rule["attrs"].get("outs", [])):
                self.outputs[canonical(out, rule["package"])] = label

    def matches(self, label, seen=None):
        label = canonical(label)
        if label.startswith("@platforms//os:"):
            return label.endswith(":ios")
        if label.startswith("@platforms//cpu:"):
            return label.endswith((":aarch64", ":arm64"))
        if label.startswith("@apple_support//constraints:"):
            return label.endswith(":device")
        seen = set() if seen is None else seen
        if label in seen:
            raise ValueError(f"Recursive configuration condition {label}")
        seen = seen | {label}
        rule = self.rules.get(label)
        if rule is None:
            raise ValueError(f"Unknown select condition {label}")
        attrs = rule["attrs"]
        kind = rule["kind"]
        if kind == "alias":
            return self.matches(self.resolve(attrs["actual"]), seen)
        if kind == "config_setting_group":
            if attrs.get("match_all"):
                return all(self.matches(x, seen) for x in attrs["match_all"])
            return any(self.matches(x, seen) for x in attrs.get("match_any", []))
        if kind != "config_setting":
            raise ValueError(f"Unsupported select condition kind {kind}: {label}")
        def flag(k):
            k = canonical(k, rule["package"])
            if k in self.flag_values:
                return self.flag_values[k]
            r = self.rules.get(k)
            if r is None or "build_setting_default" not in r["attrs"]:
                raise ValueError(f"Unknown build setting {k}")
            return str(r["attrs"]["build_setting_default"]).lower()
        return (
            all(self.values.get(k) == v for k, v in attrs.get("values", {}).items())
            and all(flag(k) == str(v).lower() for k, v in attrs.get("flag_values", {}).items())
            and all(self.defines.get(k) == v for k, v in attrs.get("define_values", {}).items())
            and all(self.matches(x, seen) for x in attrs.get("constraint_values", []))
        )

    def resolve(self, value):
        if isinstance(value, Select):
            matches = [v for k, v in value.choices.items() if k != "//conditions:default" and self.matches(k)]
            if len(matches) > 1 and any(v != matches[0] for v in matches[1:]):
                raise ValueError("Ambiguous select branches; configure an explicit specialization")
            if matches:
                return self.resolve(matches[0])
            if "//conditions:default" not in value.choices:
                raise ValueError("No select branch matches iOS arm64 Release")
            return self.resolve(value.choices["//conditions:default"])
        if isinstance(value, Addition):
            return self.resolve(value.left) + self.resolve(value.right)
        if isinstance(value, list):
            return [self.resolve(v) for v in value]
        if isinstance(value, dict):
            return {k: self.resolve(v) for k, v in value.items()}
        return value

    def attrs(self, label):
        try:
            return self.resolve(self.rules[canonical(label)]["attrs"])
        except ValueError as error:
            raise ValueError(f"{label}: {error}") from error

    def source_path(self, label, generated):
        label = canonical(label)
        package, name = label.split(":", 1)
        if label in self.outputs:
            if package.startswith("@"):
                return generated / "external" / package[1:].replace("//", "/") / name
            return generated / package.removeprefix("//") / name
        if package.startswith("@"):
            repo, subdir = package[1:].split("//", 1)
            if repo not in self.repo_paths:
                # Repository rules do not appear in query --output=build.
                candidates = list((self.output_base / "external").glob(repo + "+*"))
                if len(candidates) != 1:
                    raise ValueError(f"Cannot locate external repository {repo}")
                self.repo_paths[repo] = candidates[0]
            return self.repo_paths[repo] / subdir / name
        return self.root / package.removeprefix("//") / name

    def files(self, label, seen=None):
        label = canonical(label)
        seen = set() if seen is None else seen
        if label in seen:
            raise ValueError(f"Recursive filegroup {label}")
        rule = self.rules.get(label)
        if rule is None:
            return [label]
        attrs = self.attrs(label)
        if rule["kind"] == "alias":
            return self.files(canonical(attrs["actual"], rule["package"]), seen | {label})
        if rule["kind"] == "genrule":
            return [canonical(x, rule["package"]) for x in attrs["outs"]]
        if rule["kind"] == "filegroup":
            return [f for x in attrs.get("srcs", []) for f in self.files(canonical(x, rule["package"]), seen | {label})]
        raise ValueError(f"Source expansion requires an adapter for {rule['kind']}: {label}")

    def dependencies(self, label):
        rule = self.rules[canonical(label)]
        attrs = self.attrs(label)
        if rule["kind"] == "alias":
            return [canonical(attrs["actual"], rule["package"])]
        return [canonical(x, rule["package"]) for attr in ("deps", "frameworks") for x in attrs.get(attr, [])]

    def closure(self, roots):
        result = set()
        def visit(label):
            label = canonical(label)
            if label in result:
                return
            if label not in self.rules:
                raise ValueError(f"Missing dependency rule {label}")
            result.add(label)
            for dep in self.dependencies(label):
                visit(dep)
        for label in roots:
            visit(label)
        return sorted(result)
