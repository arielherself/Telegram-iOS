#!/usr/bin/env python3
"""Build pinned codec sources as iOS arm64 archives with Linux LLVM.

This supplements source export; it does not mark resource packaging complete.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

from graph import Graph, canonical
from prepare import ROOT


class NativeBuilder:
    def __init__(self, graph, output, sdk, toolchain, jobs):
        self.graph = graph
        self.output = output.resolve()
        self.generated = self.output / "generated"
        self.sdk = sdk.resolve()
        self.toolchain = toolchain.resolve()
        self.jobs = jobs
        definitions = json.loads((self.sdk / "swift-sdk.json").read_text())["targetTriples"]["arm64-apple-ios"]
        self.sysroot = self.sdk / definitions["sdkRootPath"]
        self.linker = self.sdk / "toolset/bin/ld64.lld"
        if not self.sysroot.is_dir() or not self.linker.is_file():
            raise ValueError("Incomplete Darwin SDK installation")
        self.bin = self.output / "native-tools"
        self.bin.mkdir(parents=True, exist_ok=True)
        for name in ("clang", "clang++"):
            script = self.bin / name
            # Arguments are constants or forwarded verbatim. No shell source
            # text from the downloaded project is interpolated here.
            import shlex
            script.write_text(
                '#!/usr/bin/env bash\nlink_options=(' + shlex.join([
                    "-fuse-ld=" + str(self.linker), "-Wl,-platform_version,ios,13.0,26.2",
                ]) + ')\nfor argument in "$@"; do\n'
                '    case "$argument" in -c|-S|-E|-fsyntax-only|--version|-dumpmachine) link_options=();; esac\n'
                'done\nexec ' + shlex.join([
                    str(self.toolchain / name), "--target=arm64-apple-ios13.0", "-isysroot", str(self.sysroot),
                ]) + ' "${link_options[@]}" "$@"\n'
            )
            script.chmod(0o755)
        for name, tool in (("ar", "llvm-ar"), ("ranlib", "llvm-ranlib"), ("nm", "llvm-nm")):
            target = self.bin / name
            if target.is_symlink():
                target.unlink()
            target.symlink_to(self.toolchain / tool)
        import shlex
        xcrun = self.bin / "xcrun"
        xcrun.write_text("#!/usr/bin/env bash\nexec " + shlex.join([sys.executable, str(Path(__file__).with_name("apple_tools.py"))]) + ' "$@"\n')
        xcrun.chmod(0o755)
        assembler = self.bin / "ios-as"
        assembler.write_text("#!/usr/bin/env bash\nexec " + shlex.quote(str(self.bin / "clang")) + ' -c "$@"\n')
        assembler.chmod(0o755)
        make = self.bin / "make"
        make.write_text('#!/usr/bin/env bash\nargs=()\nfor arg in "$@"; do\n    case "$arg" in -j|-j[0-9]*) args+=(-j' + str(jobs) + ');; *) args+=("$arg");; esac\ndone\nexec /usr/bin/make "${args[@]}"\n')
        make.chmod(0o755)
        self.env = os.environ | {
            "CC": str(self.bin / "clang"), "CXX": str(self.bin / "clang++"),
            "AR": str(self.bin / "ar"), "RANLIB": str(self.bin / "ranlib"),
            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            "CFLAGS": "-O2 -fPIC -miphoneos-version-min=13.0",
            "CXXFLAGS": "-O2 -fPIC -miphoneos-version-min=13.0",
            "SDKROOT": str(self.sysroot),
        }

    def run(self, args, cwd, stream):
        subprocess.run([str(x) for x in args], cwd=cwd, env=self.env, stdout=stream, stderr=subprocess.STDOUT, check=True)

    def work(self, library):
        path = self.output / "native-build" / library
        path.mkdir(parents=True, exist_ok=True)
        return path

    def publish(self, rule_label, candidates):
        attrs = self.graph.attrs(rule_label)
        package = self.graph.rules[rule_label]["package"]
        missing = []
        for label in attrs["outs"]:
            label = canonical(label, package)
            basename = label.rsplit("/", 1)[-1]
            relative_name = label.split(":", 1)[1].removeprefix("Public/")
            source = candidates.get(relative_name, candidates.get(basename))
            if source is None or not source.exists():
                missing.append(label)
                continue
            destination = self.graph.source_path(label, self.generated)
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
        if missing:
            raise ValueError(f"Unproduced outputs for {rule_label}: {missing}")

    def outputs_exist(self, label):
        attrs = self.graph.attrs(label)
        package = self.graph.rules[label]["package"]
        return all(self.graph.source_path(canonical(x, package), self.generated).exists() for x in attrs["outs"])

    def opus(self, stream):
        label = "//third-party/opus:opus_build"
        work = self.work("opus")
        source = work / "opus-1.5.1"
        prefix = work / "install"
        if not source.exists():
            self.run(["tar", "-xzf", ROOT / "third-party/opus/opus-1.5.1.tar.gz", "-C", work], ROOT, stream)
        if not (source / "Makefile").exists():
            self.run([
                source / "configure", "--disable-shared", "--enable-static", "--with-pic",
                "--disable-extra-programs", "--disable-doc", "--disable-asm",
                "--enable-intrinsics", "--host=aarch64-apple-darwin", "--prefix=" + str(prefix),
            ], source, stream)
        self.run(["make", "-j" + str(self.jobs)], source, stream)
        self.run(["make", "install"], source, stream)
        candidates = {p.name: p for p in (prefix / "include/opus").glob("*.h")}
        candidates["libopus.a"] = prefix / "lib/libopus.a"
        self.publish(label, candidates)

    def cmake(self, library, source, options, stream, targets=None):
        build = self.work(library) / "build"
        self.run([
            "cmake", "-S", source, "-B", build, "-G", "Ninja",
            "-DCMAKE_SYSTEM_NAME=Darwin", "-DCMAKE_SYSTEM_PROCESSOR=aarch64",
            "-DCMAKE_OSX_ARCHITECTURES=arm64", "-DCMAKE_OSX_SYSROOT=" + str(self.sysroot),
            "-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY", "-DCMAKE_BUILD_TYPE=Release",
            "-DCMAKE_C_COMPILER=" + str(self.bin / "clang"),
            "-DCMAKE_CXX_COMPILER=" + str(self.bin / "clang++"),
            "-DCMAKE_AR=" + str(self.bin / "ar"), "-DCMAKE_RANLIB=" + str(self.bin / "ranlib"),
            "-DCMAKE_POLICY_VERSION_MINIMUM=3.5",
        ] + options, ROOT, stream)
        self.run(["cmake", "--build", build, "-j", str(self.jobs)] + (["--target"] + targets if targets else []), ROOT, stream)
        return build

    def webp(self, stream):
        source = ROOT / "third-party/webp/libwebp"
        build = self.cmake("webp", source, [
            "-DBUILD_SHARED_LIBS=OFF", "-DWEBP_LINK_STATIC=1",
            "-DWEBP_BUILD_CWEBP=OFF", "-DWEBP_BUILD_DWEBP=OFF", "-DWEBP_BUILD_IMG2WEBP=OFF",
            "-DWEBP_BUILD_ANIM_UTILS=OFF", "-DWEBP_BUILD_GIF2WEBP=OFF", "-DWEBP_BUILD_VWEBP=OFF",
            "-DWEBP_BUILD_WEBPINFO=OFF", "-DWEBP_BUILD_LIBWEBPMUX=OFF",
            "-DWEBP_BUILD_WEBPMUX=OFF", "-DWEBP_BUILD_EXTRAS=OFF",
        ], stream)
        candidates = {p.name: p for p in (source / "src/webp").glob("*.h")}
        candidates.update({p.name: p for p in build.rglob("*.a")})
        self.publish("//third-party/webp:webp_build", candidates)

    def mozjpeg(self, stream):
        source = ROOT / "third-party/mozjpeg/mozjpeg"
        build = self.cmake("mozjpeg", source, [
            "-DPNG_SUPPORTED=OFF", "-DENABLE_SHARED=OFF", "-DWITH_JPEG8=1", "-DBUILD=10000",
        ], stream)
        candidates = {p.name: p for p in source.glob("*.h")}
        candidates.update({p.name: p for p in build.glob("*.h")})
        candidates.update({p.name: p for p in build.rglob("*.a")})
        self.publish("//third-party/mozjpeg:mozjpeg_build", candidates)

    def dav1d(self, stream):
        source = ROOT / "third-party/dav1d/dav1d"
        work = self.work("dav1d")
        build = work / "build"
        cross = work / "ios-arm64.meson"
        # Meson requires single-quoted strings in machine files.
        q = repr
        cross.write_text(
            "[binaries]\n" + "\n".join(f"{key} = {q(str(self.bin / tool))}" for key, tool in [("c", "clang"), ("cpp", "clang++"), ("ar", "ar")])
            + "\n[host_machine]\nsystem = 'darwin'\ncpu_family = 'aarch64'\ncpu = 'aarch64'\nendian = 'little'\n"
            + "[properties]\nneeds_exe_wrapper = true\n"
        )
        if not (build / "build.ninja").exists():
            self.run([
                "meson", "setup", build, source, "--cross-file", cross,
                "--buildtype=release", "--default-library=static",
                "-Denable_tools=false", "-Denable_tests=false",
            ], ROOT, stream)
        self.run(["ninja", "-C", build, "-j", str(self.jobs)], ROOT, stream)
        candidates = {p.name: p for p in source.rglob("*.h")}
        candidates.update({p.name: p for p in build.rglob("*.h")})
        candidates.update({p.relative_to(source / "include").as_posix(): p for p in (source / "include").rglob("*.h")})
        candidates.update({p.relative_to(build / "include").as_posix(): p for p in (build / "include").rglob("*.h")})
        candidates["libdav1d.a"] = build / "src/libdav1d.a"
        self.publish("//third-party/dav1d:dav1d_build", candidates)

    def build(self, name):
        methods = {"opus": self.opus, "webp": self.webp, "mozjpeg": self.mozjpeg, "dav1d": self.dav1d, "vpx": self.vpx, "ffmpeg": self.ffmpeg, "td": self.td}
        self.output.joinpath("logs").mkdir(parents=True, exist_ok=True)
        log = self.output / "logs" / ("native-" + name + ".log")
        print(f"Building iOS arm64 {name}; log: {log}", flush=True)
        with log.open("w") as stream:
            methods[name](stream)
        print(f"Published {name} headers and archives.", flush=True)

    def vpx(self, stream):
        work = self.work("vpx")
        source = work / "source"
        build = work / "build"
        prefix = work / "install"
        if not source.exists():
            shutil.copytree(ROOT / "third-party/libvpx/libvpx", source)
            # The upstream script checks Xcode's version before enabling NEON.
            # Test the actual Linux cross compiler's NEON support instead.
            configure = source / "build/make/configure.sh"
            text = configure.read_text()
            import re
            text, count = re.subn(
                r"check_xcode_minimum_version\(\) \{.*?\n\}",
                'check_xcode_minimum_version() {\n  echo "#include <arm_neon.h>" | "$CC" -x c -fsyntax-only -\n}',
                text, count=1, flags=re.S,
            )
            if count != 1:
                raise ValueError("The pinned VPX compiler capability check changed")
            configure.write_text(text)
        build.mkdir(exist_ok=True)
        if not (build / "config.mk").exists():
            self.run([
                source / "configure", "--target=arm64-darwin-gcc", "--prefix=" + str(prefix),
                "--disable-docs", "--disable-examples", "--disable-postproc", "--disable-webm-io",
                "--disable-vp9-highbitdepth", "--disable-vp9-postproc", "--disable-vp9-temporal-denoising",
                "--disable-unit-tests", "--enable-realtime-only", "--enable-multi-res-encoding",
                "--size-limit=8192x8192",
            ], build, stream)
        self.run(["make", "-j" + str(self.jobs)], build, stream)
        self.run(["make", "install"], build, stream)
        candidates = {p.name: p for p in (prefix / "include/vpx").glob("*.h")}
        candidates.update({p.name: p for p in build.glob("*.h")})
        candidates["libVPX.a"] = prefix / "lib/libvpx.a"
        self.publish("//third-party/libvpx:libvpx_build", candidates)

    def ffmpeg(self, stream):
        for dependency, label in [
            ("opus", "//third-party/opus:opus_build"),
            ("vpx", "//third-party/libvpx:libvpx_build"),
            ("dav1d", "//third-party/dav1d:dav1d_build"),
        ]:
            if not self.outputs_exist(label):
                raise ValueError(f"Build {dependency} before FFmpeg")
        work = self.work("ffmpeg")
        source = work / "FFMpegSource"
        if not source.exists():
            shutil.copytree(ROOT / "submodules/ffmpeg/Sources/FFMpeg", source)
        for package, directory, subdir, archive in [
            ("third-party/libvpx", "libvpx", "vpx", "libVPX.a"),
            ("third-party/opus", "libopus", "opus", "libopus.a"),
            ("third-party/dav1d", "libdav1d", "dav1d", "libdav1d.a"),
        ]:
            dependency = source / directory
            dependency.mkdir(exist_ok=True)
            shutil.copytree(self.generated / package / "Public" / subdir, dependency / "include" / subdir, dirs_exist_ok=True)
            (dependency / "lib").mkdir(exist_ok=True)
            archive_labels = [label for label in self.graph.outputs if label.startswith("//" + package + ":") and label.rsplit("/", 1)[-1] == archive]
            if len(archive_labels) != 1:
                raise ValueError(f"Cannot identify the generated archive {archive}")
            archive_path = self.graph.source_path(archive_labels[0], self.generated)
            shutil.copy2(archive_path, dependency / "lib" / archive)
        # GNU nm cannot read Mach-O. Reconfigure when an older run inferred
        # the ELF symbol prefix; LLVM nm discovers Darwin's underscore.
        config = work / "scratch/arm64/config.h"
        if config.exists() and '#define EXTERN_PREFIX ""' in config.read_text():
            shutil.rmtree(work / "scratch/arm64")
            (work / "thin/arm64/configured_marker").unlink(missing_ok=True)
        self.run(["bash", source / "build-ffmpeg-bazel.sh", "release", "arm64", work, source, "7.1.1"], ROOT, stream)
        prefix = work / "FFmpeg-iOS"
        attrs = self.graph.attrs("//submodules/ffmpeg:libffmpeg_build")
        for output_label in attrs["outs"]:
            label = canonical(output_label)
            name = label.split(":", 1)[1]
            if name.endswith(".a"):
                source_file = prefix / "lib" / Path(name).name
            else:
                relative = name.removeprefix("Public/").removeprefix("third_party/ffmpeg/")
                source_file = prefix / "include" / relative
            if not source_file.exists():
                raise ValueError(f"FFmpeg output missing: {source_file}")
            destination = self.graph.source_path(label, self.generated)
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source_file, destination)

    def td(self, stream):
        work = self.work("td")
        source = work / "source"
        if not source.exists():
            # The TDLib host generators write files into the source directory.
            # Use a private copy to preserve the checked-in source tree.
            shutil.copytree(ROOT / "third-party/td/td", source)
        crypto_package = self.output / "host-tools/crypto-package"
        subprocess.run([
            sys.executable, Path(__file__).with_name("prepare.py"),
            "--bazel", self.bazel, "--query-file", self.query_file,
            "--root", "//third-party/boringssl:crypto", "--output", crypto_package,
        ], cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT, check=True)
        subprocess.run([
            "swift", "build", "--package-path", crypto_package, "--swift-sdk", "arm64-apple-ios",
            "--configuration", "release", "--jobs", str(self.jobs),
        ], cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT, check=True)
        objects = sorted((crypto_package / ".build/arm64-apple-ios/release/crypto.build").rglob("*.o"))
        if not objects:
            raise ValueError("SwiftPM did not produce BoringSSL crypto objects")
        archive = work / "libcrypto.a"
        archive.unlink(missing_ok=True)
        self.run([self.toolchain / "llvm-ar", "rcs", archive] + objects, ROOT, stream)
        host_build = work / "host-build"
        environment = os.environ | {"CC": "/usr/bin/cc", "CXX": "/usr/bin/c++"}
        environment.pop("SDKROOT", None)
        subprocess.run([
            "cmake", "-S", source, "-B", host_build, "-G", "Ninja",
            "-DCMAKE_BUILD_TYPE=Release", "-DTD_GENERATE_SOURCE_FILES=ON",
        ], env=environment, stdout=stream, stderr=subprocess.STDOUT, check=True)
        subprocess.run(["cmake", "--build", host_build, "-j", str(self.jobs)], env=environment, stdout=stream, stderr=subprocess.STDOUT, check=True)
        build = self.cmake("td", source, [
            "-DOPENSSL_FOUND=1", "-DOPENSSL_CRYPTO_LIBRARY=" + str(archive),
            "-DOPENSSL_INCLUDE_DIR=" + str(ROOT / "third-party/boringssl/src/include"),
            "-DIOS_DEPLOYMENT_TARGET=13.0",
        ], stream, targets=["tde2e"])
        candidates = {p.name: p for p in (source / "tde2e").rglob("*.h")}
        candidates.update({p.name: p for p in build.rglob("*.a")})
        self.publish("//third-party/td:td_build", candidates)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bazel", default=os.environ.get("BAZEL", "bazel"))
    parser.add_argument("--output", type=Path, default=ROOT / "build/xtool")
    parser.add_argument("--query-file", type=Path)
    parser.add_argument("--sdk", type=Path, default=Path.home() / ".swiftpm/swift-sdks/darwin.artifactbundle")
    parser.add_argument("--toolchain", type=Path, default=Path.home() / ".local/opt/swift-6.3/usr/bin")
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("libraries", nargs="+", choices=["opus", "webp", "mozjpeg", "dav1d", "vpx", "ffmpeg", "td"])
    args = parser.parse_args()
    base = subprocess.run([args.bazel, "info", "output_base"], cwd=ROOT, check=True, capture_output=True, text=True).stdout.strip()
    graph = Graph((args.query_file or args.output / "rules.star").read_text(), ROOT, Path(base))
    builder = NativeBuilder(graph, args.output, args.sdk, args.toolchain, args.jobs)
    builder.bazel = args.bazel
    builder.query_file = args.query_file or args.output / "rules.star"
    for library in args.libraries:
        builder.build(library)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, subprocess.CalledProcessError) as error:
        print(f"Native build failed: {error}", file=sys.stderr)
        sys.exit(1)
