// darksix-icongen: builds the dark icon theme from the icons that are actually on this device.
// Run by the DarkSix package after install (as root). Output: /Library/Themes/DarkSix.theme/Icons/
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include "icon_core.h"

typedef struct { const char *bid; int mode; } Rule;

// 1 = white shape on colour -> colour shape on black     2 = dark shape on colour -> colour shape on black
// 3 = plain background goes black, picture stays         4 = paper icons: light <-> dark, colours stay
// 5 = darker
// Not listed (already dark, or SpringBoard draws on top of them): Calendar, Clock, Stocks, Calculator, Videos, Contacts, Passbook.
static const Rule rules[] = {
    {"com.apple.MobileSMS", 1}, {"com.apple.mobilephone", 1}, {"com.apple.mobilemail", 1},
    {"com.apple.facetime", 1}, {"com.apple.AppStore", 1}, {"com.apple.MobileStore", 1},
    {"com.apple.mobileipod", 2},
    {"com.apple.mobilesafari", 3}, {"com.apple.mobileslideshow", 3}, {"com.apple.camera", 3},
    {"com.apple.Preferences", 3}, {"com.apple.gamecenter", 3}, {"com.apple.compass", 3},
    {"com.apple.VoiceMemos", 3}, {"com.apple.weather", 3},
    {"com.apple.mobilenotes", 4}, {"com.apple.reminders", 4},
    {"com.apple.Maps", 5}, {"com.apple.newsstand", 5},
    {NULL, 0}
};

#define THEME_ICONS "/Library/Themes/DarkSix.theme/Icons"

static int is_ipad(void) {
    char buf[64];
    size_t len = sizeof(buf);
    memset(buf, 0, sizeof(buf));
    if (sysctlbyname("hw.machine", buf, &len, NULL, 0) != 0) return 0;
    return strncmp(buf, "iPad", 4) == 0;
}

static void make_dirs(void) {
    mkdir("/Library/Themes", 0755);
    mkdir("/Library/Themes/DarkSix.theme", 0755);
    mkdir(THEME_ICONS, 0755);
}

static int ends_with(const char *s, const char *suf) {
    size_t a = strlen(s), b = strlen(suf);
    return a >= b && strcmp(s + a - b, suf) == 0;
}

static CFDictionaryRef load_plist(const char *appPath) {
    char plist[1024];
    snprintf(plist, sizeof(plist), "%s/Info.plist", appPath);
    FILE *f = fopen(plist, "rb");
    if (f == NULL) return NULL;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz <= 0 || sz > 4000000) { fclose(f); return NULL; }
    unsigned char *buf = (unsigned char *)malloc((size_t)sz);
    if (buf == NULL || fread(buf, 1, (size_t)sz, f) != (size_t)sz) { fclose(f); free(buf); return NULL; }
    fclose(f);
    CFDataRef data = CFDataCreate(kCFAllocatorDefault, buf, sz);
    free(buf);
    if (data == NULL) return NULL;
    CFPropertyListRef pl = CFPropertyListCreateWithData(kCFAllocatorDefault, data, kCFPropertyListImmutable, NULL, NULL);
    CFRelease(data);
    if (pl == NULL) return NULL;
    if (CFGetTypeID(pl) != CFDictionaryGetTypeID()) { CFRelease(pl); return NULL; }
    return (CFDictionaryRef)pl;
}

static char *plist_bundle_id(CFDictionaryRef pl) {
    CFTypeRef v = CFDictionaryGetValue(pl, CFSTR("CFBundleIdentifier"));
    if (v != NULL && CFGetTypeID(v) == CFStringGetTypeID()) {
        char tmp[256];
        if (CFStringGetCString((CFStringRef)v, tmp, sizeof(tmp), kCFStringEncodingUTF8)) return strdup(tmp);
    }
    return NULL;
}

#define MAX_NAMES 40
typedef struct { char n[MAX_NAMES][200]; int count; } NameList;

static void add_name(NameList *l, CFTypeRef v) {
    if (v == NULL || CFGetTypeID(v) != CFStringGetTypeID() || l->count >= MAX_NAMES) return;
    if (CFStringGetCString((CFStringRef)v, l->n[l->count], 200, kCFStringEncodingUTF8)) l->count++;
}

static void add_names_array(NameList *l, CFTypeRef arr) {
    if (arr == NULL) return;
    if (CFGetTypeID(arr) == CFStringGetTypeID()) { add_name(l, arr); return; }
    if (CFGetTypeID(arr) != CFArrayGetTypeID()) return;
    CFIndex c = CFArrayGetCount((CFArrayRef)arr);
    for (CFIndex i = 0; i < c; i++) add_name(l, CFArrayGetValueAtIndex((CFArrayRef)arr, i));
}

// every icon file name the app's Info.plist mentions
static void collect_names(CFDictionaryRef pl, NameList *l) {
    l->count = 0;
    add_names_array(l, CFDictionaryGetValue(pl, CFSTR("CFBundleIconFiles")));
    add_names_array(l, CFDictionaryGetValue(pl, CFSTR("CFBundleIconFiles~ipad")));
    add_names_array(l, CFDictionaryGetValue(pl, CFSTR("CFBundleIconFile")));
    CFStringRef keys[2] = { CFSTR("CFBundleIcons"), CFSTR("CFBundleIcons~ipad") };
    for (int k = 0; k < 2; k++) {
        CFTypeRef ic = CFDictionaryGetValue(pl, keys[k]);
        if (ic != NULL && CFGetTypeID(ic) == CFDictionaryGetTypeID()) {
            CFTypeRef pr = CFDictionaryGetValue((CFDictionaryRef)ic, CFSTR("CFBundlePrimaryIcon"));
            if (pr != NULL && CFGetTypeID(pr) == CFDictionaryGetTypeID()) {
                add_names_array(l, CFDictionaryGetValue((CFDictionaryRef)pr, CFSTR("CFBundleIconFiles")));
            }
        }
    }
}

// returns the width of the processed icon (0 on failure); names the output by size
static int process_file(const char *src, const char *bid, int mode, int ipad) {
    CFStringRef sp = CFStringCreateWithCString(kCFAllocatorDefault, src, kCFStringEncodingUTF8);
    CFURLRef su = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, sp, kCFURLPOSIXPathStyle, false);
    CFRelease(sp);
    CGImageSourceRef is = CGImageSourceCreateWithURL(su, NULL);
    CFRelease(su);
    if (is == NULL) { printf("  cannot open %s\n", src); return 0; }
    CGImageRef img = CGImageSourceCreateImageAtIndex(is, 0, NULL);
    CFRelease(is);
    if (img == NULL) { printf("  cannot decode %s\n", src); return 0; }
    size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
    const char *suffix = NULL;
    if (w == h) {
        if (!ipad && w <= 60) suffix = ".png";
        else if (!ipad && w >= 100 && w <= 124) suffix = "@2x.png";
        else if (w >= 66 && w <= 80) suffix = ipad ? ".png" : "-72.png";
        else if (w >= 136 && w <= 160) suffix = ipad ? "@2x.png" : "-72@2x.png";
    }
    if (suffix == NULL) { printf("  skipping %s (%dx%d)\n", src, (int)w, (int)h); CGImageRelease(img); return 0; }
    char dst[1024];
    snprintf(dst, sizeof(dst), "%s/%s%s", THEME_ICONS, bid, suffix);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef bc = CGBitmapContextCreate(NULL, w, h, 8, w * 4, cs, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (bc == NULL) { CGImageRelease(img); return 0; }
    // opaque black underneath, so any transparent corner does not turn into garbage
    CGContextSetRGBFillColor(bc, 0, 0, 0, 1);
    CGContextFillRect(bc, CGRectMake(0, 0, (CGFloat)w, (CGFloat)h));
    CGContextDrawImage(bc, CGRectMake(0, 0, (CGFloat)w, (CGFloat)h), img);
    CGImageRelease(img);
    unsigned char *px = (unsigned char *)CGBitmapContextGetData(bc);
    size_t rb = CGBitmapContextGetBytesPerRow(bc);
    if (px == NULL) { CGContextRelease(bc); return 0; }
    unsigned char *tight = (unsigned char *)malloc(w * h * 4);
    if (tight == NULL) { CGContextRelease(bc); return 0; }
    for (size_t y = 0; y < h; y++) memcpy(tight + y * w * 4, px + y * rb, w * 4);
    ds_process(tight, (int)w, (int)h, mode);
    for (size_t y = 0; y < h; y++) memcpy(px + y * rb, tight + y * w * 4, w * 4);
    free(tight);
    CGImageRef out = CGBitmapContextCreateImage(bc);
    CGContextRelease(bc);
    if (out == NULL) return 0;
    CFStringRef dp = CFStringCreateWithCString(kCFAllocatorDefault, dst, kCFStringEncodingUTF8);
    CFURLRef du = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, dp, kCFURLPOSIXPathStyle, false);
    CFRelease(dp);
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL(du, CFSTR("public.png"), 1, NULL);
    CFRelease(du);
    int ok = 0;
    if (dest != NULL) {
        CGImageDestinationAddImage(dest, out, NULL);
        ok = CGImageDestinationFinalize(dest) ? 1 : 0;
        CFRelease(dest);
    }
    CGImageRelease(out);
    printf("  %s (%dx%d) -> %s %s\n", src, (int)w, (int)h, dst, ok ? "ok" : "FAILED");
    return ok ? (int)w : 0;
}

static void lower_copy(const char *s, char *out, size_t n) {
    size_t i = 0;
    for (; s[i] != 0 && i + 1 < n; i++) out[i] = (s[i] >= 'A' && s[i] <= 'Z') ? (char)(s[i] + 32) : s[i];
    out[i] = 0;
}

static int do_app(const char *appPath, const char *bid, int mode, int ipad, const NameList *names) {
    int done = 0;
    // 1. the files the Info.plist names (with and without .png, and the @2x / ~iphone variants)
    for (int i = 0; names != NULL && i < names->count; i++) {
        char base[200];
        strncpy(base, names->n[i], sizeof(base) - 1);
        base[sizeof(base) - 1] = 0;
        size_t bl = strlen(base);
        if (bl > 4 && strcmp(base + bl - 4, ".png") == 0) base[bl - 4] = 0;
        const char *forms[6] = { "%s/%s.png", "%s/%s@2x.png", "%s/%s~iphone.png", "%s/%s@2x~iphone.png", "%s/%s~ipad.png", "%s/%s@2x~ipad.png" };
        for (int f = 0; f < 6; f++) {
            char src[1024];
            snprintf(src, sizeof(src), forms[f], appPath, base);
            if (access(src, R_OK) != 0) continue;
            if (process_file(src, bid, mode, ipad) > 0) done++;
        }
    }
    // 2. anything in the folder with "icon" in its name
    DIR *d = opendir(appPath);
    if (d == NULL) return done;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        char l[300];
        lower_copy(e->d_name, l, sizeof(l));
        if (!ends_with(l, ".png")) continue;
        if (strstr(l, "icon") == NULL) continue;
        if (strstr(l, "small") != NULL || strstr(l, "spotlight") != NULL || strstr(l, "settings") != NULL ||
            strstr(l, "launch") != NULL || strstr(l, "default") != NULL || strstr(l, "artwork") != NULL ||
            strstr(l, "notification") != NULL || strstr(l, "document") != NULL) continue;
        char src[1024];
        snprintf(src, sizeof(src), "%s/%s", appPath, e->d_name);
        if (process_file(src, bid, mode, ipad) > 0) done++;
    }
    closedir(d);
    if (done == 0) {
        printf("  Info.plist icon names: %d\n", names != NULL ? names->count : 0);
        for (int i = 0; names != NULL && i < names->count; i++) printf("    %s\n", names->n[i]);
        printf("  no usable icon files found in %s; its files:\n", appPath);
        d = opendir(appPath);
        if (d != NULL) {
            int shown = 0;
            while ((e = readdir(d)) != NULL && shown < 40) {
                if (e->d_name[0] == '.') continue;
                printf("    %s\n", e->d_name);
                shown++;
            }
            closedir(d);
        }
    }
    return done;
}

int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "--remove") == 0) {
        DIR *d = opendir(THEME_ICONS);
        if (d != NULL) {
            struct dirent *e;
            while ((e = readdir(d)) != NULL) {
                if (e->d_name[0] == '.') continue;
                char p[1024];
                snprintf(p, sizeof(p), "%s/%s", THEME_ICONS, e->d_name);
                unlink(p);
            }
            closedir(d);
        }
        return 0;
    }
    make_dirs();
    int ipad = is_ipad();
    printf("DarkSix icon generator (%s)\n", ipad ? "iPad" : "iPhone/iPod");
    DIR *d = opendir("/Applications");
    if (d == NULL) return 0;
    struct dirent *e;
    int found = 0;
    while ((e = readdir(d)) != NULL) {
        if (!ends_with(e->d_name, ".app")) continue;
        char appPath[1024];
        snprintf(appPath, sizeof(appPath), "/Applications/%s", e->d_name);
        CFDictionaryRef pl = load_plist(appPath);
        if (pl == NULL) continue;
        char *bid = plist_bundle_id(pl);
        if (bid == NULL) { CFRelease(pl); continue; }
        for (int i = 0; rules[i].bid != NULL; i++) {
            if (strcmp(rules[i].bid, bid) == 0) {
                printf("%s (%s)\n", appPath, bid);
                NameList names;
                collect_names(pl, &names);
                found += (do_app(appPath, bid, rules[i].mode, ipad, &names) > 0) ? 1 : 0;
                break;
            }
        }
        free(bid);
        CFRelease(pl);
    }
    closedir(d);
    printf("DarkSix icons: %d apps processed\n", found);
    fflush(stdout);
    return 0;
}
