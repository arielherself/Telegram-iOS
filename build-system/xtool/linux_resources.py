#!/usr/bin/env python3
"""Pack loose iOS images and original Metal source on Linux."""
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
from PIL import Image
from resources import Resources


class LinuxResources(Resources):
    def render(self, source, target, scale):
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists() and target.stat().st_mtime >= source.stat().st_mtime:
            if source.suffix != '.pdf' or Image.open(target).mode == 'RGBA':
                return
        if source.suffix == '.pdf':
            subprocess.run(['pdftocairo', '-transp', '-singlefile', '-png', '-r', str(72 * scale), str(source), str(target.with_suffix(''))], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        elif source.suffix == '.svg':
            subprocess.run(['rsvg-convert', '--zoom', str(scale), '-o', str(target), str(source)], check=True, stderr=subprocess.PIPE)
        else:
            shutil.copy2(source, target)

    def shader_source(self, paths):
        # Inline quoted includes once, preserving declarations and definitions.
        seen = set()
        def expand(path):
            path = path.resolve()
            if path in seen:
                return ''
            seen.add(path)
            text = path.read_text()
            text = re.sub(r'^\s*#include "([^"]+)"', lambda m: expand(path.parent / m[1]), text, flags=re.M)
            return text.replace('#pragma once', '')
        chunks = []
        for path in sorted(set(paths)):
            text = expand(path)
            # These two independent translation units define identical types.
            # Give NV12's local types unique names in the combined library.
            if path.name == 'NV12VideoShaders.metal':
                for name in ('Vertex', 'Varyings'):
                    text = re.sub(r'\b' + name + r'\b', 'NV12' + name, text)
            chunks.append(text)
        return '\n'.join(chunks)

    def pack_files(self, files, destination, name=None):
        destination.mkdir(parents=True, exist_ok=True)
        imagesets = set()
        catalogs = set()
        appiconsets = set()
        metal = []
        template = []
        jobs = []
        copied_sources = {}
        for source in files:
            text = str(source)
            if '.xcassets/' in text:
                catalog = Path(text.split('.xcassets/', 1)[0] + '.xcassets')
                catalogs.add(catalog)
                appicon = next((p for p in source.parents if p.suffix == '.appiconset'), None)
                if appicon:
                    appiconsets.add(appicon)
                parent = next((p for p in source.parents if p.suffix == '.imageset'), None)
                if parent:
                    imagesets.add(parent)
                continue
            if '.icon/' in text:
                continue
            if '.alticon/' in text:
                icon_name = Path(text.split('.alticon/', 1)[0]).stem
                self.alternate_icons.setdefault(icon_name, {}).setdefault('iphone', set()).add(icon_name)
            if source.suffix == '.metal':
                metal.append(source)
                continue
            if source.suffix == '.xib':
                if source.name != 'LaunchScreen.xib':
                    raise ValueError(f'Unsupported interface resource: {source}')
                continue
            locale = next((part for part in source.parts if part.endswith('.lproj')), None)
            folder = destination / locale if locale else destination
            folder.mkdir(exist_ok=True)
            target = folder / source.name
            previous = copied_sources.get(target)
            if previous is not None and previous.read_bytes() != source.read_bytes():
                raise ValueError(f'Resource collision: {target}')
            copied_sources[target] = source
            shutil.copy2(source, target)
        for appiconset in sorted(appiconsets):
            content = json.loads((appiconset / 'Contents.json').read_text())
            for item in content.get('images', []):
                if not item.get('filename') or item.get('idiom') == 'ios-marketing':
                    continue
                stem = appiconset.stem + item['size'].split('x')[0]
                scale = int(item.get('scale', '1x').rstrip('x'))
                suffix = '' if scale == 1 else f'@{scale}x'
                source = appiconset / item['filename']
                target = destination / (stem + suffix + '.png')
                shutil.copy2(source, target)
                self.alternate_icons.setdefault(appiconset.stem, {}).setdefault(item['idiom'], set()).add(stem)
        for imageset in sorted(imagesets):
            content = json.loads((imageset / 'Contents.json').read_text())
            namespace = []
            for parent in reversed(imageset.parents):
                metadata = parent / 'Contents.json'
                if parent in catalogs:
                    continue
                if metadata.is_file() and json.loads(metadata.read_text()).get('properties', {}).get('provides-namespace'):
                    namespace.append(parent.name)
            base = destination.joinpath(*namespace, imageset.stem)
            if content.get('properties', {}).get('template-rendering-intent') == 'template':
                template.append('/'.join(namespace + [imageset.stem]))
            for item in content.get('images', []):
                if not item.get('filename'):
                    continue
                if item.get('appearances') or item.get('idiom', 'universal') != 'universal':
                    raise ValueError(f'Image variants require an adapter: {imageset}')
                source = imageset / item['filename']
                scales = (1, 2, 3) if source.suffix in ('.pdf', '.svg') else (int(item.get('scale', '1x').rstrip('x')),)
                for scale in scales:
                    suffix = '' if scale == 1 else f'@{scale}x'
                    target = base.parent / (base.name + suffix + ('.png' if source.suffix in ('.pdf', '.svg') else source.suffix))
                    jobs.append((source, target, scale))
        with ThreadPoolExecutor(max_workers=4) as pool:
            list(pool.map(lambda x: self.render(*x), jobs))
        if metal:
            (destination / 'xtool-shaders.metal').write_text(self.shader_source(metal))
        (destination / 'xtool-template-images.plist').write_bytes(plistlib.dumps(template))

    def compile(self, bundles, files):
        self.alternate_icons = {}
        resources = self.output / 'resources'
        # Raster outputs are reused when inputs have not changed.
        self.pack_files(files, resources)
        for label, collection in bundles.items():
            rule = self.graph.rules[label]
            attrs = self.graph.attrs(label)
            directory = resources / (attrs['name'] + '.bundle')
            self.pack_files(collection, directory)
            info = {'CFBundlePackageType': 'BNDL', 'CFBundleName': attrs['name']}
            from graph import canonical
            for reference in attrs.get('infoplists', []):
                fragment = self.graph.attrs(canonical(reference, rule['package']))
                info.update(plistlib.loads(('<plist version="1.0"><dict>' + fragment['template'] + '</dict></plist>').encode()))
            (directory / 'Info.plist').write_bytes(plistlib.dumps(info))
        # Classic icon PNGs remain supported on iOS 13 and later.
        source = Path('Telegram/Telegram-iOS/DefaultAppIcon.xcassets/AppIconLLC.appiconset/Swiftgram.png')
        sizes = [(60, 2), (60, 3), (76, 1), (76, 2), (83.5, 2)]
        for points, scale in sizes:
            image = Image.open(source).convert('RGB')
            pixels = int(points * scale)
            image.resize((pixels, pixels), Image.Resampling.LANCZOS).save(resources / f'AppIcon{points}@{scale}x.png')
        info_path = self.output / 'Arielgram-Info.plist'
        info = plistlib.loads(info_path.read_bytes())
        icon = {'CFBundleIconFiles': ['AppIcon60'], 'UIPrerenderedIcon': False}
        info['CFBundleIcons'] = {'CFBundlePrimaryIcon': icon}
        info['CFBundleIcons~ipad'] = {'CFBundlePrimaryIcon': {'CFBundleIconFiles': ['AppIcon60', 'AppIcon76', 'AppIcon83.5']}}
        for key, idiom in (('CFBundleIcons', 'iphone'), ('CFBundleIcons~ipad', 'ipad')):
            info[key]['CFBundleAlternateIcons'] = {name: {'CFBundleIconFiles': sorted(sizes.get(idiom, sizes.get('iphone', set())))} for name, sizes in self.alternate_icons.items()}
        info.pop('CFBundleIconName', None)
        # The original XIB is an empty view using systemBackgroundColor.
        # UILaunchScreen supplies that empty launch view on iOS 14+.
        info.pop('UILaunchStoryboardName', None)
        info['UILaunchScreen'] = {}
        info_path.write_bytes(plistlib.dumps(info))
        config_path = self.output / 'xtool.yml'
        config = json.loads(config_path.read_text())
        config['resources'] = [str(p.relative_to(self.output)) for p in sorted(resources.iterdir())]
        # Statically linked classes resolve Bundle(for:) to the extension bundle.
        # Keep their resources there as well as in the host app. This includes
        # Metal bundles and localized widget intent definitions.
        for extension in config.get('extensions', []):
            extension['resources'] = config['resources']
        config_path.write_text(json.dumps(config, indent=2) + '\n')
        (self.output / 'resource-status.json').write_text(json.dumps({'complete': False, 'mode': 'linux-runtime', 'limitations': ['iOS 13 launch-screen adaptation pending', 'device shader validation pending']}, indent=2) + '\n')


def main():
    import argparse
    from prepare import ROOT
    from graph import Graph
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bazel', required=True)
    parser.add_argument('--output', type=Path, default=ROOT / 'build/xtool')
    parser.add_argument('--query-file', type=Path, required=True)
    args = parser.parse_args()
    base = subprocess.run([args.bazel, 'info', 'output_base'], cwd=ROOT, check=True, capture_output=True, text=True).stdout.strip()
    graph = Graph(args.query_file.read_text(), ROOT, Path(base))
    resource = LinuxResources(graph, args.output)
    bundles, files = resource.plan()
    resource.compile(bundles, files)
    print(f'Packed {len(bundles)} resource bundles and loose images')

if __name__ == '__main__':
    main()
