#ifndef BUILD_CONFIG_SIGNED_ENTITLEMENTS_H
#define BUILD_CONFIG_SIGNED_ENTITLEMENTS_H

#include <stddef.h>
#include <stdint.h>

static inline uint32_t BCRead32(const unsigned char *p, int bigEndian) {
    return bigEndian ? ((uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3])
                     : ((uint32_t)p[3] << 24 | (uint32_t)p[2] << 16 | (uint32_t)p[1] << 8 | p[0]);
}

// iOS installs a thinned Mach-O. Read its signed XML entitlements rather than
// assuming the capabilities requested at build time survived re-signing.
static inline const unsigned char *BCSignedEntitlements(const unsigned char *bytes, size_t length, size_t *xmlLength) {
    *xmlLength = 0;
    if (length < 32 || BCRead32(bytes, 0) != 0xfeedfacf) {
        return NULL;
    }
    size_t commandsLength = BCRead32(bytes + 20, 0);
    if (commandsLength > length - 32) {
        return NULL;
    }
    size_t commandsEnd = 32 + commandsLength;
    size_t offset = 32;
    uint32_t count = BCRead32(bytes + 16, 0);
    for (uint32_t i = 0; i < count; i++) {
        if (offset > commandsEnd || commandsEnd - offset < 8) {
            return NULL;
        }
        uint32_t command = BCRead32(bytes + offset, 0);
        size_t size = BCRead32(bytes + offset + 4, 0);
        if (size < 8 || size > commandsEnd - offset) {
            return NULL;
        }
        if (command == 0x1d) { // LC_CODE_SIGNATURE
            if (size < 16) {
                return NULL;
            }
            size_t start = BCRead32(bytes + offset + 8, 0);
            size_t signatureLength = BCRead32(bytes + offset + 12, 0);
            if (start > length || signatureLength > length - start || signatureLength < 12) {
                return NULL;
            }
            const unsigned char *signature = bytes + start;
            size_t blobLength = BCRead32(signature + 4, 1);
            uint32_t slots = BCRead32(signature + 8, 1);
            if (BCRead32(signature, 1) != 0xfade0cc0 || blobLength < 12 || blobLength > signatureLength || slots > (blobLength - 12) / 8) {
                return NULL;
            }
            for (uint32_t j = 0; j < slots; j++) {
                size_t blob = BCRead32(signature + 16 + j * 8, 1);
                if (blob > blobLength || blobLength - blob < 8) {
                    return NULL;
                }
                size_t entitlementLength = BCRead32(signature + blob + 4, 1);
                if (entitlementLength < 8 || entitlementLength > blobLength - blob) {
                    return NULL;
                }
                if (BCRead32(signature + blob, 1) == 0xfade7171) {
                    *xmlLength = entitlementLength - 8;
                    return signature + blob + 8;
                }
            }
            return NULL;
        }
        offset += size;
    }
    return NULL;
}

#endif
