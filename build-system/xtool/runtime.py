"""Source adapters applied only to exported SwiftPM copies."""
from pathlib import Path

METAL_HELPER = '''import Foundation
import Metal

// Linux cannot produce AIR/metallib. Compile the original shaders on device.
func xtoolDefaultLibrary(device: MTLDevice, bundle: Bundle) throws -> MTLLibrary {
    guard let url = bundle.url(forResource: "xtool-shaders", withExtension: "metal") else {
        throw NSError(domain: "XToolMetalResources", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Missing shader source in \\(bundle.bundlePath)"])
    }
    let options = MTLCompileOptions()
    options.fastMathEnabled = true
    return try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: options)
}
'''


def write_adapted(destination, text):
    if destination.exists() and not destination.is_symlink() and destination.read_text() == text:
        return
    destination.unlink(missing_ok=True)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(text)


def adapt(source, destination):
    if source.name == 'AppBundle.m':
        write_adapted(destination, source.read_text() + IMAGE_HELPER)
        return False
    if source.name == 'CGPath.cpp':
        write_adapted(destination, source.read_text().replace('transformVector(', 'cgPathTransformVector('))
        return False
    if source.suffix in ('.m', '.mm'):
        text = source.read_text()
        fixed = text.replace('CommonCrypto/CommonHMac.h', 'CommonCrypto/CommonHMAC.h')
        if 'import <endian.h>' in text:
            fixed = fixed.replace('import <endian.h>', 'import <machine/endian.h>')
            fixed = fixed.replace('__BYTE_ORDER', '__BYTE_ORDER__').replace('__LITTLE_ENDIAN', '__ORDER_LITTLE_ENDIAN__').replace('__BIG_ENDIAN', '__ORDER_BIG_ENDIAN__')
        if fixed != text:
            write_adapted(destination, fixed)
        return False
    if source.suffix != '.swift':
        return False
    text = source.read_text()
    import re
    text_for_app = text.replace("#if !SWIFT_PACKAGE", "#if true // xtool: use application resources")
    text_for_app = text_for_app.replace("#if SWIFT_PACKAGE", "#if false // xtool: use application implementation")
    adapted, count = re.subn(r'(self\.device|device)\.makeDefaultLibrary\(bundle: ([^\n]+?)\)', r'xtoolDefaultLibrary(device: \1, bundle: \2)', text_for_app)
    if adapted != text:
        write_adapted(destination, adapted)
    return bool(count)

IMAGE_HELPER = r'''
#import <objc/runtime.h>

@implementation UIImage (XToolLooseAssets)
+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method original = class_getClassMethod(self, @selector(imageNamed:inBundle:compatibleWithTraitCollection:));
        Method replacement = class_getClassMethod(self, @selector(xtool_imageNamed:inBundle:compatibleWithTraitCollection:));
        method_exchangeImplementations(original, replacement);
        method_exchangeImplementations(class_getClassMethod(self, @selector(imageNamed:)),
                                       class_getClassMethod(self, @selector(xtool_imageNamed:)));
    });
}
+ (UIImage *)xtool_imageNamed:(NSString *)name {
    UIImage *image = [self xtool_imageNamed:name];
    return [self xtool_applyMetadata:image name:name bundle:NSBundle.mainBundle];
}
+ (UIImage *)xtool_imageNamed:(NSString *)name inBundle:(NSBundle *)bundle compatibleWithTraitCollection:(UITraitCollection *)traits {
    UIImage *image = [self xtool_imageNamed:name inBundle:bundle compatibleWithTraitCollection:traits];
    return [self xtool_applyMetadata:image name:name bundle:bundle];
}
+ (UIImage *)xtool_applyMetadata:(UIImage *)image name:(NSString *)name bundle:(NSBundle *)bundle {
    if (!image) return nil;
    NSBundle *sourceBundle = bundle ?: NSBundle.mainBundle;
    static NSCache *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ cache = [[NSCache alloc] init]; });
    NSSet *names = [cache objectForKey:sourceBundle.bundlePath];
    if (!names) {
        NSString *metadataPath = [sourceBundle pathForResource:@"xtool-template-images" ofType:@"plist"];
        NSArray *values = metadataPath ? [NSArray arrayWithContentsOfFile:metadataPath] : nil;
        names = [NSSet setWithArray:values ?: @[]];
        [cache setObject:names forKey:sourceBundle.bundlePath];
    }
    if ([names containsObject:name]) return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    return image;
}
@end
'''
