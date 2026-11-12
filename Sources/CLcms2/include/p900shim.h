#ifndef P900SHIM_H
#define P900SHIM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Convert an RGBX image (4 channels, last one ignored) from the source ICC
 * profile to a printer/paper ICC profile, writing 8-bit RGBX.
 *
 * intent: 0 perceptual, 1 relative colorimetric, 2 saturation, 3 absolute
 * bpc:    1 = black point compensation on
 * srcBits: 8 or 16 (16-bit data must be native endian)
 *
 * Returns 0 on success. On failure returns non-zero and fills err.
 */
int p900_convert(const void *srcIcc, uint32_t srcIccLen,
                 const char *dstPath,
                 int intent, int bpc,
                 const void *src, int srcBits, size_t srcStride,
                 void *dst, size_t dstStride,
                 uint32_t width, uint32_t height,
                 char *err, size_t errLen);

/*
 * Gamut check. Finds the pixels of an RGBX image (in the source ICC profile) that the paper
 * profile cannot print with the given intent.
 *
 * mask: optional RGBA8 output, magenta (255,0,255,255) where out of gamut, fully transparent elsewhere.
 * stats: optional totals, see P900GamutStats.
 */
typedef struct {
    uint64_t total;            /* pixels scanned */
    uint64_t outCount;         /* pixels outside the paper's gamut */
    double   meanDeltaE;       /* average CIEDE2000 shift of those pixels under Relative Colorimetric, -1 if unknown */
    double   perceptualShift;  /* average 0-255 device value difference, Perceptual vs Relative, on those pixels, -1 if unknown */
} P900GamutStats;

int p900_gamut_scan(const void *srcIcc, uint32_t srcIccLen,
                    const char *paperPath,
                    int intent, int bpc,
                    const void *src, int srcBits, size_t srcStride,
                    uint32_t width, uint32_t height,
                    uint8_t *mask, size_t maskStride,
                    P900GamutStats *stats,
                    char *err, size_t errLen);

/*
 * Soft proof. Renders an RGBX image (in the source ICC profile) as it will look when printed on the paper
 * profile with the given intent, as 8-bit RGBA in sRGB (alpha forced to 255).
 *
 * simulatePaper: 0 shows paper white as screen white, 1 keeps the paper's own white and black.
 */
int p900_softproof(const void *srcIcc, uint32_t srcIccLen,
                   const char *paperPath,
                   int intent, int bpc, int simulatePaper,
                   const void *src, int srcBits, size_t srcStride,
                   uint32_t width, uint32_t height,
                   uint8_t *dst, size_t dstStride,
                   char *err, size_t errLen);

#ifdef __cplusplus
}
#endif

#endif
