#include "p900shim.h"
#include "lcms2.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <math.h>

static void set_err(char *err, size_t errLen, const char *msg)
{
    if (err && errLen > 0) {
        snprintf(err, errLen, "%s", msg);
    }
}

int p900_convert(const void *srcIcc, uint32_t srcIccLen,
                 const char *dstPath,
                 int intent, int bpc,
                 const void *src, int srcBits, size_t srcStride,
                 void *dst, size_t dstStride,
                 uint32_t width, uint32_t height,
                 char *err, size_t errLen)
{
    cmsHPROFILE hIn = NULL;
    cmsHPROFILE hOut = NULL;
    cmsHTRANSFORM xf = NULL;
    int rc = -1;
    cmsUInt32Number fmtIn;
    cmsUInt32Number fmtOut = TYPE_RGBA_8;
    cmsUInt32Number flags = cmsFLAGS_HIGHRESPRECALC;

    hIn = cmsOpenProfileFromMem(srcIcc, srcIccLen);
    if (!hIn) {
        set_err(err, errLen, "Could not read the image's embedded color profile.");
        goto done;
    }

    hOut = cmsOpenProfileFromFile(dstPath, "r");
    if (!hOut) {
        set_err(err, errLen, "Could not open the paper profile.");
        goto done;
    }

    fmtIn = (srcBits == 16) ? TYPE_RGBA_16 : TYPE_RGBA_8;
    if (bpc) flags |= cmsFLAGS_BLACKPOINTCOMPENSATION;

    xf = cmsCreateTransform(hIn, fmtIn, hOut, fmtOut, (cmsUInt32Number)intent, flags);
    if (!xf) {
        set_err(err, errLen, "Could not build the color transform (profile may not support this rendering intent).");
        goto done;
    }

    cmsDoTransformLineStride(xf, src, dst,
                             width, height,
                             (cmsUInt32Number)srcStride, (cmsUInt32Number)dstStride,
                             0, 0);
    rc = 0;

done:
    if (xf) cmsDeleteTransform(xf);
    if (hIn) cmsCloseProfile(hIn);
    if (hOut) cmsCloseProfile(hOut);
    return rc;
}

/* ------------------------------------------------------------------ */
/* Gamut check                                                         */
/* ------------------------------------------------------------------ */

/* Pixels outside the paper's gamut come back from the proofing transform as this exact color. */
#define ALARM_R 255
#define ALARM_G 0
#define ALARM_B 255

static int is_alarm(const uint8_t *p)
{
    return p[0] == ALARM_R && p[1] == ALARM_G && p[2] == ALARM_B;
}

int p900_gamut_scan(const void *srcIcc, uint32_t srcIccLen,
                    const char *paperPath,
                    int intent, int bpc,
                    const void *src, int srcBits, size_t srcStride,
                    uint32_t width, uint32_t height,
                    uint8_t *mask, size_t maskStride,
                    P900GamutStats *stats,
                    char *err, size_t errLen)
{
    int rc = -1;
    cmsHPROFILE hIn = NULL, hPaper = NULL, hDisp = NULL, hLab = NULL;
    cmsHTRANSFORM xfGamut = NULL, xfLab = NULL, xfPrint = NULL, xfBack = NULL, xfPerc = NULL;
    uint8_t *tmp = NULL;
    uint8_t *flagSrc = NULL;
    uint8_t *devRel = NULL, *devPerc = NULL;
    cmsCIELab *labA = NULL, *labB = NULL;
    cmsUInt32Number fmtIn;
    cmsUInt32Number flags;
    cmsUInt16Number alarm[cmsMAXCHANNELS];
    size_t bpp;
    uint64_t nOut = 0;
    size_t n = 0;
    uint32_t x, y;

    if (stats) {
        stats->total = (uint64_t)width * height;
        stats->outCount = 0;
        stats->meanDeltaE = -1.0;
        stats->perceptualShift = -1.0;
    }

    hIn = cmsOpenProfileFromMem(srcIcc, srcIccLen);
    if (!hIn) { set_err(err, errLen, "Could not read the image's embedded color profile."); goto done; }
    hPaper = cmsOpenProfileFromFile(paperPath, "r");
    if (!hPaper) { set_err(err, errLen, "Could not open the paper profile."); goto done; }
    hDisp = cmsCreate_sRGBProfile();
    hLab = cmsCreateLab4Profile(NULL);
    if (!hDisp || !hLab) { set_err(err, errLen, "Could not create helper profiles."); goto done; }

    fmtIn = (srcBits == 16) ? TYPE_RGBA_16 : TYPE_RGBA_8;
    bpp = (srcBits == 16) ? 8 : 4;

    memset(alarm, 0, sizeof(alarm));
    alarm[0] = (cmsUInt16Number)(ALARM_R * 257);
    alarm[1] = (cmsUInt16Number)(ALARM_G * 257);
    alarm[2] = (cmsUInt16Number)(ALARM_B * 257);
    cmsSetAlarmCodes(alarm);

    flags = cmsFLAGS_GAMUTCHECK | cmsFLAGS_SOFTPROOFING;
    if (bpc) flags |= cmsFLAGS_BLACKPOINTCOMPENSATION;
    xfGamut = cmsCreateProofingTransform(hIn, fmtIn, hDisp, TYPE_RGBA_8, hPaper,
                                         (cmsUInt32Number)intent, (cmsUInt32Number)intent, flags);
    if (!xfGamut) {
        set_err(err, errLen, "Could not build the gamut check (the paper profile may not support it).");
        goto done;
    }

    tmp = (uint8_t *)malloc((size_t)width * height * 4);
    if (!tmp) { set_err(err, errLen, "Out of memory."); goto done; }

    cmsDoTransformLineStride(xfGamut, src, tmp, width, height,
                             (cmsUInt32Number)srcStride, (cmsUInt32Number)(width * 4), 0, 0);

    for (y = 0; y < height; y++) {
        for (x = 0; x < width; x++) {
            const uint8_t *p = tmp + ((size_t)y * width + x) * 4;
            int out = is_alarm(p);
            if (out) nOut++;
            if (mask) {
                uint8_t *m = mask + (size_t)y * maskStride + (size_t)x * 4;
                m[0] = out ? 255 : 0;
                m[1] = 0;
                m[2] = out ? 255 : 0;
                m[3] = out ? 255 : 0;
            }
        }
    }
    if (stats) stats->outCount = nOut;

    /* How badly are those colors clipped, and would Perceptual do anything different? */
    if (stats && nOut > 0) {
        uint64_t step = nOut / 60000 + 1;
        uint64_t seen = 0;
        size_t cap = (size_t)(nOut / step) + 1;
        size_t i;

        flagSrc = (uint8_t *)malloc(cap * bpp);
        if (!flagSrc) { set_err(err, errLen, "Out of memory."); goto done; }
        for (y = 0; y < height; y++) {
            for (x = 0; x < width; x++) {
                const uint8_t *p = tmp + ((size_t)y * width + x) * 4;
                if (is_alarm(p)) {
                    if (seen % step == 0 && n < cap) {
                        memcpy(flagSrc + n * bpp, (const uint8_t *)src + (size_t)y * srcStride + (size_t)x * bpp, bpp);
                        n++;
                    }
                    seen++;
                }
            }
        }

        {
            cmsUInt32Number f = bpc ? cmsFLAGS_BLACKPOINTCOMPENSATION : 0;
            xfLab = cmsCreateTransform(hIn, fmtIn, hLab, TYPE_Lab_DBL, INTENT_RELATIVE_COLORIMETRIC, 0);
            xfPrint = cmsCreateTransform(hIn, fmtIn, hPaper, TYPE_RGBA_8, INTENT_RELATIVE_COLORIMETRIC, f);
            xfBack = cmsCreateTransform(hPaper, TYPE_RGBA_8, hLab, TYPE_Lab_DBL, INTENT_RELATIVE_COLORIMETRIC, 0);
            xfPerc = cmsCreateTransform(hIn, fmtIn, hPaper, TYPE_RGBA_8, INTENT_PERCEPTUAL, f);
        }

        devRel = (uint8_t *)malloc(n * 4);
        labA = (cmsCIELab *)malloc(n * sizeof(cmsCIELab));
        labB = (cmsCIELab *)malloc(n * sizeof(cmsCIELab));
        devPerc = (uint8_t *)malloc(n * 4);
        if (!devRel || !labA || !labB || !devPerc) { set_err(err, errLen, "Out of memory."); goto done; }

        if (xfLab && xfPrint && xfBack && n > 0) {
            double sum = 0;
            cmsDoTransform(xfLab, flagSrc, labA, (cmsUInt32Number)n);
            cmsDoTransform(xfPrint, flagSrc, devRel, (cmsUInt32Number)n);
            cmsDoTransform(xfBack, devRel, labB, (cmsUInt32Number)n);
            for (i = 0; i < n; i++) sum += cmsCIE2000DeltaE(&labA[i], &labB[i], 1, 1, 1);
            stats->meanDeltaE = sum / (double)n;

            if (xfPerc) {
                double d = 0;
                cmsDoTransform(xfPerc, flagSrc, devPerc, (cmsUInt32Number)n);
                for (i = 0; i < n; i++) {
                    d += fabs((double)devPerc[i * 4]     - (double)devRel[i * 4]);
                    d += fabs((double)devPerc[i * 4 + 1] - (double)devRel[i * 4 + 1]);
                    d += fabs((double)devPerc[i * 4 + 2] - (double)devRel[i * 4 + 2]);
                }
                stats->perceptualShift = d / (3.0 * (double)n);
            }
        }
    } else if (stats) {
        stats->meanDeltaE = 0.0;
        stats->perceptualShift = 0.0;
    }
    rc = 0;

done:
    free(tmp); free(flagSrc); free(devRel); free(devPerc); free(labA); free(labB);
    if (xfGamut) cmsDeleteTransform(xfGamut);
    if (xfLab) cmsDeleteTransform(xfLab);
    if (xfPrint) cmsDeleteTransform(xfPrint);
    if (xfBack) cmsDeleteTransform(xfBack);
    if (xfPerc) cmsDeleteTransform(xfPerc);
    if (hIn) cmsCloseProfile(hIn);
    if (hPaper) cmsCloseProfile(hPaper);
    if (hDisp) cmsCloseProfile(hDisp);
    if (hLab) cmsCloseProfile(hLab);
    return rc;
}

/* ------------------------------------------------------------------ */
/* Soft proof                                                          */
/* ------------------------------------------------------------------ */

int p900_softproof(const void *srcIcc, uint32_t srcIccLen,
                   const char *paperPath,
                   int intent, int bpc, int simulatePaper,
                   const void *src, int srcBits, size_t srcStride,
                   uint32_t width, uint32_t height,
                   uint8_t *dst, size_t dstStride,
                   char *err, size_t errLen)
{
    int rc = -1;
    cmsHPROFILE hIn = NULL, hPaper = NULL, hDisp = NULL;
    cmsHTRANSFORM xfPrint = NULL, xfShow = NULL;
    cmsUInt32Number fmtIn;
    cmsUInt32Number flagsPrint = cmsFLAGS_HIGHRESPRECALC;
    cmsUInt32Number flagsShow = cmsFLAGS_HIGHRESPRECALC;
    uint8_t *paperRGB = NULL;
    uint32_t x, y;

    hIn = cmsOpenProfileFromMem(srcIcc, srcIccLen);
    if (!hIn) { set_err(err, errLen, "Could not read the image's embedded color profile."); goto done; }
    hPaper = cmsOpenProfileFromFile(paperPath, "r");
    if (!hPaper) { set_err(err, errLen, "Could not open the paper profile."); goto done; }
    hDisp = cmsCreate_sRGBProfile();
    if (!hDisp) { set_err(err, errLen, "Could not create the display profile."); goto done; }

    fmtIn = (srcBits == 16) ? TYPE_RGBA_16 : TYPE_RGBA_8;
    if (bpc) flagsPrint |= cmsFLAGS_BLACKPOINTCOMPENSATION;

    /* Step 1 is exactly the conversion the print uses: photo to paper values, 8 bit. */
    xfPrint = cmsCreateTransform(hIn, fmtIn, hPaper, TYPE_RGBA_8, (cmsUInt32Number)intent, flagsPrint);
    if (!xfPrint) { set_err(err, errLen, "Could not build the soft proof (the paper profile may not support this intent)."); goto done; }

    /* Step 2 shows those paper values on the screen. Relative maps paper white and black to screen white and
       black. Absolute keeps the paper's own white and black, so the proof looks as flat and warm as the paper. */
    if (!simulatePaper) flagsShow |= cmsFLAGS_BLACKPOINTCOMPENSATION;
    xfShow = cmsCreateTransform(hPaper, TYPE_RGBA_8, hDisp, TYPE_RGBA_8,
                                simulatePaper ? INTENT_ABSOLUTE_COLORIMETRIC : INTENT_RELATIVE_COLORIMETRIC,
                                flagsShow);
    if (!xfShow) { set_err(err, errLen, "Could not show the paper profile on screen."); goto done; }

    paperRGB = (uint8_t *)malloc((size_t)width * height * 4);
    if (!paperRGB) { set_err(err, errLen, "Out of memory."); goto done; }

    cmsDoTransformLineStride(xfPrint, src, paperRGB, width, height,
                             (cmsUInt32Number)srcStride, (cmsUInt32Number)(width * 4), 0, 0);
    cmsDoTransformLineStride(xfShow, paperRGB, dst, width, height,
                             (cmsUInt32Number)(width * 4), (cmsUInt32Number)dstStride, 0, 0);
    for (y = 0; y < height; y++) {
        uint8_t *row = dst + (size_t)y * dstStride;
        for (x = 0; x < width; x++) row[(size_t)x * 4 + 3] = 255;
    }
    rc = 0;

done:
    free(paperRGB);
    if (xfPrint) cmsDeleteTransform(xfPrint);
    if (xfShow) cmsDeleteTransform(xfShow);
    if (hIn) cmsCloseProfile(hIn);
    if (hPaper) cmsCloseProfile(hPaper);
    if (hDisp) cmsCloseProfile(hDisp);
    return rc;
}
