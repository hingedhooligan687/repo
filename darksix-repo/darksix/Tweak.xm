// DarkSix - experimental dark mode for stock iOS 6 apps.
// Idea: remap light backgrounds to dark and dark text to light at the point
// where apps set their colors, then fix up tables, cells, bars and keyboards.
// No libc string functions are used (they fail to link with the new toolchain).

#import <UIKit/UIKit.h>
#include "icon_core.h"
#include "kb_core.h"
#import <QuartzCore/QuartzCore.h>

// Diagnostic files are only written while the file /var/mobile/Library/Caches/DarkSix-debug exists.
// Normally nothing is logged, which saves battery and storage. (The file is checked at most every few seconds.)
static BOOL DSDebugOn(void) {
    static BOOL on = NO;
    static CFAbsoluteTime last = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (last == 0 || now - last > 5.0) {
        last = now;
        on = [[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/Library/Caches/DarkSix-debug"];
    }
    return on;
}
#import <objc/runtime.h>
#include <string.h>

// Messages' typing bar (found with the view dump). Declared only so we can hook it.
@interface CKMessageEntryView : UIImageView
@end

// The nav bar's back button draws itself (no subviews); declared so we can hook it.
@interface UINavigationItemButtonView : UIView
@end

static BOOL dsIsMessages = NO;   // running inside Messages
static BOOL dsDrawMap = NO;      // remap colors used for custom drawing (Mail, Contacts)
static BOOL dsMessagesHooked = NO;
static BOOL dsStyleBypass = NO;  // lets us flip a bar style ourselves
static NSMutableDictionary *dsImgCache = nil;
static BOOL dsInBackDraw = NO;  // true while the nav back button is drawing
static BOOL dsOptLinen = NO;       // setting: "Apple Linen" behind iMessage conversations
static BOOL dsOptIcons = YES;      // setting: dark Home screen icons (SpringBoard)
static BOOL dsOptKeyboard = YES;   // setting: dark keyboard (default on)
static BOOL dsOptPinstripes = NO;  // setting: dark "Apple Pinstripes" in Settings
static BOOL dsIsSettings = NO;     // running inside Settings
static int dsMusicDumps = 0;
static int dsHdrTries = 0;
static BOOL dsInCellBg = NO;      // Settings: drawing a grouped-table cell background (its light edge line is made near-black)
static BOOL dsInMusicCell = NO;   // drawing a Music song row (its own white divider lines are skipped)
static BOOL dsInHeaderDraw = NO;   // drawing a Music section header (the A, B, C bars)
static void DSInstallHeaderHooks(void);
static BOOL dsInStatusDraw = NO;   // drawing a status bar item (battery, signal): never recolor those
static BOOL dsIsCal = NO;          // running inside Calendar
static BOOL dsIsExtra = NO;        // Calendar, Photos or Videos
static BOOL dsIsMusic = NO;        // running inside the Music app
static BOOL dsInBarBgDraw = NO; // true while the nav bar background view is drawing
static CGFloat dsSatMin = 0.12;  // how colorful a pixel must be to count as "blue" when recoloring
static IMP dsOrigBgDraw = NULL;
static Class dsNavBgClass = Nil;
static BOOL dsInHook = NO;       // guards against our own image drawing re-entering the hook
static BOOL dsComposeDumped = NO;
static int dsBalTries = 0;
static BOOL dsBypass = NO;       // set while we assign colors ourselves, so our own hooks leave them alone

// ---------- string helpers ----------

static BOOL DSHasPrefix(const char *n, const char *p) {
    if (n == NULL) return NO;
    while (*p != '\0' && *n == *p) {
        n++;
        p++;
    }
    return *p == '\0';
}

static BOOL DSContains(const char *name, const char *needle) {
    if (name == NULL || *needle == '\0') return NO;
    for (const char *h = name; *h != '\0'; h++) {
        if (DSHasPrefix(h, needle)) return YES;
    }
    return NO;
}

// ---------- optional background pictures (installed in /usr/share/DarkSix) ----------

static UIColor *DSPatternNamed(NSString *name) {
    static NSMutableDictionary *cache = nil;
    if (cache == nil) {
        cache = [[NSMutableDictionary alloc] init];
    }
    id hit = [cache objectForKey:name];
    if (hit != nil) {
        return (hit == (id)[NSNull null]) ? nil : (UIColor *)hit;
    }
    UIColor *col = nil;
    NSString *path = [[@"/usr/share/DarkSix" stringByAppendingPathComponent:name] stringByAppendingString:@".png"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data != nil) {
        UIImage *img = [UIImage imageWithData:data];
        if (img != nil && img.CGImage != NULL) {
            // the pictures are made for the Retina screen
            UIImage *scaled = [UIImage imageWithCGImage:img.CGImage scale:2.0 orientation:UIImageOrientationUp];
            col = [UIColor colorWithPatternImage:scaled];
        }
    }
    [cache setObject:((col != nil) ? (id)col : (id)[NSNull null]) forKey:name];
    return col;
}

// background behind a conversation (not the conversation list)
static UIColor *DSTranscriptColor(void) {
    UIColor *c = dsOptLinen ? DSPatternNamed(@"linen") : nil;
    return (c != nil) ? c : [UIColor blackColor];
}

// ---------- color helpers ----------

// Reads brightness (L), saturation (S) and alpha (A) of plain gray/RGB colors.
// Returns NO for pattern/other colors, which we leave alone.
static BOOL DSInfo(UIColor *c, CGFloat *L, CGFloat *S, CGFloat *A) {
    if (!c) return NO;
    CGColorRef cg = c.CGColor;
    if (!cg) return NO;
    CGColorSpaceModel m = CGColorSpaceGetModel(CGColorGetColorSpace(cg));
    size_t n = CGColorGetNumberOfComponents(cg);
    const CGFloat *p = CGColorGetComponents(cg);
    if (m == kCGColorSpaceModelMonochrome && n == 2) {
        *L = p[0]; *S = 0; *A = p[1];
        return YES;
    }
    if (m == kCGColorSpaceModelRGB && n == 4) {
        CGFloat r = p[0], g = p[1], b = p[2];
        CGFloat mx = MAX(r, MAX(g, b)), mn = MIN(r, MIN(g, b));
        *L = 0.299 * r + 0.587 * g + 0.114 * b;
        *S = mx > 0 ? (mx - mn) / mx : 0;
        *A = p[3];
        return YES;
    }
    return NO;
}

// light, neutral background -> dark (white becomes black; in Messages, dark gray)
static UIColor *DSBackground(UIColor *c) {
    CGFloat L, S, A;
    if (!DSInfo(c, &L, &S, &A) || A < 0.05 || S > 0.35 || L < 0.5) return c;
    CGFloat v = 1.0 - L;
    if (dsIsMessages && v < 0.17) v = 0.17;
    return [UIColor colorWithWhite:v alpha:A];
}

// Settings: the dull dark blue of values like "Off" / "Not Connected" -> brighter iOS blue
static UIColor *DSBrightBlue(UIColor *c) {
    if (c == nil || c.CGColor == NULL) return nil;
    CGColorRef cg = c.CGColor;
    if (CGColorSpaceGetModel(CGColorGetColorSpace(cg)) != kCGColorSpaceModelRGB || CGColorGetNumberOfComponents(cg) != 4) return nil;
    const CGFloat *p = CGColorGetComponents(cg);
    CGFloat r = p[0], g = p[1], b = p[2], a = p[3];
    if (a < 0.3 || b < 0.3 || b > 0.8) return nil;
    if (b < r + 0.18 || b < g + 0.08) return nil;          // not a blue
    return [UIColor colorWithRed:0.15 green:0.48 blue:0.92 alpha:a];
}

// dark, neutral text -> light (black becomes white)
static UIColor *DSText(UIColor *c) {
    if (dsIsSettings || dsIsExtra) {
        UIColor *bb = DSBrightBlue(c);
        if (bb != nil) return bb;
    }
    CGFloat L, S, A;
    if (!DSInfo(c, &L, &S, &A) || A < 0.05 || S > 0.35 || L > 0.5) return c;
    CGFloat v = 1.0 - L;
    if (dsIsMusic) {                            // Music lists: titles pure white, detail text light gray
        if (L <= 0.2) {
            v = 1.0;
        } else if (v < 0.62) {
            v = 0.62;
        }
    }
    return [UIColor colorWithWhite:v alpha:A];
}

// opaque white / nearGlyph white
static BOOL DSIsSolidWhite(UIColor *c) {
    CGFloat L = 0, S = 0, A = 0;
    return DSInfo(c, &L, &S, &A) && A > 0.9 && L > 0.9 && S < 0.2;
}

// a light color (used to spot the white "emboss" shadows under dark text)
static BOOL DSIsLightColor(UIColor *c) {
    CGFloat L = 0, S = 0, A = 0;
    return DSInfo(c, &L, &S, &A) && A > 0.05 && L > 0.6;
}

// ---------- places we must NOT touch ----------
// Light image-based surfaces with dark text on top: alert/action sheets, pickers,
// popovers, chat bubbles, keyboard, search field, web content.

static BOOL DSPrefixEx(const char *n, BOOL ignoreCK) {
    static const char *p[] = {
        "UIKB", "UIKeyboard", "UIStatusBar", "UIWeb", "_UIWeb", "CK",
        "UISearchBar", "UIAlert", "_UIAlert", "UIThreePart", "UIActionSheet",
        "UIPopover", "_UIPopover", "UIPicker", "UIDatePicker", "UIDimming",
        "UIActivity", "UIInputSwitcher", "UIAutocorrect"
    };
    if (dsIsMessages && !ignoreCK) {
        // New Message screen (MessageUI views): keep the stock light look so nothing is half-dark
        if (DSHasPrefix(n, "MF") || DSContains(n, "Recipient") || DSContains(n, "Compose")) return YES;
    }
    for (unsigned i = 0; i < sizeof(p) / sizeof(p[0]); i++) {
        if (ignoreCK && DSHasPrefix(p[i], "CK")) continue;
        if (DSHasPrefix(n, p[i])) return YES;
    }
    return NO;
}

static BOOL DSAvoidEx(UIView *v, BOOL ignoreCK) {
    int depth = 0;
    for (UIView *x = v; x != nil && depth < 10; x = x.superview, depth++) {
        if (DSPrefixEx(class_getName(object_getClass(x)), ignoreCK)) return YES;
        if (dsIsMusic) {
            // Music: keep the whole Now Playing screen stock (its view controller owns the view)
            UIResponder *r = [x nextResponder];
            if (r != nil && [r isKindOfClass:[UIViewController class]] &&
                DSContains(class_getName(object_getClass(r)), "NowPlaying")) {
                return YES;
            }
        }
    }
    return NO;
}

static BOOL DSAvoid(UIView *v) {
    return DSAvoidEx(v, NO);
}

// Switch to the dark keyboard, but only if this object really supports it
// (iOS 6 UISearchBar does not, and asking it crashes the app).
static void DSDarkKeyboard(id obj) {
    if (!dsOptKeyboard) return;
    if ([obj respondsToSelector:@selector(keyboardAppearance)] &&
        [obj respondsToSelector:@selector(setKeyboardAppearance:)]) {
        if ([(UITextField *)obj keyboardAppearance] == UIKeyboardAppearanceDefault) {
            [(UITextField *)obj setKeyboardAppearance:(UIKeyboardAppearance)1];
        }
    }
}

// ---------- Messages: typing bubble stays white with black text ----------

static BOOL DSIsDarkOpaque(UIColor *c) {
    CGFloat L = 0, S = 0, A = 0;
    return DSInfo(c, &L, &S, &A) && A > 0.9 && S < 0.35 && L < 0.5;
}

static BOOL DSIsEditableTextView(UIView *v) {
    return [v isKindOfClass:[UITextView class]] && ((UITextView *)v).editable;
}

static BOOL DSHasEditableChild(UIView *v) {
    for (UIView *sv in v.subviews) {
        if (DSIsEditableTextView(sv)) return YES;
    }
    return NO;
}

// a view that sits behind/around an editable text view (the pill that holds it)
static BOOL DSHasEditableSibling(UIView *v) {
    UIView *p = v.superview;
    if (p == nil) return NO;
    for (UIView *sv in p.subviews) {
        if (sv != v && DSIsEditableTextView(sv) && CGRectIntersectsRect(sv.frame, v.frame)) return YES;
    }
    return NO;
}

// The message entry text view: make its bubble light gray (the text view, small
// containers around it, and any pill-sized view sitting behind it) and the typed text black.
static void DSWhiteBubble(UITextView *tv) {
    dsBypass = YES;
    UIColor *light = [UIColor colorWithWhite:0.86 alpha:1.0];
    if (DSIsDarkOpaque(tv.backgroundColor)) {
        tv.backgroundColor = light;
    }
    int depth = 0;
    for (UIView *anc = tv.superview; anc != nil && depth < 3; anc = anc.superview, depth++) {
        if (anc.bounds.size.height < 130.0 && DSIsDarkOpaque(anc.backgroundColor)) {
            anc.backgroundColor = light;
        }
        CGRect r = [tv convertRect:tv.bounds toView:anc];
        for (UIView *sv in anc.subviews) {
            if (sv != tv &&
                sv.bounds.size.height < 130.0 &&
                sv.bounds.size.width >= tv.bounds.size.width * 0.6 &&
                CGRectIntersectsRect(sv.frame, r) &&
                DSIsDarkOpaque(sv.backgroundColor)) {
                sv.backgroundColor = light;
            }
        }
    }
    tv.textColor = [UIColor blackColor];
    dsBypass = NO;
}

// Messages nav/tool bar buttons: no blue tint, no blue "Done" style
static void DSFixBarItem(UIBarButtonItem *item) {
    if (item == nil) return;
    item.tintColor = nil;
    if (item.style == UIBarButtonItemStyleDone) {
        item.style = UIBarButtonItemStyleBordered;
    }
}

static void DSFixNavItem(UINavigationItem *it) {
    if (it == nil) return;
    DSFixBarItem(it.leftBarButtonItem);
    DSFixBarItem(it.rightBarButtonItem);
    DSFixBarItem(it.backBarButtonItem);
    for (UIBarButtonItem *b in it.leftBarButtonItems) {
        DSFixBarItem(b);
    }
    for (UIBarButtonItem *b in it.rightBarButtonItems) {
        DSFixBarItem(b);
    }
}

// ---------- Messages: darken the typing bar's pictures ----------

static NSMutableDictionary *dsBarCache = nil;

// Light neutral picture -> dark gray (keeps shading, edges and transparency).
// Returns NULL if the picture is already dark or has nothing to change.
static CGImageRef DSDarkNeutralCGImageCreate(CGImageRef src) {
    if (src == NULL) return NULL;
    size_t w = CGImageGetWidth(src);
    size_t h = CGImageGetHeight(src);
    if (w == 0 || h == 0 || w > 2000 || h > 2000) return NULL;
    NSMutableData *buf = [NSMutableData dataWithLength:w * h * 4];
    uint8_t *px = (uint8_t *)[buf mutableBytes];
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, w, h, 8, w * 4, cs,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (ctx == NULL) return NULL;
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), src);

    // how bright is the picture overall? if it is already dark, leave it alone
    double sum = 0, cnt = 0;
    for (size_t i = 0; i < w * h; i++) {
        uint8_t *p = px + i * 4;
        if (p[3] > 200) {
            sum += (0.299 * p[0] + 0.587 * p[1] + 0.114 * p[2]) / 255.0;
            cnt += 1;
        }
    }
    if (cnt < 1 || (sum / cnt) < 0.5) {
        CGContextRelease(ctx);
        return NULL;
    }

    for (size_t i = 0; i < w * h; i++) {
        uint8_t *p = px + i * 4;
        CGFloat a = p[3] / 255.0;
        if (a < 0.02) continue;
        CGFloat r = p[0] / 255.0 / a;
        CGFloat g = p[1] / 255.0 / a;
        CGFloat b = p[2] / 255.0 / a;
        if (r > 1.0) r = 1.0;
        if (g > 1.0) g = 1.0;
        if (b > 1.0) b = 1.0;
        CGFloat mx = MAX(r, MAX(g, b));
        CGFloat mn = MIN(r, MIN(g, b));
        CGFloat sat = (mx > 0) ? (mx - mn) / mx : 0;
        if (sat < 0.35) {
            CGFloat L = 0.299 * r + 0.587 * g + 0.114 * b;
            CGFloat gv = 0.48 * L * L;
            uint8_t v = (uint8_t)(gv * a * 255.0 + 0.5);
            p[0] = v;
            p[1] = v;
            p[2] = v;
        }
    }
    CGImageRef out = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return out;
}

static UIImage *DSDarkBarImage(UIImage *img) {
    if (img == nil || img.CGImage == NULL) return img;
    if (dsBarCache == nil) {
        dsBarCache = [[NSMutableDictionary alloc] init];
    }
    NSValue *key = [NSValue valueWithPointer:img];
    NSArray *e = [dsBarCache objectForKey:key];
    if (e == nil) {
        UIImage *res = nil;
        CGImageRef out = DSDarkNeutralCGImageCreate(img.CGImage);
        if (out != NULL) {
            res = [UIImage imageWithCGImage:out scale:img.scale orientation:UIImageOrientationUp];
            CGImageRelease(out);
            UIEdgeInsets caps = img.capInsets;
            if (!UIEdgeInsetsEqualToEdgeInsets(caps, UIEdgeInsetsZero)) {
                res = [res resizableImageWithCapInsets:caps];
            } else if (img.leftCapWidth > 0 || img.topCapHeight > 0) {
                res = [res stretchableImageWithLeftCapWidth:img.leftCapWidth topCapHeight:img.topCapHeight];
            }
        }
        id second = (res != nil) ? (id)res : (id)img;
        e = [NSArray arrayWithObjects:img, second, nil];      // keeps the original alive so the key stays valid
        [dsBarCache setObject:e forKey:key];
        if (res != nil) {
            // the dark result maps to itself, so it is never darkened twice
            [dsBarCache setObject:[NSArray arrayWithObjects:res, res, nil] forKey:[NSValue valueWithPointer:res]];
        }
    }
    return (UIImage *)[e objectAtIndex:1];
}

// ---------- Messages: typing bar pill, nav button images ----------

// The typing bar (CKMessageEntryView) holds a plain UIView that is the pill behind the text.
// Make that pill light gray, and give the "iMessage" placeholder a readable gray.
static void DSFixPlaceholders(UIView *v, int depth) {
    if (depth > 4) return;
    for (UIView *sv in v.subviews) {
        if (object_getClass(sv) == [UILabel class]) {
            UILabel *lb = (UILabel *)sv;
            CGFloat L = 0, S = 0, A = 0;
            if (DSInfo(lb.textColor, &L, &S, &A) && L > 0.6) {
                lb.textColor = [UIColor colorWithWhite:0.42 alpha:1.0];
            }
        }
        DSFixPlaceholders(sv, depth + 1);
    }
}

static void DSFixEntry(UIView *entry) {
    dsBypass = YES;
    UIColor *pillColor = [UIColor colorWithWhite:0.75 alpha:1.0];
    for (UIView *sv in entry.subviews) {
        if (object_getClass(sv) == [UIView class] &&
            sv.bounds.size.width > 120.0 && sv.bounds.size.height > 20.0) {
            CGFloat L = 0, S = 0, A = 0;
            BOOL ok = DSInfo(sv.backgroundColor, &L, &S, &A);
            if (!ok || A < 0.9 || L < 0.73 || L > 0.77) {
                sv.backgroundColor = pillColor;
            }
        }
    }
    DSFixPlaceholders(entry, 0);
    dsBypass = NO;

    // the bar behind everything, and the overlay that frames the pill: dark gray pictures
    if ([entry isKindOfClass:[UIImageView class]]) {
        UIImageView *bar = (UIImageView *)entry;
        UIImage *bi = bar.image;
        UIImage *bd = DSDarkBarImage(bi);
        if (bd != bi) {
            bar.image = bd;
        }
    }
    for (UIView *sv in entry.subviews) {
        if (object_getClass(sv) == [UIImageView class] &&
            sv.bounds.size.width > 150.0 && sv.bounds.size.height >= 30.0) {
            UIImageView *ov = (UIImageView *)sv;
            UIImage *oi = ov.image;
            UIImage *od = DSDarkBarImage(oi);
            if (od != oi) {
                ov.image = od;
            }
        }
    }
}

// Recolor a bluish bar-button image to graphite (keeps shape, shading and stretch caps).
// Returns a new (retained) CGImage, or NULL if the image has nothing blue in it.
static CGImageRef DSGraphiteCGImageCreate(CGImageRef src) {
    if (src == NULL) return NULL;
    size_t w = CGImageGetWidth(src);
    size_t h = CGImageGetHeight(src);
    if (w == 0 || h == 0 || w > 2000 || h > 2000) return NULL;
    NSMutableData *buf = [NSMutableData dataWithLength:w * h * 4];
    uint8_t *px = (uint8_t *)[buf mutableBytes];
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, w, h, 8, w * 4, cs,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (ctx == NULL) return NULL;
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), src);

    BOOL changed = NO;
    for (size_t i = 0; i < w * h; i++) {
        uint8_t *p = px + i * 4;
        CGFloat a = p[3] / 255.0;
        if (a < 0.02) continue;
        CGFloat r = p[0] / 255.0 / a;
        CGFloat g = p[1] / 255.0 / a;
        CGFloat b = p[2] / 255.0 / a;
        if (r > 1.0) r = 1.0;
        if (g > 1.0) g = 1.0;
        if (b > 1.0) b = 1.0;
        CGFloat mx = MAX(r, MAX(g, b));
        CGFloat mn = MIN(r, MIN(g, b));
        CGFloat sat = (mx > 0) ? (mx - mn) / mx : 0;
        if (sat > dsSatMin && b > r) {
            CGFloat L = 0.299 * r + 0.587 * g + 0.114 * b;
            CGFloat gv = 0.55 * L * L;               // graphite, highlights stay lighter
            uint8_t v = (uint8_t)(gv * a * 255.0 + 0.5);
            p[0] = v;
            p[1] = v;
            p[2] = v;
            changed = YES;
        }
    }
    CGImageRef out = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    if (out != NULL && !changed) {
        CGImageRelease(out);
        out = NULL;
    }
    return out;
}

static UIImage *DSGraphiteImage(UIImage *img) {
    if (img == nil || img.CGImage == NULL) return nil;
    CGImageRef out = DSGraphiteCGImageCreate(img.CGImage);
    if (out == NULL) return nil;
    UIImage *res = [UIImage imageWithCGImage:out scale:img.scale orientation:UIImageOrientationUp];
    CGImageRelease(out);
    UIEdgeInsets caps = img.capInsets;
    if (!UIEdgeInsetsEqualToEdgeInsets(caps, UIEdgeInsetsZero)) {
        res = [res resizableImageWithCapInsets:caps];
    }
    return res;
}

static UIImage *DSNavImage(UIImage *img) {
    if (img == nil) return img;
    if (dsImgCache == nil) {
        dsImgCache = [[NSMutableDictionary alloc] init];
    }
    NSValue *key = [NSValue valueWithPointer:img];
    NSArray *e = [dsImgCache objectForKey:key];
    if (e == nil) {
        UIImage *r = DSGraphiteImage(img);
        id second = (r != nil) ? (id)r : (id)[NSNull null];
        e = [NSArray arrayWithObjects:img, second, nil];     // keeps the original alive so the key stays valid
        [dsImgCache setObject:e forKey:key];
    }
    id r2 = [e objectAtIndex:1];
    return (r2 == [NSNull null]) ? img : (UIImage *)r2;
}

// same idea for raw CGImages (button pictures that live directly on a layer)
static CGImageRef DSNavCGImage(CGImageRef src) {
    if (src == NULL) return src;
    if (dsImgCache == nil) {
        dsImgCache = [[NSMutableDictionary alloc] init];
    }
    NSValue *key = [NSValue valueWithPointer:src];
    NSArray *e = [dsImgCache objectForKey:key];
    if (e == nil) {
        CGImageRef out = DSGraphiteCGImageCreate(src);
        id second = (out != NULL) ? (id)out : (id)[NSNull null];
        e = [NSArray arrayWithObjects:(id)src, second, nil];
        [dsImgCache setObject:e forKey:key];
        if (out != NULL) {
            CGImageRelease(out);                              // the array holds it now
        }
    }
    id r2 = [e objectAtIndex:1];
    return (r2 == [NSNull null]) ? src : (CGImageRef)r2;
}

static BOOL DSIsNavButtonChild(UIView *v) {
    UIView *p = v.superview;
    if (p == nil) return NO;
    const char *n = class_getName(object_getClass(p));
    return DSHasPrefix(n, "UINavigationButton") || DSHasPrefix(n, "UINavigationItemButtonView");
}

static void DSRecolorLayerTree(CALayer *layer, int depth) {
    if (layer == nil || depth > 6) return;
    id c = layer.contents;
    if (c != nil && CFGetTypeID((CFTypeRef)c) == CGImageGetTypeID()) {
        CGImageRef n = DSNavCGImage((CGImageRef)c);
        if (n != (CGImageRef)c) {
            layer.contents = (id)n;
        }
    }
    for (CALayer *sub in layer.sublayers) {
        DSRecolorLayerTree(sub, depth + 1);
    }
}

static void DSWhiteLabels(UIView *v, int depth) {
    if (v == nil || depth > 4) return;
    if ([v isKindOfClass:[UILabel class]]) {
        UILabel *l = (UILabel *)v;
        l.textColor = [UIColor whiteColor];
        l.shadowColor = [UIColor colorWithWhite:0.1 alpha:1.0];
        l.shadowOffset = CGSizeMake(0, -1);
    }
    NSArray *subs = [NSArray arrayWithArray:v.subviews];
    for (UIView *x in subs) {
        DSWhiteLabels(x, depth + 1);
    }
}

// Recolor every blue button picture currently in a nav bar (bar buttons and the back button).
static void DSRecolorNavBar(UINavigationBar *bar) {
    if (bar == nil) return;
    if (dsIsExtra) {
        for (UIView *sv in bar.subviews) {
            const char *n2 = class_getName(object_getClass(sv));
            if (DSHasPrefix(n2, "UINavigationButton") || DSHasPrefix(n2, "UINavigationItemButtonView")) {
                DSWhiteLabels(sv, 0);          // button titles (Done, Cancel...) white with a dark shadow
            }
        }
    }
    for (UIView *sv in bar.subviews) {
        const char *n = class_getName(object_getClass(sv));
        if (DSHasPrefix(n, "UINavigationButton") || DSHasPrefix(n, "UINavigationItemButtonView")) {
            DSRecolorLayerTree(sv.layer, 0);
        } else if (DSHasPrefix(n, "_UINavigationBarBackground")) {
            dsSatMin = 0.08;                 // the bar gradient is only lightly blue
            DSRecolorLayerTree(sv.layer, 0);
            dsSatMin = 0.12;
        }
    }
}

// Calendar/Photos/Videos: blue toolbar buttons and the List/Day/Month control -> graphite
static UIImage *DSNavImage(UIImage *img);

static void DSRecolorBranch(UIView *v, int depth) {
    if (v == nil || depth > 8) return;
    DSRecolorLayerTree(v.layer, 5);                       // only this layer's own picture (depth guard)
    if ([v isKindOfClass:[UIImageView class]]) {
        UIImageView *iv = (UIImageView *)v;
        UIImage *a = iv.image;
        if (a != nil) {
            UIImage *b = DSNavImage(a);
            if (b != a) iv.image = b;
        }
        UIImage *h = iv.highlightedImage;
        if (h != nil) {
            UIImage *h2 = DSNavImage(h);
            if (h2 != h) iv.highlightedImage = h2;
        }
    }
    NSArray *subs = [NSArray arrayWithArray:v.subviews];
    for (UIView *x in subs) {
        DSRecolorBranch(x, depth + 1);
    }
}

static void DSRecolorBars(UIView *v, int depth) {
    if (v == nil || depth > 10) return;
    const char *n = class_getName(object_getClass(v));
    if (DSHasPrefix(n, "UIToolbar") || DSHasPrefix(n, "UISegmentedControl") || DSHasPrefix(n, "UISegment")) {
        DSRecolorBranch(v, 0);
        return;
    }
    NSArray *subs = [NSArray arrayWithArray:v.subviews];
    for (UIView *x in subs) {
        DSRecolorBars(x, depth + 1);
    }
}

// ---------- diagnostics: view tree of the New Message screen ----------

static void DSAppendDump(NSString *text) {
    if (!DSDebugOn()) return;
    NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *dir = ([dirs count] > 0) ? [dirs objectAtIndex:0] : NSTemporaryDirectory();
    NSString *path = [dir stringByAppendingPathComponent:@"DarkSix-compose.txt"];
    [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

static void DSDumpKeyWindow(void) {
    UIWindow *w = [[UIApplication sharedApplication] keyWindow];
    if (w != nil && [w respondsToSelector:@selector(recursiveDescription)]) {
        NSString *d = [w performSelector:@selector(recursiveDescription)];
        if (d != nil) {
            DSAppendDump(d);
        }
    }
}

// ---------- Music: light title text, white glyphs ----------

static NSDictionary *DSLightTitleAttrs(void) {
    return [NSDictionary dictionaryWithObjectsAndKeys:
            [UIColor whiteColor], UITextAttributeTextColor,
            [UIColor blackColor], UITextAttributeTextShadowColor,
            [NSValue valueWithUIOffset:UIOffsetMake(0, -1)], UITextAttributeTextShadowOffset,
            nil];
}

static NSMutableDictionary *dsGlyphCache = nil;

// small dark neutral glyph (like the Shuffle arrows) -> white. NULL if it is not one.
static CGImageRef DSLightGlyphCGImageCreate(CGImageRef src) {
    if (src == NULL) return NULL;
    size_t w = CGImageGetWidth(src);
    size_t h = CGImageGetHeight(src);
    if (w == 0 || h == 0 || w > 90 || h > 90) return NULL;     // album art and big pictures are left alone
    NSMutableData *buf = [NSMutableData dataWithLength:w * h * 4];
    uint8_t *px = (uint8_t *)[buf mutableBytes];
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, w, h, 8, w * 4, cs,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (ctx == NULL) return NULL;
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), src);

    double sum = 0, wsum = 0, neutral = 0, cnt = 0;
    for (size_t i = 0; i < w * h; i++) {
        uint8_t *p = px + i * 4;
        if (p[3] < 80) continue;
        double a = p[3] / 255.0;
        double r = p[0] / 255.0 / a, g = p[1] / 255.0 / a, b = p[2] / 255.0 / a;
        double mx = MAX(r, MAX(g, b)), mn = MIN(r, MIN(g, b));
        double sat = (mx > 0) ? (mx - mn) / mx : 0;
        sum += (0.299 * r + 0.587 * g + 0.114 * b) * a;
        wsum += a;
        cnt += 1;
        if (sat < 0.35) neutral += 1;
    }
    if (cnt < 4 || wsum <= 0 || (sum / wsum) > 0.3 || (neutral / cnt) < 0.9) {
        CGContextRelease(ctx);
        return NULL;
    }
    for (size_t i = 0; i < w * h; i++) {
        uint8_t *p = px + i * 4;
        double a = p[3] / 255.0;
        if (a < 0.01) continue;
        double r = p[0] / 255.0 / a, g = p[1] / 255.0 / a, b = p[2] / 255.0 / a;
        double L = 0.299 * r + 0.587 * g + 0.114 * b;
        if (L > 1.0) L = 1.0;
        uint8_t v = (uint8_t)((1.0 - L) * a * 255.0 + 0.5);
        p[0] = v;
        p[1] = v;
        p[2] = v;
    }
    CGImageRef out = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return out;
}

static UIImage *DSLightGlyphImage(UIImage *img) {
    if (img == nil || img.CGImage == NULL) return img;
    if (dsGlyphCache == nil) {
        dsGlyphCache = [[NSMutableDictionary alloc] init];
    }
    NSValue *key = [NSValue valueWithPointer:img];
    NSArray *e = [dsGlyphCache objectForKey:key];
    if (e == nil) {
        UIImage *res = nil;
        CGImageRef out = DSLightGlyphCGImageCreate(img.CGImage);
        if (out != NULL) {
            res = [UIImage imageWithCGImage:out scale:img.scale orientation:UIImageOrientationUp];
            CGImageRelease(out);
        }
        id second = (res != nil) ? (id)res : (id)img;
        e = [NSArray arrayWithObjects:img, second, nil];
        [dsGlyphCache setObject:e forKey:key];
        if (res != nil) {
            [dsGlyphCache setObject:[NSArray arrayWithObjects:res, res, nil] forKey:[NSValue valueWithPointer:res]];
        }
    }
    return (UIImage *)[e objectAtIndex:1];
}

static BOOL DSInSectionHeader(UIView *v) {
    if ([v isKindOfClass:[UILabel class]] && [v.superview isKindOfClass:[UIImageView class]] &&
        [v.superview.superview isKindOfClass:[UITableView class]]) {
        return YES;                  // Music: the silver A, B, C bar is an image view holding a label
    }
    int d = 0;
    for (UIView *x = v; x != nil && d < 5; x = x.superview, d++) {
        const char *n = class_getName(object_getClass(x));
        if (DSContains(n, "SectionHeader") || DSContains(n, "HeaderFooter") || DSHasPrefix(n, "UITableViewHeaderView")) {
            return YES;
        }
    }
    return NO;
}

// Settings: the captions above and below grouped tables ("Choose a Network...", footnotes) are drawn in iOS's
// slate gray-blue with a white shadow. Spot them by that color (rows and values use other colors).
static BOOL DSIsCaptionColor(UIColor *c) {
    if (c == nil || c.CGColor == NULL) return NO;
    CGColorRef cg = c.CGColor;
    if (CGColorSpaceGetModel(CGColorGetColorSpace(cg)) != kCGColorSpaceModelRGB || CGColorGetNumberOfComponents(cg) != 4) return NO;
    const CGFloat *p = CGColorGetComponents(cg);
    return p[3] > 0.5 && fabs(p[0] - 0.30) < 0.07 && fabs(p[1] - 0.34) < 0.07 && fabs(p[2] - 0.42) < 0.07;
}

static BOOL DSIsTableCaption(UIView *v) {
    if (![v isKindOfClass:[UILabel class]]) return NO;
    UILabel *l = (UILabel *)v;
    if (DSIsCaptionColor(l.textColor)) return YES;
    UIView *sp = v.superview;
    return sp != nil && [sp isKindOfClass:[UITableView class]] && ((UITableView *)sp).style == UITableViewStyleGrouped;
}

// Music tab bar icons: gray picture with a dark gray shadow underneath (made from the icon's shape)
static NSMutableDictionary *dsTabCache = nil;
static NSMutableArray *dsTabDone = nil;
static BOOL dsTabBusy = NO;
static NSMutableDictionary *dsTabRev = nil;

static UIImage *DSTabColored(UIImage *mask, CGFloat gray) {
    CGSize sz = mask.size;
    UIGraphicsBeginImageContextWithOptions(sz, NO, mask.scale);
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGRect r = CGRectMake(0, 0, sz.width, sz.height);
    [mask drawInRect:r];
    CGContextSetBlendMode(c, kCGBlendModeSourceIn);
    CGContextSetGrayFillColor(c, gray, 1.0);
    CGContextFillRect(c, r);
    UIImage *o = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return o;
}

static UIImage *DSTabIcon(UIImage *mask, CGFloat gray) {
    if (mask == nil || mask.CGImage == NULL) return mask;
    if (dsTabCache == nil) {
        dsTabCache = [[NSMutableDictionary alloc] init];
    }
    NSString *key = [NSString stringWithFormat:@"%p-%d", mask, (int)(gray * 100)];
    NSArray *e = [dsTabCache objectForKey:key];
    if (e == nil) {
        BOOL prev = dsInHook;
        dsInHook = YES;
        UIImage *main = DSTabColored(mask, gray);
        UIImage *shade = DSTabColored(mask, 0.3);
        CGSize sz = mask.size;
        UIGraphicsBeginImageContextWithOptions(sz, NO, mask.scale);
        [shade drawInRect:CGRectMake(0, 1, sz.width, sz.height)];
        [main drawInRect:CGRectMake(0, 0, sz.width, sz.height)];
        UIImage *o = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        dsInHook = prev;
        e = [NSArray arrayWithObjects:mask, (o != nil ? o : mask), nil];
        [dsTabCache setObject:e forKey:key];
        if (o != nil) {
            if (dsTabRev == nil) {
                dsTabRev = [[NSMutableDictionary alloc] init];
            }
            [dsTabRev setObject:mask forKey:[NSValue valueWithPointer:(const void *)o]];
        }
    }
    return (UIImage *)[e objectAtIndex:1];
}

// any picture shown in a tab button -> gray with shade (selected tab a little lighter)
static UIImage *DSTabImageFor(UIImageView *iv, UIImage *img) {
    if (img == nil) return img;
    UIImage *mask = [dsTabRev objectForKey:[NSValue valueWithPointer:(const void *)img]];
    if (mask == nil) mask = img;
    CGFloat g = 0.62;
    for (UIView *sib in iv.superview.subviews) {
        if (DSContains(class_getName(object_getClass(sib)), "SelectionIndicator")) {
            g = 0.88;
        }
    }
    return DSTabIcon(mask, g);
}

static void DSFixTabItem(UITabBarItem *item) {
    if (item == nil || dsTabBusy) return;
    if (![item respondsToSelector:@selector(setFinishedSelectedImage:withFinishedUnselectedImage:)]) return;
    UIImage *mask = item.image;
    if (mask == nil) return;
    if (dsTabDone == nil) {
        dsTabDone = [[NSMutableArray alloc] init];
    }
    if ([dsTabDone indexOfObjectIdenticalTo:item] != NSNotFound) return;
    [dsTabDone addObject:item];
    dsTabBusy = YES;
    UIImage *un = DSTabIcon(mask, 0.62);
    UIImage *sel = DSTabIcon(mask, 0.88);
    [item setFinishedSelectedImage:sel withFinishedUnselectedImage:un];
    dsTabBusy = NO;
}

// Messages: the date stamp above a conversation and the "Delivered" / "Read" line
static BOOL dsStyling = NO;
static BOOL DSIsStatusLabel(UILabel *l) {
    if (!dsIsMessages || dsStyling) return NO;
    NSString *t = l.text;
    if (t == nil || [t length] < 4 || [t length] > 48) return NO;
    BOOL hit = [t isEqualToString:@"Delivered"] || [t hasPrefix:@"Read"] ||
               [t rangeOfString:@" AM"].location != NSNotFound || [t rangeOfString:@" PM"].location != NSNotFound;
    if (!hit) return NO;
    int d = 0;
    for (UIView *x = l; x != nil && d < 6; x = x.superview, d++) {
        const char *n = class_getName(object_getClass(x));
        if (DSContains(n, "Balloon") || DSContains(n, "Bubble") || [x isKindOfClass:[UITextField class]]) {
            return NO;
        }
    }
    return YES;
}


static void DSStyleStatusLabel(UILabel *l) {
    if (dsStyling) return;           // setting these makes UIKit call back into us: never nest
    dsStyling = YES;
    BOOL prev = dsBypass;
    dsBypass = YES;
    l.textColor = [UIColor colorWithWhite:0.96 alpha:1.0];
    l.shadowColor = [UIColor colorWithWhite:0.25 alpha:1.0];
    l.shadowOffset = CGSizeMake(0, 1);
    dsBypass = prev;
    dsStyling = NO;
}

// Messages: find the date stamps / "Delivered" lines in the visible screen and style them.
// Done from the outside (never from inside a UILabel setter), so it cannot loop.
static void DSStyleStatusTree(UIView *v, int depth) {
    if (v == nil || depth > 14) return;
    if ([v isKindOfClass:[UILabel class]]) {
        if (DSIsStatusLabel((UILabel *)v)) {
            DSStyleStatusLabel((UILabel *)v);
        }
        return;
    }
    NSArray *kids = [NSArray arrayWithArray:v.subviews];
    for (UIView *k in kids) {
        DSStyleStatusTree(k, depth + 1);
    }
}

static void DSStyleStatusWindow(void) {
    UIWindow *w = [[UIApplication sharedApplication] keyWindow];
    if (w != nil) {
        DSStyleStatusTree(w, 0);
    }
}

static UIColor *DSMusicShadow(void) {
    return [UIColor colorWithWhite:0.3 alpha:1.0];
}

static NSMutableDictionary *dsDrawnCache = nil;

// glyph pictures that are drawn straight into a context (e.g. the Shuffle arrows)
static CGImageRef DSMusicDrawnGlyph(CGImageRef src) {
    if (src == NULL) return NULL;
    size_t w = CGImageGetWidth(src);
    size_t h = CGImageGetHeight(src);
    if (w == 0 || h == 0 || w > 90 || h > 90) return NULL;
    if (dsDrawnCache == nil) {
        dsDrawnCache = [[NSMutableDictionary alloc] init];
    }
    NSValue *key = [NSValue valueWithPointer:src];
    NSArray *e = [dsDrawnCache objectForKey:key];
    if (e == nil) {
        UIImage *holder = [UIImage imageWithCGImage:src];      // keeps src alive so the key stays valid
        CGImageRef out = DSLightGlyphCGImageCreate(src);
        id res = [NSNull null];
        if (out != NULL) {
            res = [UIImage imageWithCGImage:out];
            CGImageRelease(out);
        }
        e = [NSArray arrayWithObjects:holder, res, nil];
        [dsDrawnCache setObject:e forKey:key];
    }
    id r = [e objectAtIndex:1];
    if (r == [NSNull null]) return NULL;
    return ((UIImage *)r).CGImage;
}

// Diagnostics go to a few places, because a few apps cannot write to their own Caches folder.
// File names carry the app name, so Videos, Calendar and Photos do not mix.
static void DSWriteDiag(NSString *fname, NSString *text, BOOL append) {
    if (!DSDebugOn()) return;
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    NSString *name = [NSString stringWithFormat:@"%@-%@", (bid != nil ? bid : @"app"), fname];
    NSMutableArray *dirs = [NSMutableArray array];
    NSArray *cd = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    if ([cd count] > 0) [dirs addObject:[cd objectAtIndex:0]];
    [dirs addObject:@"/var/mobile/Library/Caches"];
    [dirs addObject:@"/var/mobile"];
    [dirs addObject:@"/var/tmp"];
    for (NSString *dir in dirs) {
        NSString *path = [dir stringByAppendingPathComponent:name];
        NSString *out = text;
        if (append) {
            NSString *old = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
            if (old != nil) out = [old stringByAppendingString:text];
        }
        [out writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    }
}

static void DSDumpNamed(NSString *fname) {
    if (!DSDebugOn()) return;
    UIWindow *w = [[UIApplication sharedApplication] keyWindow];
    if (w == nil || ![w respondsToSelector:@selector(recursiveDescription)]) return;
    NSString *d = [w performSelector:@selector(recursiveDescription)];
    if (d == nil) return;
    DSWriteDiag(fname, [NSString stringWithFormat:@"\n\n===== %@ =====\n%@", [NSDate date], d], YES);
}

static void DSDumpMusic(void) {
    DSDumpNamed(@"DarkSix-music.txt");
}

static void DSDumpChat(void) {
    DSDumpNamed(@"DarkSix-chat.txt");
}

// Music: light silver nav buttons -> dark (already-dark ones, like Now Playing, stay);
// small dark glyphs in table rows -> white.
static UIImage *DSMusicImage(UIImageView *iv, UIImage *img) {
    if (img == nil || DSAvoid(iv)) return img;
    if (DSContains(class_getName(object_getClass(iv)), "TabBarSwappable")) {
        return DSTabImageFor(iv, img);
    }
    if (DSIsNavButtonChild(iv)) {
        return DSDarkBarImage(img);
    }
    UIView *p = iv.superview;
    int d = 0;
    while (p != nil && d < 6) {
        if ([p isKindOfClass:[UITableViewCell class]] || [p isKindOfClass:[UITableView class]]) {
            return DSLightGlyphImage(img);
        }
        p = p.superview;
        d++;
    }
    return img;
}

// ---------- Messages: chat bubbles ----------

static BOOL dsInBalloonDraw = NO;     // true while a chat balloon view is drawing itself
static CGImageRef DSDarkCGImageCreate(CGImageRef src, CGFloat alpha);

static BOOL DSViewInBalloon(UIView *v) {
    BOOL hit = NO;
    int d = 0;
    for (UIView *x = v; x != nil && d < 6; x = x.superview, d++) {
        const char *n = class_getName(object_getClass(x));
        if (DSContains(n, "Entry") || DSContains(n, "Compose")) return NO;
        if ([x isKindOfClass:[UITextView class]] && ((UITextView *)x).editable) return NO;
        if (DSContains(n, "Balloon")) hit = YES;
    }
    return hit;
}

// photo / GIF / video / audio / attachment balloons: their pictures are content, never recolored
static BOOL dsInMediaDraw = NO;

static BOOL DSNameIsMedia(const char *n) {
    return DSContains(n, "ImageBalloon") || DSContains(n, "MovieBalloon") || DSContains(n, "MediaBalloon") ||
           DSContains(n, "VideoBalloon") || DSContains(n, "PhotoBalloon") || DSContains(n, "AnimatedImage") ||
           DSContains(n, "GIF") || DSContains(n, "Gif") || DSContains(n, "Attachment") || DSContains(n, "Thumbnail") ||
           DSContains(n, "Movie") || DSContains(n, "Video") || DSContains(n, "MediaObject") || DSContains(n, "AudioBalloon");
}

static BOOL DSViewInMedia(UIView *v) {
    int d = 0;
    for (UIView *x = v; x != nil && d < 8; x = x.superview, d++) {
        if (DSNameIsMedia(class_getName(object_getClass(x)))) return YES;
    }
    return NO;
}

static BOOL DSLayerInBalloon(CALayer *l) {
    id dg = l.delegate;
    if (dg != nil && [dg isKindOfClass:[UIView class]]) {
        if (DSViewInMedia((UIView *)dg)) return NO;
        return DSViewInBalloon((UIView *)dg);
    }
    return NO;
}

static BOOL DSTextIsDark(UIColor *c) {
    if (c == nil) return YES;
    CGColorRef cg = c.CGColor;
    size_t n = CGColorGetNumberOfComponents(cg);
    const CGFloat *p = CGColorGetComponents(cg);
    if (p == NULL) return NO;
    CGFloat lum = (n >= 3) ? (0.299 * p[0] + 0.587 * p[1] + 0.114 * p[2]) : p[0];
    return lum < 0.5;
}

static void DSBubbleLog(NSString *line) {
    static int count = 0;
    if (count > 60) return;
    count++;
    DSWriteDiag(@"DarkSix-chat.txt", line, YES);
}

// per-pixel recolor of a chat bubble keeps its gloss and widens it (kind 1 received, 2 sent blue); +1 retained
static CGImageRef DSBubbleRemap(CGImageRef src, int kind) {
    size_t w = CGImageGetWidth(src), h = CGImageGetHeight(src);
    if (w == 0 || h == 0 || w > 1024 || h > 1024) return NULL;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef bc = CGBitmapContextCreate(NULL, w, h, 8, w * 4, cs, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (bc == NULL) return NULL;
    BOOL prev = dsInHook;
    dsInHook = YES;
    CGContextDrawImage(bc, CGRectMake(0, 0, w, h), src);
    dsInHook = prev;
    unsigned char *px = (unsigned char *)CGBitmapContextGetData(bc);
    if (px == NULL) {
        CGContextRelease(bc);
        return NULL;
    }
    size_t rowBytes = CGBitmapContextGetBytesPerRow(bc);
    for (size_t y = 0; y < h; y++) {
        unsigned char *row = px + y * rowBytes;
        for (size_t x = 0; x < w; x++) {
            unsigned char *q = row + x * 4;
            CGFloat a = q[3] / 255.0;
            if (a <= 0.004) continue;
            CGFloat r = q[0] / 255.0 / a, g = q[1] / 255.0 / a, b = q[2] / 255.0 / a;
            CGFloat l = 0.299 * r + 0.587 * g + 0.114 * b;
            CGFloat nr, ng, nb;
            if (kind == 1) {
                CGFloat v = 0.20 + (l - 0.88) * 2.4;       // light gray body -> dark gray, gloss stays brighter
                if (v < 0.05) v = 0.05;
                if (v > 0.55) v = 0.55;
                nr = ng = nb = v;
            } else {
                CGFloat f = 0.62 + (l - 0.52) * 1.9;      // blue body -> deep blue, gloss stays brighter
                if (f < 0.25) f = 0.25;
                if (f > 1.6) f = 1.6;
                nr = 0.14 * f; ng = 0.31 * f; nb = 0.86 * f;      // the Send button's blue
                if (nr > 1) nr = 1;
                if (ng > 1) ng = 1;
                if (nb > 1) nb = 1;
            }
            q[0] = (unsigned char)(nr * a * 255.0 + 0.5);
            q[1] = (unsigned char)(ng * a * 255.0 + 0.5);
            q[2] = (unsigned char)(nb * a * 255.0 + 0.5);
        }
    }
    CGImageRef out = CGBitmapContextCreateImage(bc);
    CGContextRelease(bc);
    return out;
}

static NSMutableDictionary *dsBubbleCache = nil;

// returns a darker copy of a chat bubble picture (not retained), or NULL when it is not a bubble
static CGImageRef DSBubbleImage(CGImageRef src) {
    if (src == NULL || dsInHook || dsInMediaDraw) return NULL;
    size_t w = CGImageGetWidth(src), h = CGImageGetHeight(src);
    if (w < 8 || h < 8 || w > 220 || h > 220) return NULL;      // chat bubble pictures are small; photos are bigger
    if (dsBubbleCache == nil) {
        dsBubbleCache = [[NSMutableDictionary alloc] init];
    }
    if ([dsBubbleCache count] > 300) {
        [dsBubbleCache removeAllObjects];
    }
    NSString *key = [NSString stringWithFormat:@"%p", src];
    NSArray *e = [dsBubbleCache objectForKey:key];
    if (e == nil) {
        CGImageRef out = NULL;
        int kind = 0;
        CGFloat mr = 0, mg = 0, mb = 0, lv = 0;
        enum { N = 12 };
        unsigned char px[N * N * 4];
        memset(px, 0, sizeof(px));
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef bc = CGBitmapContextCreate(px, N, N, 8, N * 4, cs, kCGImageAlphaPremultipliedLast);
        CGColorSpaceRelease(cs);
        if (bc != NULL) {
            dsInHook = YES;
            CGContextDrawImage(bc, CGRectMake(0, 0, N, N), src);
            dsInHook = NO;
            CGContextRelease(bc);
            int cnt = 0;
            CGFloat sl = 0, sl2 = 0;
            for (int i = 0; i < N * N; i++) {
                CGFloat a = px[i * 4 + 3];
                if (a < 230) continue;
                CGFloat r = px[i * 4] / a, g = px[i * 4 + 1] / a, b = px[i * 4 + 2] / a;
                CGFloat l = 0.299 * r + 0.587 * g + 0.114 * b;
                mr += r; mg += g; mb += b; sl += l; sl2 += l * l;
                cnt++;
            }
            if (cnt >= N * N * 0.3) {
                mr /= cnt; mg /= cnt; mb /= cnt;
                CGFloat lum = sl / cnt;
                lv = sl2 / cnt - lum * lum;
                CGFloat mx = MAX(mr, MAX(mg, mb)), mn = MIN(mr, MIN(mg, mb));
                CGFloat sat = (mx > 0) ? (mx - mn) / mx : 0;
                if (lv < 0.04 && lum > 0.6 && sat < 0.15) {
                    kind = 1;
                } else if (lv < 0.12 && mb > mr + 0.15 && mb > 0.5 && sat > 0.2 && mb >= mg) {
                    kind = 2;                 // sent iMessage blue (has a strong gloss, so allow more variation)
                }
            }
        }
        if (kind == 1 || kind == 2) {
            out = DSBubbleRemap(src, kind);
        }
        DSBubbleLog([NSString stringWithFormat:@"image %lux%lu kind %d rgb %.2f %.2f %.2f var %.3f balloonDraw %d\n", (unsigned long)w, (unsigned long)h, kind, mr, mg, mb, lv, (int)dsInBalloonDraw]);
        id second = (out != NULL) ? (id)out : (id)[NSNull null];
        e = [NSArray arrayWithObjects:(id)src, second, nil];
        [dsBubbleCache setObject:e forKey:key];
        if (out != NULL) CGImageRelease(out);
    }
    id r2 = [e objectAtIndex:1];
    return (r2 == [NSNull null]) ? NULL : (CGImageRef)r2;
}

// the balloon classes draw themselves: note when that happens so their pictures get recolored
static NSMutableDictionary *dsBalOrig = nil;

static void DSBalloonDraw(id self, SEL _cmd, CGRect rect) {
    IMP orig = NULL;
    for (Class k = object_getClass(self); k != Nil && orig == NULL; k = class_getSuperclass(k)) {
        NSValue *v = [dsBalOrig objectForKey:[NSValue valueWithPointer:(const void *)k]];
        if (v != nil) {
            orig = (IMP)[v pointerValue];
        }
    }
    BOOL prev = dsInBalloonDraw;
    BOOL prevMedia = dsInMediaDraw;
    dsInBalloonDraw = YES;
    dsInMediaDraw = DSNameIsMedia(class_getName(object_getClass(self))) || ([self isKindOfClass:[UIView class]] && DSViewInMedia((UIView *)self));
    if (orig != NULL) {
        ((void (*)(id, SEL, CGRect))orig)(self, _cmd, rect);
    }
    dsInMediaDraw = prevMedia;
    dsInBalloonDraw = prev;
}

static void DSInstallBalloonHooks(void) {
    if (dsBalOrig == nil) {
        dsBalOrig = [[NSMutableDictionary alloc] init];
    }
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    NSMutableData *buf = [NSMutableData dataWithLength:sizeof(Class) * count];
    Class *list = (Class *)[buf mutableBytes];
    count = objc_getClassList(list, count);
    Class uiview = [UIView class];
    for (int i = 0; i < count; i++) {
        Class k = list[i];
        const char *n = class_getName(k);
        if (!DSContains(n, "Balloon") || DSContains(n, "Entry")) continue;
        BOOL isView = NO;
        for (Class s2 = k; s2 != Nil; s2 = class_getSuperclass(s2)) {
            if (s2 == uiview) {
                isView = YES;
                break;
            }
        }
        if (!isView) continue;
        NSValue *key = [NSValue valueWithPointer:(const void *)k];
        if ([dsBalOrig objectForKey:key] != nil) continue;
        unsigned int mc = 0;
        Method *ms = class_copyMethodList(k, &mc);
        Method own = NULL;
        for (unsigned int j = 0; j < mc; j++) {
            if (method_getName(ms[j]) == @selector(drawRect:)) {
                own = ms[j];
                break;
            }
        }
        DSBubbleLog([NSString stringWithFormat:@"balloon class %s ownDrawRect %d\n", n, own != NULL]);
        if (own != NULL) {
            [dsBalOrig setObject:[NSValue valueWithPointer:(const void *)method_getImplementation(own)] forKey:key];
            method_setImplementation(own, (IMP)DSBalloonDraw);
        }
        if (ms != NULL) {
            free(ms);
        }
    }
}

// ---------- keyboard: black background, dark gray keys, white text ----------

static BOOL dsInKeyboardDraw = NO;    // true while a keyboard view is drawing itself
static BOOL dsKbEmoji = NO;           // the picture being looked at belongs to the emoji keyboard

static BOOL DSViewInKeyboard(UIView *v) {
    int d = 0;
    for (UIView *x = v; x != nil && d < 10; x = x.superview, d++) {
        const char *n = class_getName(object_getClass(x));
        if (DSHasPrefix(n, "UIKB") || DSHasPrefix(n, "UIKeyboard")) return YES;
    }
    return NO;
}

static BOOL DSViewInEmoji(UIView *v) {
    int d = 0;
    for (UIView *x = v; x != nil && d < 10; x = x.superview, d++) {
        if (DSContains(class_getName(object_getClass(x)), "Emoji")) return YES;
    }
    return NO;
}

static BOOL DSLayerInKeyboard(CALayer *l) {
    dsKbEmoji = NO;
    int d = 0;
    for (CALayer *x = l; x != nil && d < 10; x = x.superlayer, d++) {
        id dg = x.delegate;
        if (dg != nil && [dg isKindOfClass:[UIView class]]) {
            dsKbEmoji = DSViewInEmoji((UIView *)dg);
            return DSViewInKeyboard((UIView *)dg);
        }
    }
    return NO;
}

static void DSKbLog(NSString *line) {
    static int count = 0;
    if (count > 400) return;
    count++;
    DSWriteDiag(@"DarkSix-kb.txt", line, YES);
}

static CGFloat DSKbMap(CGFloat l) {
    if (l <= 0.30) return l * 0.10;                       // keyboard background -> black
    return 0.05 + (l - 0.30) / 0.70 * 0.27;               // key surface -> dark gray, top a little lighter than the bottom
}

static NSMutableDictionary *dsKbCache = nil;
static NSMutableSet *dsKbOutSet = nil;        // pictures DarkSix made itself (never recolored a second time)
static NSMutableArray *dsKbOutKeep = nil;     // keeps them alive so their addresses are never reused

// returns a dark copy of a keyboard picture (not retained), or NULL to leave it alone
static CGImageRef DSKeyboardImage(CGImageRef src) {
    if (src == NULL || dsInHook || !dsOptKeyboard) return NULL;
    if (dsKbOutSet != nil && [dsKbOutSet containsObject:[NSValue valueWithPointer:src]]) return NULL;
    size_t w = CGImageGetWidth(src), h = CGImageGetHeight(src);
    if (w < 6 || h < 6 || w > 2600 || h > 2600 || w * h > 3000000) return NULL;
    if (dsKbCache == nil) {
        dsKbCache = [[NSMutableDictionary alloc] init];
    }
    if ([dsKbCache count] > 120) {
        [dsKbCache removeAllObjects];
    }
    NSString *key = [NSString stringWithFormat:@"%p", src];
    NSArray *e = [dsKbCache objectForKey:key];
    if (e == nil) {
        CGImageRef out = NULL;
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef bc = CGBitmapContextCreate(NULL, w, h, 8, w * 4, cs, kCGImageAlphaPremultipliedLast);
        CGColorSpaceRelease(cs);
        if (bc != NULL) {
            dsInHook = YES;
            CGContextDrawImage(bc, CGRectMake(0, 0, w, h), src);
            dsInHook = NO;
            unsigned char *px = (unsigned char *)CGBitmapContextGetData(bc);
            size_t rb = CGBitmapContextGetBytesPerRow(bc);
            if (px != NULL) {
                // first pass: is this a dark keyboard picture at all? (a light keyboard is left alone)
                double sum = 0;
                long cnt = 0, colorful = 0;
                int hist[10] = {0};
                for (size_t y = 0; y < h; y += 2) {
                    unsigned char *row = px + y * rb;
                    for (size_t x = 0; x < w; x += 2) {
                        unsigned char *q = row + x * 4;
                        if (q[3] < 200) continue;
                        CGFloat a = q[3] / 255.0;
                        CGFloat l = (0.299 * q[0] + 0.587 * q[1] + 0.114 * q[2]) / 255.0 / a;
                        sum += l;
                        cnt++;
                        {
                            int mxc = MAX(q[0], MAX(q[1], q[2])), mnc = MIN(q[0], MIN(q[1], q[2]));
                            if (mxc > 40 && (mxc - mnc) > 0.22 * mxc) colorful++;
                        }
                        int bin = (int)(l * 10);
                        if (bin > 9) bin = 9;
                        if (bin < 0) bin = 0;
                        hist[bin]++;
                    }
                }
                double mean = (cnt > 0) ? sum / cnt : 1.0;
                DSKbLog([NSString stringWithFormat:@"image %lux%lu opaque %ld mean %.2f hist %d %d %d %d %d %d %d %d %d %d drawing %d\n",
                    (unsigned long)w, (unsigned long)h, cnt, mean, hist[0], hist[1], hist[2], hist[3], hist[4], hist[5], hist[6], hist[7], hist[8], hist[9], (int)dsInKeyboardDraw]);
                // emoji are small colorful pictures: never recolored (keys, the Go key etc. are bigger or gray)
                // (gray ones like the skull too: emoji pictures are small and nearly square, keys are 84-90 tall)
                long dwh = (long)w - (long)h;
                BOOL squareish = (dsKbEmoji && w >= 40 && h >= 40 && w <= 140 && h <= 140 && dwh >= -8 && dwh <= 8);     // only inside the emoji keyboard (symbol key legends are the same size)
                BOOL emojiLike = (cnt > 20 && (squareish || (colorful * 100 > cnt * 6 && (dsKbEmoji || (w <= 110 && h <= 110)))));
                // light, key-sized pictures (84-90 tall) are keys that were left white: they get the same dark treatment
                BOOL lightKey = NO;      // (experiment removed: light keys stay as the app draws them)      // the wide space bar (300+) is left alone
                // light key legends ($ . , ? ! ' and the currency signs): dark symbol with a white emboss, drawn on a key
                BOOL legendLight = (!emojiLike && w >= 28 && h >= 28 && w <= 72 && h <= 72 && mean >= 0.62 && colorful * 100 <= cnt * 6);
                DSKbLog([NSString stringWithFormat:@"   decision %lux%lu lightKey %d emojiLike %d squareish %d colorful %ld -> %@\n", (unsigned long)w, (unsigned long)h, (int)lightKey, (int)emojiLike, (int)squareish, colorful, ((cnt > 20 && (mean < 0.62 || lightKey || legendLight) && !emojiLike) ? @"recolor" : @"leave")]);
                // key faces (60-160 wide, 80-92 tall; not the 300+ wide space bar / return) are painted flat dark gray, keeping
                // the picture's own outline/shadow; light symbol legends become white glyphs
                // the white key faces found with the debug colors: $ and the three currency keys (60x90, mean .87),
                // and the punctuation keys (86x90 and 88x90). Letter keys, space, return, delete, 123/ABC and the globe are other pictures.
                BOOL faceKey = (h == 90 && mean >= 0.62 && ((w == 60 && mean > 0.855 && mean < 0.885) || w == 86 || w == 88));
                BOOL direct = (cnt > 20 && !emojiLike && faceKey);
                // DEBUG: when /var/mobile/Library/Caches/DarkSix-kbdebug exists, every key-sized or glyph-sized picture is painted a
                // different solid color (alpha kept) and the color/size pairs are logged, so each picture can be matched to a key
                static int dbgState = -1;
                if (dbgState < 0) {
                    dbgState = [[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/Library/Caches/DarkSix-kbdebug"] ? 1 : 0;
                }
                if (dbgState == 1 && !emojiLike && cnt > 20) {      // every keyboard picture, the big full-keyboard sheets too
                    static int dbgIdx = 0;
                    static const char *names[] = {"red", "green", "blue", "yellow", "magenta", "cyan", "orange", "purple", "white", "gray"};
                    static const unsigned char cols[10][3] = {{255,0,0},{0,255,0},{0,0,255},{255,255,0},{255,0,255},{0,255,255},{255,140,0},{140,0,200},{255,255,255},{128,128,128}};
                    int ci = dbgIdx % 10;
                    dbgIdx++;
                    for (size_t y = 0; y < h; y++) {
                        unsigned char *row = px + y * rb;
                        for (size_t x = 0; x < w; x++) {
                            unsigned char *q = row + x * 4;
                            if (q[3] == 0) continue;
                            q[0] = (unsigned char)(cols[ci][0] * q[3] / 255);
                            q[1] = (unsigned char)(cols[ci][1] * q[3] / 255);
                            q[2] = (unsigned char)(cols[ci][2] * q[3] / 255);
                        }
                    }
                    out = CGBitmapContextCreateImage(bc);
                    DSKbLog([NSString stringWithFormat:@"   DEBUG picture #%d %lux%lu mean %.2f painted %s\n", dbgIdx, (unsigned long)w, (unsigned long)h, mean, names[ci]]);
                    direct = YES;
                }
                if (!dbgState && direct) {   // flat dark gray key face
                    for (size_t y = 0; y < h; y++) {
                        unsigned char *row = px + y * rb;
                        for (size_t x = 0; x < w; x++) {
                            unsigned char *q = row + x * 4;
                            if (q[3] == 0) continue;
                            CGFloat a = q[3] / 255.0;
                            CGFloat l = (0.299 * q[0] + 0.587 * q[1] + 0.114 * q[2]) / 255.0 / a;
                            if (l > 1) l = 1;
                            if (faceKey) {
                                CGFloat yy = ((CGFloat)y - 4.0) / 82.0;
                                if (yy < 0) yy = 0;
                                if (yy > 1) yy = 1;
                                CGFloat g = 0.27 - 0.08 * yy;                               // the same gray as the keys in the full keyboard picture
                                CGFloat v = (l < 0.25) ? 0.04 : g;
                                unsigned char c = (unsigned char)(v * a * 255.0 + 0.5);
                                q[0] = c; q[1] = c; q[2] = c;
                            } else {
                                CGFloat t = (0.72 - l) / 0.42;                                  // dark symbol -> white, its white halo -> see-through
                                if (t < 0) t = 0;
                                if (t > 1) t = 1;
                                t = t * t * (3.0 - 2.0 * t);
                                unsigned char c = (unsigned char)(t * a * 255.0 + 0.5);
                                q[0] = c; q[1] = c; q[2] = c; q[3] = c;
                            }
                        }
                    }
                    out = CGBitmapContextCreateImage(bc);
                }
                unsigned char *tg = NULL;      // light legends: how dark (glyph-like) each pixel is, so small symbols still come out white
                if (!direct && legendLight && cnt > 20 && !emojiLike) {
                    tg = (unsigned char *)calloc(w * h, 1);
                    if (tg != NULL) {
                        for (size_t y = 0; y < h; y++) {
                            unsigned char *row = px + y * rb;
                            for (size_t x = 0; x < w; x++) {
                                unsigned char *q = row + x * 4;
                                if (q[3] == 0) continue;
                                CGFloat a = q[3] / 255.0;
                                CGFloat l = (0.299 * q[0] + 0.587 * q[1] + 0.114 * q[2]) / 255.0 / a;
                                CGFloat t = (0.60 - l) / 0.35;
                                if (t < 0) t = 0;
                                if (t > 1) t = 1;
                                tg[y * w + x] = (unsigned char)(t * t * (3.0 - 2.0 * t) * 255.0);
                            }
                        }
                    }
                }
                // the full keyboard picture (letters, numbers, symbols): black background, gray keys, white legends (kb_core.c)
                BOOL sheetNew = (w >= 400 && h >= 300 && cnt > 20 && !dsKbEmoji && dbgState != 1);
                if (sheetNew) {
                    if (ds_kb_sheet(px, (int)w, (int)h, (int)rb)) {
                        out = CGBitmapContextCreateImage(bc);
                    }
                }
                if (!direct && !sheetNew && cnt > 20 && (mean < 0.62 || legendLight) && !emojiLike) {
                    size_t n = w * h;
                    unsigned char *lb = (unsigned char *)malloc(n);
                    unsigned char *tx = (unsigned char *)calloc(n, 1);      // 255 = letter core, 1..254 = soft edge of a letter
                    unsigned char *sd = (unsigned char *)calloc(n, 1);      // 1 = shadow under a letter
                    if (lb != NULL && tx != NULL && sd != NULL) {
                        for (size_t y = 0; y < h; y++) {
                            unsigned char *row = px + y * rb;
                            for (size_t x = 0; x < w; x++) {
                                unsigned char *q = row + x * 4;
                                if (q[3] == 0) {
                                    lb[y * w + x] = 0;
                                    continue;
                                }
                                CGFloat a = q[3] / 255.0;
                                CGFloat l = (0.299 * q[0] + 0.587 * q[1] + 0.114 * q[2]) / 255.0 / a;
                                if (l > 1) l = 1;
                                lb[y * w + x] = (unsigned char)(l * 255.0 + 0.5);
                            }
                        }
                        // letters: small, closed-off blobs of dark pixels (the key outline and the gaps between
                        // keys are all one big connected dark area, so they are never picked up)
                        unsigned char *vis = (unsigned char *)calloc(n, 1);
                        int *stk = (int *)malloc(sizeof(int) * n);
                        if (vis != NULL && stk != NULL) {
                            for (size_t start = 0; start < n; start++) {
                                if (vis[start] || lb[start] >= 56) continue;
                                size_t top = 0, cntp = 0, head = 0;
                                long minx = (long)w, maxx = -1, miny = (long)h, maxy = -1;
                                BOOL touch = NO;
                                stk[top++] = (int)start;
                                vis[start] = 1;
                                // the stack doubles as the list of members (we append, never pop)
                                while (head < top) {
                                    int cur = stk[head++];
                                    long cx = cur % (long)w, cy = cur / (long)w;
                                    cntp++;
                                    if (cx < minx) minx = cx;
                                    if (cx > maxx) maxx = cx;
                                    if (cy < miny) miny = cy;
                                    if (cy > maxy) maxy = cy;
                                    if (cx == 0 || cy == 0 || cx == (long)w - 1 || cy == (long)h - 1) touch = YES;
                                    for (int dir = 0; dir < 4; dir++) {
                                        long nx = cx + ((dir == 0) ? -1 : ((dir == 1) ? 1 : 0));
                                        long ny = cy + ((dir == 2) ? -1 : ((dir == 3) ? 1 : 0));
                                        if (nx < 0 || ny < 0 || nx >= (long)w || ny >= (long)h) continue;
                                        size_t ni = (size_t)ny * w + (size_t)nx;
                                        if (vis[ni] || lb[ni] >= 56) continue;
                                        vis[ni] = 1;
                                        stk[top++] = (int)ni;
                                    }
                                }
                                BOOL wideThin = ((maxx - minx + 1) > 2.2 * (maxy - miny + 1)) && (maxx - minx) > 20;
                                if (!touch && !wideThin && cntp >= 6 && cntp <= 5000 && (maxx - minx) < 90 && (maxy - miny) < 90) {
                                    for (size_t m = 0; m < top; m++) {
                                        tx[stk[m]] = 255;
                                    }
                                }
                            }
                        }
                        if (vis != NULL && stk != NULL) {
                            memset(vis, 0, n);
                            for (size_t start = 0; start < n; start++) {
                                if (vis[start] || lb[start] < 170) continue;
                                size_t top = 0, head = 0;
                                long minx = (long)w, maxx = -1, miny = (long)h, maxy = -1;
                                stk[top++] = (int)start;
                                vis[start] = 1;
                                while (head < top) {
                                    int cur = stk[head++];
                                    long cx = cur % (long)w, cy = cur / (long)w;
                                    if (cx < minx) minx = cx;
                                    if (cx > maxx) maxx = cx;
                                    if (cy < miny) miny = cy;
                                    if (cy > maxy) maxy = cy;
                                    for (int dir = 0; dir < 4; dir++) {
                                        long nx = cx + ((dir == 0) ? -1 : ((dir == 1) ? 1 : 0));
                                        long ny = cy + ((dir == 2) ? -1 : ((dir == 3) ? 1 : 0));
                                        if (nx < 0 || ny < 0 || nx >= (long)w || ny >= (long)h) continue;
                                        size_t ni = (size_t)ny * w + (size_t)nx;
                                        if (vis[ni] || lb[ni] < 170) continue;
                                        vis[ni] = 1;
                                        stk[top++] = (int)ni;
                                    }
                                }
                                // a thin, wide bright sliver is the highlight line under a key: make it black
                                if ((maxy - miny) <= 7 && (maxx - minx) >= 16 && (maxx - minx + 1) >= 3 * (maxy - miny + 1)) {
                                    for (size_t m = 0; m < top; m++) {
                                        sd[stk[m]] = 2;
                                    }
                                }
                            }
                        }
                        if (vis != NULL) free(vis);
                        if (stk != NULL) free(stk);
                        // smooth letter edges: how much of each pixel near a letter is letter (0..1), judged from
                        // how far it sits between the letter's black and the lightest key surface around it
                        for (size_t y = 4; y + 5 < h; y++) {
                            for (size_t x = 4; x + 4 < w; x++) {
                                size_t i = y * w + x;
                                if (tx[i] == 255) continue;
                                BOOL nearGlyph = NO;
                                for (int oy = -3; oy <= 3 && !nearGlyph; oy++) {
                                    for (int ox = -3; ox <= 3; ox++) {
                                        if (tx[(y + oy) * w + (x + ox)] == 255) {
                                            nearGlyph = YES;
                                            break;
                                        }
                                    }
                                }
                                if (nearGlyph) {
                                    int sMax = 0;
                                    // the full keyboard picture: white highlights and white faces count as ordinary key surface (no white halos)
                                    BOOL sheetPic = (w >= 400);
                                    for (int oy = -4; oy <= 4; oy++) {
                                        for (int ox = -4; ox <= 4; ox++) {
                                            int lv2 = lb[(y + oy) * w + (x + ox)];
                                            if (sheetPic && lv2 > 150) lv2 = 150;
                                            if (lv2 > sMax) sMax = lv2;
                                        }
                                    }
                                    int lcur = lb[i];
                                    if (sheetPic && lcur > 150) lcur = 150;
                                    int span = sMax - 12;
                                    if (span > 30 && sMax - lcur > 14) {
                                        CGFloat cv = (CGFloat)(sMax - lcur) / (CGFloat)span;
                                        if (cv > 1) cv = 1;
                                        cv = cv * cv * (3.0 - 2.0 * cv);          // smoothstep
                                        int t = (int)(cv * 254.0);
                                        if (t > 0) tx[i] = (unsigned char)t;
                                    }
                                }
                            }
                        }
                        for (size_t y = 2; y + 3 < h; y++) {
                            for (size_t x = 0; x < w; x++) {
                                size_t i = y * w + x;
                                if (tx[i] == 0 && sd[i] == 0 && (tx[(y - 2) * w + x] == 255 || tx[(y - 1) * w + x] == 255)) {
                                    sd[i] = 1;
                                }
                            }
                        }
                        for (size_t y = 0; y < h; y++) {
                            unsigned char *row = px + y * rb;
                            for (size_t x = 0; x < w; x++) {
                                unsigned char *q = row + x * 4;
                                if (q[3] == 0) continue;
                                size_t i = y * w + x;
                                CGFloat a = q[3] / 255.0;
                                CGFloat v = DSKbMap(lb[i] / 255.0);
                                BOOL sheetPic = (w >= 400);
                                if (sheetPic) {
                                    // every key face in the full keyboard picture gets the same flat dark gray; background and key outlines stay black
                                    CGFloat l0 = lb[i] / 255.0;
                                    if (l0 <= 0.30) {
                                        v = l0 * 0.10;
                                    } else {
                                        CGFloat rmp = (l0 - 0.30) / 0.08;
                                        if (rmp > 1) rmp = 1;
                                        v = 0.03 + rmp * (0.22 - 0.03);
                                    }
                                }
                                if (lightKey) {
                                    // a white key becomes the same dark gray as the other keys
                                    v = 0.09 + (lb[i] / 255.0 - 0.86) * 0.5;
                                    if (v < 0.03) v = 0.03;
                                    if (v > 0.16) v = 0.16;
                                } else if (legendLight) {
                                    v = (lb[i] > 128) ? 0.05 : v;           // the white emboss around the symbol -> dark
                                }
                                if (tg != NULL) {
                                    CGFloat t2 = tg[i] / 255.0;
                                    if (tg[i] != 0) v = (tx[i] != 0) ? v : (v + (1.0 - v) * t2);
                                }
                                if (tx[i] != 0) {
                                    CGFloat t = tx[i] / 255.0;
                                    v = v + (1.0 - v) * t;                 // letters -> white
                                } else if (sheetPic) {
                                    // (no extra highlight/shadow rules for the full picture)
                                } else if (sd[i] == 2) {
                                    v = 0.02;                              // the white line under a key -> black
                                } else if (sd[i] != 0 && v > 0.04) {
                                    v = 0.04;                              // dark shadow under the letters
                                }
                                unsigned char c = (unsigned char)(v * a * 255.0 + 0.5);
                                q[0] = c;
                                q[1] = c;
                                q[2] = c;
                            }
                        }
                        out = CGBitmapContextCreateImage(bc);
                    }
                    if (lb != NULL) free(lb);
                    if (tx != NULL) free(tx);
                    if (sd != NULL) free(sd);
                }
                if (tg != NULL) free(tg);
            }
            CGContextRelease(bc);
        }
        // DUMP: when /var/mobile/Library/Caches/DarkSix-kbdump exists, the first few full keyboard pictures are saved as PNG
        // (before and after the recolor) so their real pixels can be studied
        if (w >= 400 && out != NULL) {
            static int dumpState = -1, dumpCount = 0;
            if (dumpState < 0) {
                dumpState = [[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/Library/Caches/DarkSix-kbdump"] ? 1 : 0;
            }
            if (dumpState == 1 && dumpCount < 8) {
                dumpCount++;
                BOOL prevHook = dsInHook;
                dsInHook = YES;
                NSData *pin = UIImagePNGRepresentation([UIImage imageWithCGImage:src]);
                NSData *pout = UIImagePNGRepresentation([UIImage imageWithCGImage:out]);
                [pin writeToFile:[NSString stringWithFormat:@"/var/mobile/Library/Caches/DarkSix-sheet%d-in.png", dumpCount] atomically:YES];
                [pout writeToFile:[NSString stringWithFormat:@"/var/mobile/Library/Caches/DarkSix-sheet%d-out.png", dumpCount] atomically:YES];
                dsInHook = prevHook;
            }
        }
        id second = (out != NULL) ? (id)out : (id)[NSNull null];
        e = [NSArray arrayWithObjects:(id)src, second, nil];
        [dsKbCache setObject:e forKey:key];
        if (out != NULL) {
            if (dsKbOutSet == nil) {
                dsKbOutSet = [[NSMutableSet alloc] init];
                dsKbOutKeep = [[NSMutableArray alloc] init];
            }
            if ([dsKbOutKeep count] < 400) {
                [dsKbOutKeep addObject:(id)out];
                [dsKbOutSet addObject:[NSValue valueWithPointer:out]];
            }
            CGImageRelease(out);
        }
    }
    id r2 = [e objectAtIndex:1];
    return (r2 == [NSNull null]) ? NULL : (CGImageRef)r2;
}

// Keyboard pictures that are set on layers before the layer is attached to the keyboard are missed by the setContents hook
// (that is why a different row stayed white from run to run). While the keyboard is up, look over its layers a few times a
// second and recolor anything still stock.
static BOOL dsKbVisible = NO;

static void DSKbSweepLayer(CALayer *l, int depth) {
    if (l == nil || depth > 14) return;
    id c = l.contents;
    if (c != nil && CFGetTypeID((CFTypeRef)c) == CGImageGetTypeID()) {
        DSLayerInKeyboard(l);                    // also notes whether this layer belongs to the emoji keyboard
        CGImageRef o = DSKeyboardImage((CGImageRef)c);
        if (o != NULL) {
            l.contents = (id)o;
        }
    }
    for (CALayer *sub in [[l.sublayers copy] autorelease]) {
        DSKbSweepLayer(sub, depth + 1);
    }
}

static void DSKbSweepViews(UIView *v, int depth) {
    if (v == nil || depth > 14) return;
    const char *n = class_getName(object_getClass(v));
    if (DSHasPrefix(n, "UIKB") || DSHasPrefix(n, "UIKeyboard")) {
        DSKbSweepLayer(v.layer, 0);
        return;                                  // its whole layer tree was just visited
    }
    for (UIView *s in [[v.subviews copy] autorelease]) {
        DSKbSweepViews(s, depth + 1);
    }
}

static void DSKbSweep(void) {
    if (!dsKbVisible || !dsOptKeyboard) return;
    for (UIWindow *w in [[UIApplication sharedApplication] windows]) {
        DSKbSweepViews(w, 0);
    }
}

static NSMutableDictionary *dsKbOrig = nil;

static void DSKeyboardDrawWrap(id self, SEL _cmd, CGRect rect) {
    IMP orig = NULL;
    for (Class k = object_getClass(self); k != Nil && orig == NULL; k = class_getSuperclass(k)) {
        NSValue *v = [dsKbOrig objectForKey:[NSValue valueWithPointer:(const void *)k]];
        if (v != nil) {
            orig = (IMP)[v pointerValue];
        }
    }
    BOOL prev = dsInKeyboardDraw;
    BOOL prevEmoji = dsKbEmoji;
    dsInKeyboardDraw = YES;
    dsKbEmoji = [self isKindOfClass:[UIView class]] && DSViewInEmoji((UIView *)self);
    if (orig != NULL) {
        ((void (*)(id, SEL, CGRect))orig)(self, _cmd, rect);
    }
    dsKbEmoji = prevEmoji;
    dsInKeyboardDraw = prev;
}

static void DSInstallKeyboardHooks(void) {
    if (dsKbOrig == nil) {
        dsKbOrig = [[NSMutableDictionary alloc] init];
    }
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    NSMutableData *buf = [NSMutableData dataWithLength:sizeof(Class) * count];
    Class *list = (Class *)[buf mutableBytes];
    count = objc_getClassList(list, count);
    Class uiview = [UIView class];
    for (int i = 0; i < count; i++) {
        Class k = list[i];
        const char *n = class_getName(k);
        if (!(DSHasPrefix(n, "UIKB") || DSHasPrefix(n, "UIKeyboard"))) continue;
        BOOL isView = NO;
        for (Class s2 = k; s2 != Nil; s2 = class_getSuperclass(s2)) {
            if (s2 == uiview) {
                isView = YES;
                break;
            }
        }
        if (!isView) continue;
        NSValue *key = [NSValue valueWithPointer:(const void *)k];
        if ([dsKbOrig objectForKey:key] != nil) continue;
        unsigned int mc = 0;
        Method *ms = class_copyMethodList(k, &mc);
        Method own = NULL;
        for (unsigned int j = 0; j < mc; j++) {
            if (method_getName(ms[j]) == @selector(drawRect:)) {
                own = ms[j];
                break;
            }
        }
        if (own != NULL) {
            [dsKbOrig setObject:[NSValue valueWithPointer:(const void *)method_getImplementation(own)] forKey:key];
            method_setImplementation(own, (IMP)DSKeyboardDrawWrap);
        }
        if (ms != NULL) {
            free(ms);
        }
    }
}

// one-time look at what the keyboard is made of, for tuning
static void DSDumpKeyboard(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;
    for (UIWindow *w in [[UIApplication sharedApplication] windows]) {
        if (![w respondsToSelector:@selector(recursiveDescription)]) continue;
        NSString *d = [w performSelector:@selector(recursiveDescription)];
        if (d != nil && ([d rangeOfString:@"UIKB"].location != NSNotFound || [d rangeOfString:@"UIKeyboard"].location != NSNotFound)) {
            if ([d length] > 9000) d = [d substringToIndex:9000];
            DSKbLog([NSString stringWithFormat:@"\n===== keyboard window %@ =====\n%@\n", NSStringFromClass([w class]), d]);
        }
    }
}

// ---------- color remapping ----------

%hook UIView

- (void)setBackgroundColor:(UIColor *)c
{
    UIColor *n = c;
    if (dsBypass) {
        n = c;
    } else if (dsIsMessages && (DSIsEditableTextView(self) || DSHasEditableChild(self) || DSHasEditableSibling(self))) {
        n = c;                       // Messages typing bubble: leave exactly as the app sets it
    } else if (dsIsMessages && [self isKindOfClass:[UILabel class]] && DSIsSolidWhite(c)) {
        n = [UIColor clearColor];    // list previews get a white box when you tap Edit; keep them see-through
    } else if (!DSAvoid(self)) {
        n = DSBackground(c);
    }
    %orig(n);
}

%end

%hook UILabel

- (void)setTextColor:(UIColor *)c
{
    UIColor *n = c;
    if (dsBypass) {
        n = c;                       // we are setting this color ourselves (e.g. the iMessage placeholder)
    } else if (dsIsMessages && DSTextIsDark(c) && DSViewInBalloon(self)) {
        n = [UIColor whiteColor];    // chat bubbles are dark now: white text
    } else if (dsIsMusic && DSInSectionHeader(self) && !DSAvoid(self)) {
        n = [UIColor blackColor];    // Music A, B, C section bars: black text
    } else if (dsIsSettings && (DSIsCaptionColor(c) || DSIsTableCaption(self))) {
        n = [UIColor whiteColor];    // Settings captions: white

    } else if (!DSAvoid(self)) {
        n = DSText(c);
    }
    %orig(n);
}

- (void)drawTextInRect:(CGRect)rect
{
    if (dsIsMessages && !dsBypass && !dsStyling && DSTextIsDark(self.textColor) && DSViewInBalloon(self)) {
        BOOL pb = dsBypass;
        dsBypass = YES;
        self.textColor = [UIColor whiteColor];
        dsBypass = pb;
    }
    BOOL prev = dsInHeaderDraw;
    if (dsIsMusic && DSInSectionHeader(self)) {
        dsInHeaderDraw = YES;                // section bar text is drawn black, never flipped to white
    }
    %orig(rect);
    dsInHeaderDraw = prev;
}

- (void)setShadowColor:(UIColor *)c
{
    UIColor *n = c;
    if (dsIsSettings && !dsBypass && (DSIsTableCaption(self) || DSIsLightColor(c))) {
        n = [UIColor colorWithWhite:0.15 alpha:1.0];      // Settings: white emboss shadows -> dark gray
    } else if (dsIsMusic && !dsBypass && DSInSectionHeader(self) && !DSAvoid(self)) {
        n = [UIColor colorWithWhite:0.75 alpha:0.9];
    } else if (dsIsMusic && !dsBypass && DSIsLightColor(c) && !DSAvoid(self) && !DSInSectionHeader(self)) {
        n = DSMusicShadow();                 // white emboss shadow -> soft gray shading
    }
    %orig(n);
}

- (void)didMoveToWindow
{
    %orig;
    @try {
        if (self.window != nil && dsIsSettings && DSIsTableCaption(self)) {
            self.textColor = [UIColor whiteColor];
            self.shadowColor = [UIColor colorWithWhite:0.15 alpha:1.0];
            self.shadowOffset = CGSizeMake(0, -1);
        } else if (self.window != nil && dsIsMusic && !DSAvoid(self) && DSInSectionHeader(self)) {
            self.textColor = [UIColor blackColor];
            self.shadowColor = [UIColor colorWithWhite:0.75 alpha:0.9];
            self.shadowOffset = CGSizeMake(0, 1);
            // darken the silver bar behind the letter: a translucent black layer between the bar and the text
            UIView *bar = self.superview;
            if ([bar isKindOfClass:[UIImageView class]] && [bar viewWithTag:0xD5A1] == nil) {
                UIView *shade = [[UIView alloc] initWithFrame:bar.bounds];
                shade.tag = 0xD5A1;
                shade.userInteractionEnabled = NO;
                shade.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                shade.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
                [bar insertSubview:shade atIndex:0];
                [shade release];
            }
        } else if (self.window != nil && dsIsMusic && !DSAvoid(self)) {
            UIColor *sc = self.shadowColor;
            CGFloat sd2L = 0, sd2S = 0, sd2A = 0;
            BOOL inCell = NO;
            UIView *sp = self.superview;
            int sd = 0;
            while (sp != nil && sd < 3) {
                if ([sp isKindOfClass:[UITableViewCell class]]) {
                    inCell = YES;
                }
                sp = sp.superview;
                sd++;
            }
            if (DSIsLightColor(sc) || (inCell && !DSInfo(sc, &sd2L, &sd2S, &sd2A))) {
                self.shadowColor = DSMusicShadow();
                self.shadowOffset = CGSizeMake(0, 1);
            }
        }
        if (self.window != nil && dsIsMessages && !dsComposeDumped && [self.text isEqualToString:@"To:"]) {
            dsComposeDumped = YES;
            [self performSelector:@selector(dsDumpCompose) withObject:nil afterDelay:0.8];
        }
        if (self.window != nil && !DSAvoid(self) && !(dsIsMusic && DSInSectionHeader(self))) {
            UIColor *c = self.textColor;
            UIColor *d = DSText(c);
            if (d != c) {
                self.textColor = d;
            }
        }
    } @catch (NSException *e) {
    }
}

%new
- (void)dsDumpCompose
{
    @try {
        DSDumpKeyWindow();
    } @catch (NSException *e) {
    }
}

%end

// Custom-drawn text in Mail and Contacts is drawn straight with Core Graphics.
// We watch which fill color was last set, and only while a piece of TEXT is being
// drawn do we swap a dark fill for a light one (then put the old color back).
// Backgrounds drawn with dark fills are never touched. Loaded only in those two apps.

static CGContextRef dsLastCtx = NULL;
static CGFloat dsLastR = 0, dsLastG = 0, dsLastB = 0, dsLastA = 0;
static BOOL dsLastValid = NO;

static void DSRecord(CGContextRef c, CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    dsLastCtx = c;
    dsLastR = r; dsLastG = g; dsLastB = b; dsLastA = a;
    dsLastValid = YES;
}

typedef struct {
    BOOL did;
    CGContextRef ctx;
    CGFloat r, g, b, a;
} DSTextState;

static void DSCalLog(NSString *line);

static DSTextState DSBeginTextBase(void) {
    DSTextState st;
    if (dsIsCal) {
        static int tl = 0;
        if (tl < 40) {
            tl++;
            DSCalLog([NSString stringWithFormat:@"text draw: last fill %.2f %.2f %.2f a%.2f valid %d\n", dsLastR, dsLastG, dsLastB, dsLastA, (int)dsLastValid]);
        }
    }
    st.did = NO; st.ctx = NULL; st.r = 0; st.g = 0; st.b = 0; st.a = 0;
    if (dsIsMusic && dsDrawMap && dsInHeaderDraw) {
        CGContextRef hc = UIGraphicsGetCurrentContext();
        if (hc != NULL) {
            st.did = YES;
            st.ctx = hc;
            if (dsLastValid && hc == dsLastCtx) {
                st.r = dsLastR; st.g = dsLastG; st.b = dsLastB; st.a = dsLastA;
            } else {
                st.r = 0.3; st.g = 0.3; st.b = 0.3; st.a = 1.0;
            }
            CGContextSetGrayFillColor(hc, 0.0, 1.0);
        }
        return st;
    }
    if (!dsDrawMap || !dsLastValid) return st;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (ctx == NULL || ctx != dsLastCtx) return st;
    CGFloat mx = MAX(dsLastR, MAX(dsLastG, dsLastB));
    CGFloat mn = MIN(dsLastR, MIN(dsLastG, dsLastB));
    CGFloat lum = 0.299 * dsLastR + 0.587 * dsLastG + 0.114 * dsLastB;
    CGFloat sat = (mx > 0) ? (mx - mn) / mx : 0;
    if (dsIsMusic && dsLastA > 0.05 && sat < 0.35 && lum > 0.9) {
        // the stock white "emboss" copy drawn under every title: make it a gray shade instead
        st.did = YES;
        st.ctx = ctx;
        st.r = dsLastR; st.g = dsLastG; st.b = dsLastB; st.a = dsLastA;
        CGContextSetGrayFillColor(ctx, 0.32, dsLastA);
        return st;
    }
    if (dsIsCal && dsLastA > 0.05 && sat < 0.6 && lum < 0.5) {
        // Calendar digits and labels: white (the dark shadow is set separately)
        st.did = YES;
        st.ctx = ctx;
        st.r = dsLastR; st.g = dsLastG; st.b = dsLastB; st.a = dsLastA;
        CGContextSetGrayFillColor(ctx, 1.0, dsLastA);
        return st;
    }
    if (dsLastA > 0.05 && sat < 0.35 && lum < 0.4) {
        st.did = YES;
        st.ctx = ctx;
        st.r = dsLastR; st.g = dsLastG; st.b = dsLastB; st.a = dsLastA;
        CGContextSetGrayFillColor(ctx, 1.0 - lum, dsLastA);
    }
    return st;
}

// Calendar: month digits are drawn with a picture-pattern fill (-> plain white), and many labels are drawn
// twice (a light "emboss" copy under the real one: that copy becomes a soft very dark gray shadow)
static NSMutableSet *dsEmbossSet = nil;
static NSString *dsPrevStr = nil;
static BOOL dsPrevWhite = NO;
static CFAbsoluteTime dsPrevT = 0;

static DSTextState DSBeginText(NSString *str) {
    if (dsIsCal) {
        DSTextState st;
        st.did = NO; st.ctx = NULL; st.r = 0; st.g = 0; st.b = 0; st.a = 1;
        CGContextRef ctx = UIGraphicsGetCurrentContext();
        if (ctx != NULL) {
            if (!(dsLastValid && ctx == dsLastCtx)) {
                st.did = YES;
                st.ctx = ctx;
                CGContextSetGrayFillColor(ctx, 1.0, 1.0);
                dsPrevStr = nil;
                return st;
            }
            CGFloat mx = MAX(dsLastR, MAX(dsLastG, dsLastB));
            CGFloat mn = MIN(dsLastR, MIN(dsLastG, dsLastB));
            CGFloat lum = 0.299 * dsLastR + 0.587 * dsLastG + 0.114 * dsLastB;
            BOOL whiteish = (lum > 0.9 && (mx - mn) < 0.15 && dsLastA > 0.05);
            BOOL solidWhite = whiteish && dsLastA >= 0.9;
            if (dsEmbossSet == nil) {
                dsEmbossSet = [[NSMutableSet alloc] init];
            }
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            BOOL embossCopy = NO;
            if (whiteish && dsLastA < 0.9) {
                embossCopy = YES;                                  // translucent white copy
            } else if (solidWhite && str != nil && [dsEmbossSet containsObject:str]) {
                embossCopy = YES;                                  // a white copy seen before under a real label
            }
            if (!whiteish && dsPrevStr != nil && dsPrevWhite && str != nil && (now - dsPrevT) < 0.01 &&
                [dsPrevStr isEqualToString:str]) {
                [dsEmbossSet addObject:str];                       // white copy first, real text second: learn it
            }
            [dsPrevStr release];
            dsPrevStr = [str copy];
            dsPrevWhite = solidWhite;
            dsPrevT = now;
            if (embossCopy) {
                st.did = YES;
                st.ctx = ctx;
                st.r = dsLastR; st.g = dsLastG; st.b = dsLastB; st.a = dsLastA;
                CGContextSetGrayFillColor(ctx, 0.08, 0.7);
                return st;
            }
        }
    }
    return DSBeginTextBase();
}

static void DSEndText(DSTextState st) {
    if (st.did) {
        CGContextSetRGBFillColor(st.ctx, st.r, st.g, st.b, st.a);
    }
}

%group DrawHooks

// thin, wide light rectangles inside a Music song row are its divider lines: draw them dark
%hookf(void, CGContextFillRect, CGContextRef c, CGRect rect)
{
    if (dsInMusicCell && rect.size.height <= 3.0 && rect.size.width >= 200.0) {
        CGContextSaveGState(c);
        CGContextSetGrayFillColor(c, 0.06, 1.0);
        %orig(c, rect);
        CGContextRestoreGState(c);
        return;
    }
    if (dsIsCal && dsLastValid && c == dsLastCtx && dsLastA > 0.5) {
        // Calendar's day view: white page -> black, light gray hour lines -> dark gray
        CGFloat mx = MAX(dsLastR, MAX(dsLastG, dsLastB));
        CGFloat mn = MIN(dsLastR, MIN(dsLastG, dsLastB));
        CGFloat lum = 0.299 * dsLastR + 0.587 * dsLastG + 0.114 * dsLastB;
        BOOL midPage = (mx - mn < 0.1 && lum > 0.12 && lum <= 0.6 && rect.size.width >= 100 && rect.size.height >= 40);
        BOOL bigEnough = (rect.size.width >= 100 || rect.size.height >= 100);     // never small glyphs like the + button
        if (bigEnough && ((mx - mn < 0.1 && lum > 0.6) || midPage)) {
            CGFloat oR = dsLastR, oG = dsLastG, oB = dsLastB, oA = dsLastA;
            CGContextSaveGState(c);
            if (rect.size.height <= 2.5 || rect.size.width <= 2.5) {
                CGContextSetGrayFillColor(c, 0.28, 1.0);
            } else {
                CGContextSetGrayFillColor(c, 0.0, 1.0);
            }
            %orig(c, rect);
            CGContextRestoreGState(c);
            dsLastCtx = c; dsLastR = oR; dsLastG = oG; dsLastB = oB; dsLastA = oA; dsLastValid = YES;
            return;
        }
    }
    %orig(c, rect);
}

%hookf(void, CGContextSetShadow, CGContextRef c, CGSize offset, CGFloat blur)
{
    if (dsIsCal) {
        CGContextSetShadowWithColor(c, offset, blur, [UIColor colorWithWhite:0.08 alpha:0.7].CGColor);
        return;
    }
    %orig(c, offset, blur);
}

%hookf(void, CGContextSetShadowWithColor, CGContextRef c, CGSize offset, CGFloat blur, CGColorRef color)
{
    CGColorRef use = color;
    if ((dsIsMusic || dsIsCal) && dsDrawMap && !dsInHeaderDraw && color != NULL) {
        size_t n = CGColorGetNumberOfComponents(color);
        const CGFloat *p = CGColorGetComponents(color);
        CGFloat L = -1, A = 1;
        if (n == 2) {
            L = p[0];
            A = p[1];
        } else if (n == 4) {
            L = 0.299 * p[0] + 0.587 * p[1] + 0.114 * p[2];
            A = p[3];
        }
        if (L > 0.6 && A > 0.05) {
            use = dsIsCal ? [UIColor colorWithWhite:0.08 alpha:0.7].CGColor     // Calendar: very dark gray
                          : [UIColor colorWithWhite:0.3 alpha:1.0].CGColor;      // light emboss -> gray shading
        } else if (dsIsCal && A > 0.05 && L < 0.45) {
            use = [UIColor colorWithWhite:0.08 alpha:0.7].CGColor;      // harsh dark/blue shadow -> softer very dark gray
        }
    }
    %orig(c, offset, blur, use);
}

// --- record every fill color that gets set (no changes made here) ---

%hookf(void, CGContextSetGrayFillColor, CGContextRef c, CGFloat gray, CGFloat alpha)
{
    DSRecord(c, gray, gray, gray, alpha);
    %orig(c, gray, alpha);
}

%hookf(void, CGContextSetRGBFillColor, CGContextRef c, CGFloat r, CGFloat g, CGFloat b, CGFloat alpha)
{
    DSRecord(c, r, g, b, alpha);
    %orig(c, r, g, b, alpha);
}

%hookf(void, CGContextSetFillColorWithColor, CGContextRef c, CGColorRef color)
{
    BOOL ok = NO;
    if (color != NULL) {
        CGColorSpaceModel m = CGColorSpaceGetModel(CGColorGetColorSpace(color));
        size_t n = CGColorGetNumberOfComponents(color);
        const CGFloat *p = CGColorGetComponents(color);
        if (m == kCGColorSpaceModelMonochrome && n == 2) {
            DSRecord(c, p[0], p[0], p[0], p[1]);
            ok = YES;
        } else if (m == kCGColorSpaceModelRGB && n == 4) {
            DSRecord(c, p[0], p[1], p[2], p[3]);
            ok = YES;
        }
    }
    if (!ok) {
        dsLastValid = NO;
    }
    %orig(c, color);
}

// --- string drawing: this is where the text color is fixed ---

%hook NSString

- (CGSize)drawAtPoint:(CGPoint)point withFont:(UIFont *)font
{
    DSTextState st = DSBeginText(self);
    CGSize sz = %orig(point, font);
    DSEndText(st);
    return sz;
}

- (CGSize)drawAtPoint:(CGPoint)point forWidth:(CGFloat)width withFont:(UIFont *)font lineBreakMode:(NSLineBreakMode)mode
{
    DSTextState st = DSBeginText(self);
    CGSize sz = %orig(point, width, font, mode);
    DSEndText(st);
    return sz;
}

- (CGSize)drawAtPoint:(CGPoint)point forWidth:(CGFloat)width withFont:(UIFont *)font fontSize:(CGFloat)fontSize lineBreakMode:(NSLineBreakMode)mode baselineAdjustment:(UIBaselineAdjustment)adj
{
    DSTextState st = DSBeginText(self);
    CGSize sz = %orig(point, width, font, fontSize, mode, adj);
    DSEndText(st);
    return sz;
}

- (CGSize)drawInRect:(CGRect)rect withFont:(UIFont *)font
{
    DSTextState st = DSBeginText(self);
    CGSize sz = %orig(rect, font);
    DSEndText(st);
    return sz;
}

- (CGSize)drawInRect:(CGRect)rect withFont:(UIFont *)font lineBreakMode:(NSLineBreakMode)mode
{
    DSTextState st = DSBeginText(self);
    CGSize sz = %orig(rect, font, mode);
    DSEndText(st);
    return sz;
}

- (CGSize)drawInRect:(CGRect)rect withFont:(UIFont *)font lineBreakMode:(NSLineBreakMode)mode alignment:(NSTextAlignment)alignment
{
    DSTextState st = DSBeginText(self);
    CGSize sz = %orig(rect, font, mode, alignment);
    DSEndText(st);
    return sz;
}

%end

%end

// ---------- text fields / text views / keyboard ----------

%hook UITextField

- (void)setTextColor:(UIColor *)c
{
    UIColor *n = c;
    if (!DSAvoid(self)) {
        n = DSText(c);
    }
    %orig(n);
}

- (void)didMoveToWindow
{
    %orig;
    @try {
        if (self.window != nil && !DSAvoid(self)) {
            UIColor *c = self.textColor;
            UIColor *d = (c != nil) ? DSText(c) : [UIColor whiteColor];
            if (d != c) {
                self.textColor = d;
            }
            DSDarkKeyboard(self);
            if (self.borderStyle == UITextBorderStyleRoundedRect) {
                // the stock rounded field is a white image, so draw our own dark one
                self.borderStyle = UITextBorderStyleNone;
                self.backgroundColor = [UIColor colorWithWhite:0.14 alpha:1.0];
                self.layer.cornerRadius = 7.0;
                self.layer.masksToBounds = YES;
            }
        }
    } @catch (NSException *e) {
    }
}

%end

%hook UITextView

- (void)setTextColor:(UIColor *)c
{
    UIColor *n = c;
    if (dsBypass) {
        n = c;
    } else if (dsIsMessages && self.editable) {
        n = c;                       // typed text in Messages: leave as the app sets it (black)
    } else if (dsIsMessages && DSTextIsDark(c) && DSViewInBalloon(self)) {
        n = [UIColor whiteColor];
    } else if (!DSAvoid(self)) {
        n = DSText(c);
    }
    %orig(n);
}

- (void)didMoveToWindow
{
    %orig;
    @try {
        if (self.window != nil) {
            if (dsIsMessages && self.editable) {
                DSWhiteBubble(self);
                DSDarkKeyboard(self);
            } else if (dsIsMessages && DSViewInBalloon(self)) {
                if (DSTextIsDark(self.textColor)) {
                    BOOL pb = dsBypass;
                    dsBypass = YES;
                    self.textColor = [UIColor whiteColor];
                    dsBypass = pb;
                }
            } else if (!DSAvoid(self)) {
                UIColor *c = self.textColor;
                UIColor *d = (c != nil) ? DSText(c) : [UIColor whiteColor];
                if (d != c) {
                    self.textColor = d;
                }
                DSDarkKeyboard(self);
            }
        }
    } @catch (NSException *e) {
    }
}

%end

// ---------- tables and cells ----------

// Music: hide any stray thin line views inside a song row (the white bars), and write what a row holds
static void DSHideThinLines(UIView *v, UIView *cell, int depth) {
    if (v == nil || depth > 4) return;
    NSArray *subs = [NSArray arrayWithArray:v.subviews];
    for (UIView *x in subs) {
        if (x.tag == 0xD5A2 || x.tag == 0xD5A3) continue;
        const char *n = class_getName(object_getClass(x));
        CGRect f = x.frame;
        BOOL thin = (f.size.height <= 2.5 && f.size.width >= cell.bounds.size.width * 0.4);
        if (DSContains(n, "Separator") || thin) {
            x.hidden = YES;
            x.alpha = 0.0;
        } else {
            DSHideThinLines(x, cell, depth + 1);
        }
    }
}

static BOOL dsCellDumped = NO;

static void DSMusicCellClean(UITableViewCell *cell) {
    DSHideThinLines(cell, cell, 0);
    if (DSDebugOn() && !dsCellDumped && [cell respondsToSelector:@selector(recursiveDescription)]) {
        dsCellDumped = YES;
        NSString *d = [cell performSelector:@selector(recursiveDescription)];
        NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
        NSString *dir = ([dirs count] > 0) ? [dirs objectAtIndex:0] : NSTemporaryDirectory();
        [[NSString stringWithFormat:@"cell class %s\n%@\n", class_getName(object_getClass(cell)), d]
            writeToFile:[dir stringByAppendingPathComponent:@"DarkSix-cell.txt"] atomically:YES
            encoding:NSUTF8StringEncoding error:NULL];
    }
}

// Music: our own song dividers - a dark gray line with a darker (nearGlyph black) line under it,
// instead of UIKit's gray line with a white highlight
static void DSMusicSeparator(UITableViewCell *cell) {
    UIView *tv = cell.superview;
    while (tv != nil && ![tv isKindOfClass:[UITableView class]]) {
        tv = tv.superview;
    }
    if (tv == nil || ((UITableView *)tv).style != UITableViewStylePlain) return;
    if ([cell viewWithTag:0xD5A2] != nil) return;
    CGFloat w = cell.bounds.size.width;
    CGFloat h = cell.bounds.size.height;
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(0, h - 2, w, 2)];
    box.tag = 0xD5A2;
    box.userInteractionEnabled = NO;
    box.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    UIView *line = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 1)];
    line.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    line.backgroundColor = [UIColor colorWithWhite:0.14 alpha:1.0];
    [box addSubview:line];
    [line release];
    UIView *shadow = [[UIView alloc] initWithFrame:CGRectMake(0, 1, w, 1)];
    shadow.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    shadow.backgroundColor = [UIColor colorWithWhite:0.0 alpha:1.0];
    [box addSubview:shadow];
    [shadow release];
    [cell addSubview:box];
    [box release];

    // and a dark strip along the top edge, in case the white line is drawn there
    UIView *top = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 2)];
    top.tag = 0xD5A3;
    top.userInteractionEnabled = NO;
    top.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    top.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1.0];
    [cell addSubview:top];
    [top release];
}

%hook UITableView

- (void)didMoveToWindow
{
    %orig;
    @try {
        if (self.window != nil && !DSAvoid(self)) {
            self.backgroundView = nil;                    // removes the grouped pinstripe
            UIColor *pin = nil;
            if (dsOptPinstripes && dsIsSettings && self.style == UITableViewStyleGrouped) {
                pin = DSPatternNamed(@"pinstripe");
            }
            self.backgroundColor = (pin != nil) ? pin : [UIColor blackColor];
            if (dsIsMusic && self.style == UITableViewStylePlain) {
                self.separatorStyle = UITableViewCellSeparatorStyleNone;
            }
            if (self.separatorStyle != UITableViewCellSeparatorStyleNone) {
                self.separatorColor = [UIColor colorWithWhite:(dsIsMusic ? 0.15 : 0.22) alpha:1.0];
            }
        }
    } @catch (NSException *e) {
    }
}

- (void)setSeparatorStyle:(UITableViewCellSeparatorStyle)st
{
    if (dsIsMusic && !DSAvoid(self) && self.style == UITableViewStylePlain) {
        %orig(UITableViewCellSeparatorStyleNone);     // Music draws its own dividers (see DSMusicSeparator)
    } else {
        %orig(st);
    }
}

- (void)setSeparatorColor:(UIColor *)c
{
    if (dsIsMusic && !DSAvoid(self)) {
        // Music: thin, almost black lines between songs
        %orig([UIColor colorWithWhite:0.15 alpha:1.0]);
    } else {
        %orig(c);
    }
}

%end

%hook IUMusicTableViewCell

- (void)drawRect:(CGRect)rect
{
    BOOL prev = dsInMusicCell;
    dsInMusicCell = YES;
    %orig(rect);
    dsInMusicCell = prev;
}

%end

// Settings: the little arrows (disclosure indicators) at the right of a row are redrawn in a very dark gray.
static UIView *DSFindDisclosure(UIView *v, int depth) {
    if (v == nil || depth > 3) return nil;
    for (UIView *x in [NSArray arrayWithArray:v.subviews]) {
        if (x.tag == 0xD5B1) continue;
        const char *n = class_getName(object_getClass(x));
        if (DSContains(n, "Disclosure")) return x;
        if (depth == 0 && x.frame.size.width <= 30 && x.frame.size.height <= 30 && x.frame.origin.x > v.bounds.size.width * 0.8 && ![x isKindOfClass:[UISwitch class]] && ![x isKindOfClass:[UILabel class]]) {
            if ([x isKindOfClass:[UIImageView class]] || [x isMemberOfClass:[UIView class]] || DSContains(n, "Accessory") || DSContains(n, "Indicator")) return x;
        }
        UIView *r = DSFindDisclosure(x, depth + 1);
        if (r != nil) return r;
    }
    return nil;
}

static UIImage *DSTintImage(UIImage *src, float tr, float tg, float tb) {
    if (src == nil || src.CGImage == NULL) return src;
    CGImageRef cg = src.CGImage;
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    if (w < 1 || h < 1 || w * h > 200 * 200) return src;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef cx = CGBitmapContextCreate(NULL, w, h, 8, w * 4, cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (cx == NULL) return src;
    CGContextDrawImage(cx, CGRectMake(0, 0, w, h), cg);
    unsigned char *px = (unsigned char *)CGBitmapContextGetData(cx);
    for (size_t i = 0; i < w * h; i++) {
        unsigned char a = px[i * 4 + 3];
        px[i * 4] = (unsigned char)(tr * a); px[i * 4 + 1] = (unsigned char)(tg * a); px[i * 4 + 2] = (unsigned char)(tb * a);
    }
    CGImageRef out = CGBitmapContextCreateImage(cx);
    CGContextRelease(cx);
    if (out == NULL) return src;
    UIImage *r = [UIImage imageWithCGImage:out scale:src.scale orientation:UIImageOrientationUp];
    CGImageRelease(out);
    return r;
}

static NSMutableSet *dsArrowImgs = nil;

// is this small picture dark (an arrow), judged by its opaque pixels?
static BOOL DSImageIsDark(UIImage *src) {
    if (src == nil || src.CGImage == NULL) return NO;
    CGImageRef cg = src.CGImage;
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    if (w < 2 || h < 2 || w > 100 || h > 100) return NO;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef cx = CGBitmapContextCreate(NULL, w, h, 8, w * 4, cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (cx == NULL) return NO;
    CGContextDrawImage(cx, CGRectMake(0, 0, w, h), cg);
    unsigned char *px = (unsigned char *)CGBitmapContextGetData(cx);
    double sum = 0, wsum = 0;
    for (size_t i = 0; i < w * h; i++) {
        double a = px[i * 4 + 3];
        if (a < 40) continue;
        double L = (0.299 * px[i * 4] + 0.587 * px[i * 4 + 1] + 0.114 * px[i * 4 + 2]) / a;      // premultiplied
        sum += L * a; wsum += a;
    }
    CGContextRelease(cx);
    return (wsum > 0 && sum / wsum < 0.45);
}

static NSMutableDictionary *dsArrowMap = nil;     // original picture -> its blue version (the same picture is shared by every row)

static UIImage *DSArrowFix(UIImage *im) {
    if (im == nil) return nil;
    NSString *k = [NSString stringWithFormat:@"%p", im];
    if ([dsArrowImgs containsObject:k]) return im;                      // this is already one of our blue pictures
    UIImage *known = [dsArrowMap objectForKey:k];
    if (known != nil) return known;                                     // seen before: hand out the same blue version
    UIImage *t = im;
    if (DSImageIsDark(im)) {
        t = DSTintImage(im, 0.12f, 0.45f, 0.86f);                       // the blue of a switch's ON position
    }
    if (t != im) [dsArrowImgs addObject:[NSString stringWithFormat:@"%p", t]];
    if (dsArrowMap == nil) dsArrowMap = [[NSMutableDictionary alloc] init];
    if ([dsArrowMap count] > 200) [dsArrowMap removeAllObjects];
    [dsArrowMap setObject:t forKey:k];                                  // t == im when it is not an arrow
    static NSMutableArray *keep = nil;
    if (keep == nil) keep = [[NSMutableArray alloc] init];
    if ([keep count] < 300) [keep addObject:im];                       // keep the original alive so its address is never reused
    return t;
}

// finds every small dark picture at the right edge of a row (the arrow, whichever way the row builds it)
static BOOL DSRecolorArrowsIn(UIView *v, UITableViewCell *cell, int depth) {
    if (v == nil || depth > 3) return NO;
    BOOL did = NO;
    for (UIView *x in [NSArray arrayWithArray:v.subviews]) {
        if ([x isKindOfClass:[UISwitch class]] || [x isKindOfClass:[UILabel class]] || [x isKindOfClass:[UITextField class]] || x.tag == 0xD5B1) continue;
        CGRect fr = [x.superview convertRect:x.frame toView:cell];
        BOOL atRight = (fr.origin.x >= cell.bounds.size.width * 0.78 && fr.size.width <= 50 && fr.size.height <= 50);
        if (atRight) {
            if ([x isKindOfClass:[UIButton class]]) {
                UIButton *btn = (UIButton *)x;
                UIImage *im = [btn imageForState:UIControlStateNormal];
                if (im == nil) im = btn.imageView.image;
                UIImage *t = DSArrowFix(im);
                if (t != nil && t != im) {
                    [btn setImage:t forState:UIControlStateNormal];
                    UIImage *hi = [btn imageForState:UIControlStateHighlighted];
                    if (hi != nil && hi != im && hi != t) [btn setImage:DSTintImage(hi, 0.12f, 0.45f, 0.86f) forState:UIControlStateHighlighted];
                    if (btn.imageView.image != nil && btn.imageView.image != t) btn.imageView.image = t;
                    did = YES;
                } else if (t != nil) {
                    did = YES;
                }
            } else if ([x isKindOfClass:[UIImageView class]]) {
                UIImageView *iv = (UIImageView *)x;
                UIImage *t = DSArrowFix(iv.image);
                if (t != nil && t != iv.image) {
                    iv.image = t;
                    if (iv.highlightedImage != nil) iv.highlightedImage = DSTintImage(iv.highlightedImage, 0.12f, 0.45f, 0.86f);
                    did = YES;
                }
            }
        }
        if (DSRecolorArrowsIn(x, cell, depth + 1)) did = YES;
    }
    return did;
}

static BOOL DSRecolorArrowButton(UITableViewCell *cell) {
    if (dsArrowImgs == nil) dsArrowImgs = [[NSMutableSet alloc] init];
    return DSRecolorArrowsIn(cell, cell, 0);
}

static void DSLinesLog(NSString *line);

static void DSDumpTree(UIView *v, UITableViewCell *cell, int depth, NSMutableString *log) {
    if (v == nil || depth > 4) return;
    for (UIView *x in [NSArray arrayWithArray:v.subviews]) {
        CGRect fr = [x.superview convertRect:x.frame toView:cell];
        [log appendFormat:@"%*s%s cellFrame=%@ hidden=%d img=%@ sublayers=%d contents=%s\n", depth * 2, "", class_getName(object_getClass(x)), NSStringFromCGRect(fr), x.hidden,
            [x isKindOfClass:[UIImageView class]] ? [NSString stringWithFormat:@"%@", ((UIImageView *)x).image] : ([x isKindOfClass:[UIButton class]] ? [NSString stringWithFormat:@"btn:%@", [(UIButton *)x imageForState:UIControlStateNormal]] : @"-"),
            (int)[x.layer.sublayers count], x.layer.contents ? class_getName(object_getClass(x.layer.contents)) : "nil"];
        DSDumpTree(x, cell, depth + 1, log);
    }
}

static void DSRecolorDisclosure(UITableViewCell *cell) {
    static int arrowDumps = 0;
    if (DSRecolorArrowButton(cell)) return;
    UIView *ind = DSFindDisclosure(cell, 0);
    if (arrowDumps < 6 && (cell.accessoryType != UITableViewCellAccessoryNone || cell.accessoryView != nil)) {
        arrowDumps++;
        NSMutableString *lg = [NSMutableString stringWithFormat:@"-- ARROW not found in %@ accessoryType=%d accessoryView=%@ found=%@ cellSize=%@\n", NSStringFromClass([cell class]), (int)cell.accessoryType, cell.accessoryView, ind, NSStringFromCGSize(cell.bounds.size)];
        DSDumpTree(cell, cell, 0, lg);
        DSLinesLog(lg);
    }
    if (ind == nil || ind.superview == nil) return;
    CGRect fr = ind.frame;
    if (fr.size.width < 4 || fr.size.height < 4) return;
    UIImageView *ov = (UIImageView *)[ind.superview viewWithTag:0xD5B1];
    if (ov == nil) {
        CGFloat sc = [UIScreen mainScreen].scale;
        size_t w = (size_t)ceil(fr.size.width * sc), h = (size_t)ceil(fr.size.height * sc);
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef cx = CGBitmapContextCreate(NULL, w, h, 8, w * 4, cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        CGColorSpaceRelease(cs);
        if (cx == NULL) return;
        CGContextTranslateCTM(cx, 0, h);
        CGContextScaleCTM(cx, sc, -sc);
        BOOL wasHidden = ind.hidden;
        ind.hidden = NO;
        [ind.layer renderInContext:cx];
        ind.hidden = wasHidden;
        unsigned char *px = (unsigned char *)CGBitmapContextGetData(cx);
        int solid = 0;
        for (size_t i = 0; i < w * h; i++) {
            unsigned char a = px[i * 4 + 3];
            if (a > 20) solid++;
            px[i * 4] = (unsigned char)(0.12f * a); px[i * 4 + 1] = (unsigned char)(0.45f * a); px[i * 4 + 2] = (unsigned char)(0.86f * a);     // switch-ON blue, same shape
        }
        CGImageRef im = (solid > 4) ? CGBitmapContextCreateImage(cx) : NULL;
        CGContextRelease(cx);
        if (im == NULL) return;
        ov = [[[UIImageView alloc] initWithImage:[UIImage imageWithCGImage:im scale:sc orientation:UIImageOrientationUp]] autorelease];
        CGImageRelease(im);
        ov.tag = 0xD5B1;
        ov.userInteractionEnabled = NO;
        [ind.superview addSubview:ov];
    }
    ov.frame = fr;
    ind.hidden = YES;
    ov.hidden = NO;
}

static void DSSettingsCellBg(UITableViewCell *cell);

%hook UITableViewCell

%new
- (void)dsCleanLater
{
    @try {
        DSMusicCellClean(self);
    } @catch (NSException *e) {
    }
}

- (void)layoutSubviews
{
    %orig;
    @try {
        if (dsIsSettings && self.window != nil && !DSAvoid(self)) {
            DSSettingsCellBg(self);
            DSRecolorDisclosure(self);
        }
    } @catch (NSException *e) {
    }
}

- (void)didMoveToWindow
{
    %orig;
    @try {
        if (self.window != nil && dsIsMusic && !DSAvoid(self)) {
            DSMusicSeparator(self);
            DSMusicCellClean(self);
            [self performSelector:@selector(dsCleanLater) withObject:nil afterDelay:0.15];
        }
        if (self.window != nil && !DSAvoid(self)) {
            UIColor *bg = self.backgroundColor;
            CGFloat L = 0, S = 0, A = 0;
            BOOL light = (bg == nil);
            if (!light && DSInfo(bg, &L, &S, &A)) {
                light = (A > 0.05 && L > 0.5 && S < 0.35);
            }
            if (light) {
                self.backgroundColor = [UIColor colorWithWhite:0.10 alpha:1.0];
            }
        }
    } @catch (NSException *e) {
    }
}

%end

// ---------- bar buttons (Messages only) ----------

%hook UIBarButtonItem

- (void)setTintColor:(UIColor *)c
{
    UIColor *n = c;
    if (dsIsMessages || dsIsExtra) {
        n = nil;
    }
    %orig(n);
}

- (void)setStyle:(UIBarButtonItemStyle)style
{
    UIBarButtonItemStyle n = style;
    if ((dsIsMessages || dsIsExtra) && style == UIBarButtonItemStyleDone) {
        n = UIBarButtonItemStyleBordered;
    }
    %orig(n);
}

%end

// ---------- bars ----------
// Bars ignore the "CK" (Messages) exclusion so Messages' nav bar goes dark too.

%hook UINavigationBar

- (void)layoutSubviews
{
    %orig;
    @try {
        if (dsIsMessages || dsIsMusic) {
            DSRecolorNavBar(self);
        }
    } @catch (NSException *e) {
    }
}

- (void)setBarStyle:(UIBarStyle)style
{
    UIBarStyle n = style;
    if (dsIsMessages && !dsStyleBypass) {
        n = UIBarStyleBlack;
    } else if (dsIsMusic && style == UIBarStyleDefault) {
        n = UIBarStyleBlack;
    }
    %orig(n);
}

- (void)setTintColor:(UIColor *)c
{
    UIColor *n = c;
    if (dsIsMessages) {
        n = nil;                     // Messages tints its bar blue; remove that
    } else if (dsIsMusic) {
        CGFloat tl = 0, ts = 0, ta = 0;
        if (self.barStyle != UIBarStyleBlackTranslucent || (DSInfo(c, &tl, &ts, &ta) && ts > 0.25)) {
            n = nil;                 // silver or blue tints are removed
        }
    }
    %orig(n);
}

- (void)setBackgroundImage:(UIImage *)image forBarMetrics:(UIBarMetrics)metrics
{
    UIImage *n = image;
    if (dsIsMusic && self.barStyle != UIBarStyleBlackTranslucent) {
        n = nil;                     // no custom silver picture
    }
    %orig(n, metrics);
}

- (void)setTitleTextAttributes:(NSDictionary *)attrs
{
    NSDictionary *n = attrs;
    if (dsIsMusic && self.barStyle != UIBarStyleBlackTranslucent) {
        n = DSLightTitleAttrs();
    }
    %orig(n);
}

- (void)didMoveToWindow
{
    %orig;
    @try {
        if (self.window != nil && !DSAvoidEx(self, YES)) {
            if (self.barStyle == UIBarStyleDefault || dsIsMessages) {
                self.barStyle = UIBarStyleBlack;
            }
            if (dsIsMessages) {
                self.tintColor = nil;
            }
            if (dsIsMusic && self.barStyle != UIBarStyleBlackTranslucent) {
                self.tintColor = nil;
                [self setBackgroundImage:nil forBarMetrics:UIBarMetricsDefault];
                [self setBackgroundImage:nil forBarMetrics:UIBarMetricsLandscapePhone];
                self.titleTextAttributes = DSLightTitleAttrs();
            }
        }
    } @catch (NSException *e) {
    }
}

%end

// ---------- Music: tab bar ----------

%hook UITabBar

- (void)layoutSubviews
{
    %orig;
    @try {
        if (dsIsMusic) {
            for (UIView *b in self.subviews) {
                for (UIView *iv in b.subviews) {
                    if ([iv isKindOfClass:[UIImageView class]] &&
                        DSContains(class_getName(object_getClass(iv)), "TabBarSwappable")) {
                        UIImage *cur = ((UIImageView *)iv).image;
                        UIImage *n = DSTabImageFor((UIImageView *)iv, cur);
                        if (n != cur) {
                            ((UIImageView *)iv).image = n;
                        }
                    }
                }
            }
        }
    } @catch (NSException *e) {
    }
}

- (void)setTintColor:(UIColor *)c
{
    UIColor *n = c;
    if (dsIsMusic) {
        n = [UIColor blackColor];
    }
    %orig(n);
}

- (void)setSelectedImageTintColor:(UIColor *)c
{
    UIColor *n = c;
    if (dsIsMusic) {
        n = [UIColor colorWithWhite:0.95 alpha:1.0];
    }
    %orig(n);
}

- (void)setBackgroundImage:(UIImage *)image
{
    UIImage *n = image;
    if (dsIsMusic) {
        n = nil;
    }
    %orig(n);
}

- (void)setSelectionIndicatorImage:(UIImage *)image
{
    UIImage *n = image;
    if (dsIsMusic) {
        n = nil;
    }
    %orig(n);
}

- (void)didMoveToWindow
{
    %orig;
    @try {
        if (self.window != nil && dsIsMusic) {
            for (UITabBarItem *ti in self.items) {
                DSFixTabItem(ti);
            }
            self.tintColor = [UIColor blackColor];
            if ([self respondsToSelector:@selector(setSelectedImageTintColor:)]) {
                self.selectedImageTintColor = [UIColor colorWithWhite:0.95 alpha:1.0];
            }
            self.backgroundImage = nil;
            self.selectionIndicatorImage = nil;
        }
    } @catch (NSException *e) {
    }
}

%end

%hook UITabBarItem

- (void)setImage:(UIImage *)image
{
    %orig(image);
    @try {
        if (dsIsMusic && image != nil) {
            DSFixTabItem(self);
        }
    } @catch (NSException *e) {
    }
}

%end

// ---------- switches: gray track instead of white ----------

%hook UISwitch

- (void)didMoveToWindow
{
    %orig;
    @try {
        if (self.window != nil && [self respondsToSelector:@selector(setTintColor:)]) {
            self.tintColor = [UIColor colorWithWhite:0.36 alpha:1.0];
        }
    } @catch (NSException *e) {
    }
}

%end

// ---------- Messages: black status bar (it followed the bar colors and turned blue) ----------

%hook UIApplication

- (void)setStatusBarStyle:(UIStatusBarStyle)style animated:(BOOL)animated
{
    UIStatusBarStyle n = style;
    if (dsIsMessages) {
        n = UIStatusBarStyleBlackOpaque;
    }
    %orig(n, animated);
}

- (void)setStatusBarStyle:(UIStatusBarStyle)style
{
    UIStatusBarStyle n = style;
    if (dsIsMessages) {
        n = UIStatusBarStyleBlackOpaque;
    }
    %orig(n);
}

%end

%hook UIToolbar

- (void)setBarStyle:(UIBarStyle)style
{
    UIBarStyle n = style;
    if (dsIsMessages && !dsStyleBypass) {
        n = UIBarStyleBlack;
    }
    %orig(n);
}

- (void)setTintColor:(UIColor *)c
{
    UIColor *n = c;
    if (dsIsMessages) {
        n = nil;
    }
    %orig(n);
}

- (void)didMoveToWindow
{
    %orig;
    @try {
        if (self.window != nil && !DSAvoidEx(self, YES)) {
            if (self.barStyle == UIBarStyleDefault || dsIsMessages) {
                self.barStyle = UIBarStyleBlack;
            }
            if (dsIsMessages) {
                self.tintColor = nil;
            }
        }
    } @catch (NSException *e) {
    }
}

%end

%hook UISearchBar

- (void)didMoveToWindow
{
    %orig;
    @try {
        if (self.window != nil) {
            if (self.barStyle == UIBarStyleDefault) {
                self.barStyle = UIBarStyleBlack;
            }
            DSDarkKeyboard(self);
        }
    } @catch (NSException *e) {
    }
}

%end

// ---------- Messages: dark chat background (bubbles stay untouched) ----------
// Messages' own classes have "Transcript" in their names. Only the background
// of those is changed; the bubbles themselves are never touched.

%hook UIScrollView

- (void)didMoveToWindow
{
    %orig;
    @try {
        if (self.window != nil && DSContains(class_getName(object_getClass(self)), "Transcript")) {
            self.backgroundColor = DSTranscriptColor();
            if ([self isKindOfClass:[UITableView class]]) {
                ((UITableView *)self).backgroundView = nil;
            }
        }
    } @catch (NSException *e) {
    }
}

%end

// ---------- Messages: typing bar ----------
// Hooked lazily (see viewWillAppear above) because the class lives in ChatKit.

%group MessagesHooks

%hook CKMessageEntryView

- (void)setImage:(UIImage *)image
{
    UIImage *n = DSDarkBarImage(image);
    %orig(n);
}

- (void)didMoveToWindow
{
    %orig;
    @try {
        DSFixEntry(self);
    } @catch (NSException *e) {
    }
}

- (void)layoutSubviews
{
    %orig;
    @try {
        DSFixEntry(self);
    } @catch (NSException *e) {
    }
}

%end

%end

%hook UIViewController

- (void)viewWillAppear:(BOOL)animated
{
    %orig;
    @try {
        if (dsIsMessages && !dsMessagesHooked) {
            dsMessagesHooked = YES;
            %init(MessagesHooks);              // Messages' own classes are loaded by now
        }
        if (dsIsMessages && dsBalTries < 4) {
            dsBalTries++;
            DSInstallBalloonHooks();
        }
        if (DSContains(class_getName(object_getClass(self)), "Transcript")) {
            self.view.backgroundColor = DSTranscriptColor();
        }
        if (dsIsMusic) {
            const char *cn = class_getName(object_getClass(self));
            if (dsHdrTries < 4) {
                dsHdrTries++;
                DSInstallHeaderHooks();
            }
            if (!DSHasPrefix(cn, "UI")) {            // skip plain containers (navigation, tab bar)
                dsDrawMap = !DSContains(cn, "NowPlaying");
            }
        }
        if (dsIsExtra) {
            DSFixNavItem(self.navigationItem);
            DSRecolorNavBar(self.navigationController.navigationBar);
            [self performSelector:@selector(dsRecolorNav) withObject:nil afterDelay:0.05];
            [self performSelector:@selector(dsRecolorNav) withObject:nil afterDelay:0.2];
        }
        if (dsIsMessages) {
            DSFixNavItem(self.navigationItem);
            [[UIApplication sharedApplication] setStatusBarStyle:UIStatusBarStyleBlackOpaque];
            DSRecolorNavBar(self.navigationController.navigationBar);
            [self performSelector:@selector(dsRecolorNav) withObject:nil afterDelay:0.05];
            [self performSelector:@selector(dsRecolorNav) withObject:nil afterDelay:0.2];
        }
    } @catch (NSException *e) {
    }
}

- (void)viewDidAppear:(BOOL)animated
{
    %orig;
    @try {
        if (dsIsMessages || dsIsMusic || dsIsExtra) {
            DSRecolorNavBar(self.navigationController.navigationBar);
            // buttons for a screen that just slid in can finish building a moment later
            [self performSelector:@selector(dsRecolorNav) withObject:nil afterDelay:0.35];
        }
        if (dsIsMessages) {
            [[UIApplication sharedApplication] setStatusBarStyle:UIStatusBarStyleBlackOpaque];
            [self performSelector:@selector(dsRecolorNav) withObject:nil afterDelay:0.8];
            [self performSelector:@selector(dsStyleStatusNow) withObject:nil afterDelay:0.25];
            [self performSelector:@selector(dsStyleStatusNow) withObject:nil afterDelay:1.0];
        }
        if (dsIsMessages && dsMusicDumps < 2 && DSContains(class_getName(object_getClass(self)), "Transcript")) {
            dsMusicDumps++;
            [self performSelector:@selector(dsDumpChat) withObject:nil afterDelay:1.0];
        }
        if (dsIsExtra) {
            [self performSelector:@selector(dsRecolorBarsNow) withObject:nil afterDelay:0.05];
            [self performSelector:@selector(dsRecolorBarsNow) withObject:nil afterDelay:0.35];
            [self performSelector:@selector(dsRecolorBarsNow) withObject:nil afterDelay:0.9];
        }
        if (dsIsExtra && dsMusicDumps < 5) {
            dsMusicDumps++;
            [self performSelector:@selector(dsDumpApp) withObject:nil afterDelay:1.2];
        }
        if (dsIsMusic && dsMusicDumps < 4 && !DSHasPrefix(class_getName(object_getClass(self)), "UI")) {
            dsMusicDumps++;
            [self performSelector:@selector(dsDumpMusic) withObject:nil afterDelay:1.2];
        }
    } @catch (NSException *e) {
    }
}

%new
- (void)dsStyleStatusNow
{
    @try {
        DSStyleStatusWindow();
    } @catch (NSException *e) {
    }
}

%new
- (void)dsDumpChat
{
    @try {
        DSDumpChat();
    } @catch (NSException *e) {
    }
}

%new
- (void)dsDumpApp
{
    @try {
        DSDumpNamed(@"DarkSix-app.txt");
    } @catch (NSException *e) {
    }
}

%new
- (void)dsDumpMusic
{
    @try {
        DSDumpMusic();
    } @catch (NSException *e) {
    }
}

%new
- (void)dsRecolorBarsNow
{
    @try {
        UIWindow *w = self.view.window;
        if (w != nil) {
            DSRecolorBars(w, 0);
        }
    } @catch (NSException *e) {
    }
}

%new
- (void)dsRecolorNav
{
    @try {
        DSRecolorNavBar(self.navigationController.navigationBar);
    } @catch (NSException *e) {
    }
}

%end


// ---------- Messages: blue nav button images -> graphite ----------

%hook UIImageView

- (void)setImage:(UIImage *)image
{
    UIImage *n = image;
    if (dsIsMessages && DSIsNavButtonChild(self)) {
        n = DSNavImage(image);
    } else if (dsIsMusic) {
        n = DSMusicImage(self, image);
    }
    %orig(n);
}

- (void)setHighlightedImage:(UIImage *)image
{
    UIImage *n = image;
    if (dsIsMessages && DSIsNavButtonChild(self)) {
        n = DSNavImage(image);
    } else if (dsIsMusic) {
        n = DSMusicImage(self, image);
    }
    %orig(n);
}

- (void)didMoveToSuperview
{
    %orig;
    @try {
        if (dsIsMessages && DSIsNavButtonChild(self)) {
            UIImage *a = self.image;
            UIImage *b = DSNavImage(a);
            if (b != a) {
                self.image = b;
            }
            UIImage *h = self.highlightedImage;
            UIImage *h2 = DSNavImage(h);
            if (h2 != h) {
                self.highlightedImage = h2;
            }
        } else if (dsIsMusic && self.superview != nil) {
            UIImage *a = self.image;
            UIImage *b = DSMusicImage(self, a);
            if (b != a) {
                self.image = b;
            }
            UIImage *h = self.highlightedImage;
            UIImage *h2 = DSMusicImage(self, h);
            if (h2 != h) {
                self.highlightedImage = h2;
            }
        }
    } @catch (NSException *e) {
    }
}

%end



// ---------- Messages: back button is drawn in code, recolor its pictures as they are drawn ----------

// is this picture a light, nearly colorless surface (a Calendar tile or bar)?
static NSMutableDictionary *dsLightCache = nil;

static BOOL DSImageIsLight(CGImageRef img) {
    if (img == NULL) return NO;
    if (dsLightCache == nil) {
        dsLightCache = [[NSMutableDictionary alloc] init];
    }
    NSValue *key = [NSValue valueWithPointer:img];
    NSArray *e = [dsLightCache objectForKey:key];
    if (e != nil) {
        return [[e objectAtIndex:1] boolValue];
    }
    BOOL light = NO;
    unsigned char px[4] = {0, 0, 0, 0};
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef bc = CGBitmapContextCreate(px, 1, 1, 8, 4, cs, kCGImageAlphaPremultipliedLast);
    if (bc != NULL) {
        CGContextSetInterpolationQuality(bc, kCGInterpolationMedium);
        CGContextDrawImage(bc, CGRectMake(0, 0, 1, 1), img);
        CGFloat a = px[3] / 255.0;
        if (a > 0.85) {
            CGFloat r = px[0] / 255.0 / a, g = px[1] / 255.0 / a, b = px[2] / 255.0 / a;
            CGFloat mx = MAX(r, MAX(g, b)), mn = MIN(r, MIN(g, b));
            CGFloat lum = 0.299 * r + 0.587 * g + 0.114 * b;
            light = (lum > 0.62 && (mx - mn) < 0.14);
        }
        CGContextRelease(bc);
    }
    CGColorSpaceRelease(cs);
    [dsLightCache setObject:[NSArray arrayWithObjects:(id)img, [NSNumber numberWithBool:light], nil] forKey:key];
    return light;
}

// ---------- Calendar: darken light bars, tiles and pages by walking the screen ----------

// small icon-sized surfaces (status bar battery/signal, tiny buttons) are never recolored
static BOOL DSSmallClip(CGContextRef c) {
    CGRect r = CGContextGetClipBoundingBox(c);
    return r.size.height <= 24 && r.size.width <= 100;
}

static BOOL DSSmallLayer(CALayer *l) {
    CGSize z = l.bounds.size;
    return z.width <= 100 && z.height <= 24;
}

static NSMutableDictionary *dsDarkCache = nil;

// a darkened copy of a picture (the picture drawn, then black laid over it); +1 retained, or NULL
static CGImageRef DSDarkCGImageCreate(CGImageRef src, CGFloat alpha) {
    size_t w = CGImageGetWidth(src), h = CGImageGetHeight(src);
    if (w == 0 || h == 0 || w > 2048 || h > 2048) return NULL;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef bc = CGBitmapContextCreate(NULL, w, h, 8, 0, cs, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (bc == NULL) return NULL;
    BOOL prev = dsInHook;
    dsInHook = YES;
    CGContextDrawImage(bc, CGRectMake(0, 0, w, h), src);
    dsInHook = prev;
    CGContextSetBlendMode(bc, kCGBlendModeSourceAtop);
    CGContextSetGrayFillColor(bc, 0.0, alpha);
    CGContextFillRect(bc, CGRectMake(0, 0, w, h));
    CGImageRef out = CGBitmapContextCreateImage(bc);
    CGContextRelease(bc);
    return out;
}

// returns the darkened picture, or src itself when it is not a light surface
static CGImageRef DSDarkCGImage(CGImageRef src, CGFloat alpha) {
    if (src == NULL) return src;
    if (dsDarkCache == nil) {
        dsDarkCache = [[NSMutableDictionary alloc] init];
    }
    NSString *key = [NSString stringWithFormat:@"%p/%.2f", src, alpha];
    NSArray *e = [dsDarkCache objectForKey:key];
    if (e == nil) {
        CGImageRef out = NULL;
        BOOL prev = dsInHook;
        dsInHook = YES;
        BOOL light = DSImageIsLight(src);
        dsInHook = prev;
        if (light) {
            out = DSDarkCGImageCreate(src, alpha);
        }
        id second = (out != NULL) ? (id)out : (id)[NSNull null];
        e = [NSArray arrayWithObjects:(id)src, second, nil];     // keeps src alive so the key stays valid
        [dsDarkCache setObject:e forKey:key];
        if (out != NULL) {
            CGImageRelease(out);
        }
    }
    id r2 = [e objectAtIndex:1];
    return (r2 == [NSNull null]) ? src : (CGImageRef)r2;
}

static BOOL DSCalLightColor(CGColorRef c, CGFloat *lumOut) {
    if (c == NULL) return NO;
    size_t n = CGColorGetNumberOfComponents(c);
    const CGFloat *p = CGColorGetComponents(c);
    CGFloat r, g, b, a;
    if (n == 2) { r = g = b = p[0]; a = p[1]; }
    else if (n == 4) { r = p[0]; g = p[1]; b = p[2]; a = p[3]; }
    else return NO;
    if (a < 0.5) return NO;
    CGFloat mx = MAX(r, MAX(g, b)), mn = MIN(r, MIN(g, b));
    CGFloat lum = 0.299 * r + 0.587 * g + 0.114 * b;
    if (lumOut != NULL) *lumOut = lum;
    return (mx - mn) < 0.2 && lum > 0.6;
}

static void DSCalLayer(CALayer *l, CGFloat barH) {
    if (DSSmallLayer(l)) return;
    // picture on the layer
    id c = l.contents;
    if (c != nil && CFGetTypeID((CFTypeRef)c) == CGImageGetTypeID()) {
        CGFloat lh = l.bounds.size.height;
        CGFloat a = (lh <= 8) ? 0.93 : ((lh <= 30) ? 0.55 : 0.86);
        CGImageRef d = DSDarkCGImage((CGImageRef)c, a);
        if (d != (CGImageRef)c) {
            l.contents = (id)d;
        }
    }
    if ([l isKindOfClass:[CAGradientLayer class]]) {
        CAGradientLayer *gl = (CAGradientLayer *)l;
        NSArray *cols = gl.colors;
        BOOL any = NO;
        NSMutableArray *nc = [NSMutableArray array];
        for (id col in cols) {
            CGColorRef cc = (CGColorRef)col;
            if (cc != NULL && CFGetTypeID(cc) == CGColorGetTypeID() && DSCalLightColor(cc, NULL)) {
                [nc addObject:(id)[UIColor colorWithWhite:(barH <= 30 ? 0.36 : 0.06) alpha:1.0].CGColor];
                any = YES;
            } else {
                [nc addObject:col];
            }
        }
        if (any) gl.colors = nc;
    }
}

static void DSCalWalk(UIView *v, int depth) {
    if (v == nil || depth > 14) return;
    const char *n = class_getName(object_getClass(v));
    if (DSHasPrefix(n, "UIToolbar") || DSHasPrefix(n, "UINavigationBar") || DSHasPrefix(n, "UISearchBar") ||
        DSHasPrefix(n, "UITabBar") || DSHasPrefix(n, "UISegment") || DSHasPrefix(n, "UIButton") ||
        DSHasPrefix(n, "UITextField") || DSHasPrefix(n, "UIStatusBar") || DSAvoid(v)) {
        return;
    }
    CGFloat h = v.bounds.size.height, w = v.bounds.size.width;
    BOOL isBar = (h > 0 && h <= 30 && w >= 200);
    if ([v isKindOfClass:[UILabel class]]) {
        UILabel *sl = (UILabel *)v;
        UIColor *sc = sl.shadowColor;
        if (sc != nil && sc.CGColor != NULL) {
            CGColorRef scg = sc.CGColor;
            size_t scn = CGColorGetNumberOfComponents(scg);
            const CGFloat *scp = CGColorGetComponents(scg);
            CGFloat sr = scp[0], sgc = (scn >= 3 ? scp[1] : scp[0]), sb2 = (scn >= 3 ? scp[2] : scp[0]);
            CGFloat sa2 = scp[scn - 1];
            CGFloat smx = MAX(sr, MAX(sgc, sb2)), smn = MIN(sr, MIN(sgc, sb2));
            BOOL already = (smx < 0.12 && (smx - smn) < 0.05 && sa2 <= 0.75);
            if (!already && sa2 > 0.02) {
                sl.shadowColor = [UIColor colorWithWhite:0.08 alpha:0.7];     // soft, very dark gray
            }
        }
        UIView *sp = v.superview;
        if (sp != nil && sp.bounds.size.height <= 30 && sp.bounds.size.width >= 200) {
            // day divider text: white with a dark gray shadow (not a white glow)
            UILabel *lb = (UILabel *)v;
            CGFloat lum = 0;
            if (lb.textColor != nil && DSCalLightColor(lb.textColor.CGColor, &lum)) {
                lb.shadowColor = [UIColor colorWithWhite:0.12 alpha:1.0];
                lb.shadowOffset = CGSizeMake(0, -1);
            }
        }
    }

    UIColor *bg = v.backgroundColor;
    if (bg != nil && bg.CGColor != NULL && CGColorGetPattern(bg.CGColor) != NULL &&
        ![v isKindOfClass:[UILabel class]] && w >= 100 && h >= 100) {
        v.backgroundColor = [UIColor blackColor];                 // a big picture-pattern page (the day timeline)
    } else if (bg != nil && bg.CGColor != NULL && ![v isKindOfClass:[UILabel class]]) {
        CGFloat lum = 0;
        if (DSCalLightColor(bg.CGColor, &lum)) {
            v.backgroundColor = [UIColor colorWithWhite:(isBar ? 0.36 : 0.0) alpha:1.0];
        } else if (w >= 200 && h >= 200 && lum > 0.15 && lum < 0.5) {
            CGColorRef cg = bg.CGColor;
            size_t nc = CGColorGetNumberOfComponents(cg);
            const CGFloat *pp = CGColorGetComponents(cg);
            CGFloat a = (nc == 2) ? pp[1] : (nc == 4 ? pp[3] : 0);
            if (a > 0.5) {
                v.backgroundColor = [UIColor blackColor];     // the mid-gray page of the day timeline
            }
        }
    }
    DSCalLayer(v.layer, isBar ? 20 : 100);
    for (CALayer *sl in [NSArray arrayWithArray:v.layer.sublayers]) {
        if (![sl.delegate isKindOfClass:[UIView class]]) {
            DSCalLayer(sl, isBar ? 20 : 100);
        }
    }
    if ([v isKindOfClass:[UIImageView class]]) {
        UIImageView *iv = (UIImageView *)v;
        UIImage *im = iv.image;
        if (im != nil && im.CGImage != NULL && h >= 1 && !DSSmallLayer(iv.layer)) {
            CGFloat a = (h <= 8) ? 0.93 : ((h <= 30) ? 0.55 : 0.86);
            CGImageRef d = DSDarkCGImage(im.CGImage, a);
            if (d != im.CGImage) {
                UIImage *ni = [UIImage imageWithCGImage:d scale:im.scale orientation:im.imageOrientation];
                UIEdgeInsets ci = im.capInsets;
                if (ci.top > 0 || ci.left > 0 || ci.bottom > 0 || ci.right > 0) {
                    ni = [ni resizableImageWithCapInsets:ci];
                }
                iv.image = ni;
            }
        }
    }
    NSArray *subs = [NSArray arrayWithArray:v.subviews];
    for (UIView *x in subs) {
        DSCalWalk(x, depth + 1);
    }
}

static int dsCalTickCount = 0;
static int dsCalDumps = 0;

static void DSCalTick(void) {
    dsCalTickCount++;
    if (dsCalTickCount % 17 == 0 && dsCalDumps < 10) {
        dsCalDumps++;
        DSDumpNamed(@"DarkSix-app.txt");
    }
    @try {
        for (UIWindow *w in [[UIApplication sharedApplication] windows]) {
            DSCalWalk(w, 0);
        }
    } @catch (NSException *e) {
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        DSCalTick();
    });
}

// Calendar: darken light pictures the moment they are put on a layer (no light flash when switching tabs)
static BOOL DSLayerInStatusBar(CALayer *l) {
    id d = l.delegate;
    int n = 0;
    while (d != nil && n < 6) {
        if (![d isKindOfClass:[UIView class]]) return NO;
        if (DSHasPrefix(class_getName(object_getClass(d)), "UIStatusBar")) return YES;
        d = ((UIView *)d).superview;
        n++;
    }
    return NO;
}

%hook UIStatusBarItemView

- (void)drawRect:(CGRect)rect
{
    BOOL prev = dsInStatusDraw;
    dsInStatusDraw = YES;
    %orig(rect);
    dsInStatusDraw = prev;
}

%end

static UIImage *DSLightToDarkImage(UIImage *src);

%hook CALayer

- (void)setContents:(id)contents
{
    id use = contents;
    if (dsIsSettings && !dsInHook && contents != nil && CFGetTypeID((CFTypeRef)contents) == CGImageGetTypeID() && [self.delegate isKindOfClass:NSClassFromString(@"UIGroupTableViewCellBackground")]) {
        UIImage *dk = DSLightToDarkImage([UIImage imageWithCGImage:(CGImageRef)contents]);
        if (dk.CGImage != NULL) use = (id)dk.CGImage;
    }
    if (dsIsCal && !dsInHook && contents != nil && CFGetTypeID((CFTypeRef)contents) == CGImageGetTypeID() && !DSLayerInStatusBar(self) && !DSSmallLayer(self)) {
        CGFloat lh = self.bounds.size.height;
        id d = (id)DSDarkCGImage((CGImageRef)contents, (lh > 0 && lh <= 8) ? 0.93 : ((lh > 0 && lh <= 30) ? 0.55 : 0.86));
        if (d != nil) use = d;
    }
    if (!dsInHook && contents != nil && CFGetTypeID((CFTypeRef)contents) == CGImageGetTypeID() && DSLayerInKeyboard(self)) {
        CGImageRef kb = DSKeyboardImage((CGImageRef)contents);
        if (kb != NULL) use = (id)kb;
    }
    if (dsIsMessages && !dsInHook && contents != nil && CFGetTypeID((CFTypeRef)contents) == CGImageGetTypeID() && DSLayerInBalloon(self)) {
        CGImageRef b = DSBubbleImage((CGImageRef)contents);
        if (b != NULL) use = (id)b;
    }
    %orig(use);
}

%end

// Calendar month digits: small slate-gray pictures with a soft edge -> white glyphs like the selected day
static NSMutableDictionary *dsCalGlyphCache = nil;

static void DSCalLog(NSString *line) {
    static int count = 0;
    if (count > 250) return;
    count++;
    DSWriteDiag(@"DarkSix-cal.txt", line, YES);
}

// returns a white copy of a dull, partly transparent small picture (+1 retained) or NULL when it is not one
static CGImageRef DSWhiteGlyphCreate(CGImageRef img, CGFloat *infoA, CGFloat *infoL, CGFloat *infoS) {
    size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
    if (w < 4 || h < 4 || w > 160 || h > 160) return NULL;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef bc = CGBitmapContextCreate(NULL, w, h, 8, 0, cs, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (bc == NULL) return NULL;
    BOOL prev = dsInHook;
    dsInHook = YES;
    CGContextDrawImage(bc, CGRectMake(0, 0, w, h), img);
    dsInHook = prev;
    unsigned char *d = (unsigned char *)CGBitmapContextGetData(bc);
    size_t bpr = CGBitmapContextGetBytesPerRow(bc);
    double sa = 0, sr = 0, sg = 0, sb = 0;
    size_t cnt = 0;
    for (size_t y = 0; y < h; y++) {
        for (size_t x = 0; x < w; x++) {
            unsigned char *px = d + y * bpr + x * 4;
            if (px[3] > 20) {
                sr += px[0] * 255.0 / px[3];
                sg += px[1] * 255.0 / px[3];
                sb += px[2] * 255.0 / px[3];
                cnt++;
            }
            sa += px[3];
        }
    }
    CGImageRef out = NULL;
    if (cnt > 0) {
        double avgA = sa / (255.0 * w * h);
        double r = sr / cnt / 255.0, g = sg / cnt / 255.0, b = sb / cnt / 255.0;
        double mx = MAX(r, MAX(g, b)), mn = MIN(r, MIN(g, b));
        double lum = 0.299 * r + 0.587 * g + 0.114 * b;
        double sat = (mx > 0) ? (mx - mn) / mx : 0;
        if (infoA) *infoA = avgA;
        if (infoL) *infoL = lum;
        if (infoS) *infoS = sat;
        // a glyph: mostly transparent, dull and not light, not saturated
        if (avgA < 0.8 && lum > 0.12 && lum < 0.7 && sat < 0.5) {
            CGContextSetBlendMode(bc, kCGBlendModeSourceAtop);
            CGContextSetGrayFillColor(bc, 1.0, 0.95);
            CGContextFillRect(bc, CGRectMake(0, 0, w, h));
            out = CGBitmapContextCreateImage(bc);
        }
    }
    CGContextRelease(bc);
    return out;
}

static CGImageRef DSWhiteGlyph(CGImageRef src) {
    if (src == NULL) return NULL;
    if (dsCalGlyphCache == nil) {
        dsCalGlyphCache = [[NSMutableDictionary alloc] init];
    }
    NSValue *key = [NSValue valueWithPointer:src];
    NSArray *e = [dsCalGlyphCache objectForKey:key];
    if (e == nil) {
        CGFloat a = -1, l = -1, sat = -1;
        CGImageRef out = DSWhiteGlyphCreate(src, &a, &l, &sat);
        DSCalLog([NSString stringWithFormat:@"image %zux%zu alpha %.2f lum %.2f sat %.2f -> %@\n",
                  CGImageGetWidth(src), CGImageGetHeight(src), a, l, sat, (out != NULL ? @"white glyph" : @"left alone")]);
        id second = (out != NULL) ? (id)out : (id)[NSNull null];
        e = [NSArray arrayWithObjects:(id)src, second, nil];
        [dsCalGlyphCache setObject:e forKey:key];
        if (out != NULL) CGImageRelease(out);
    }
    id r2 = [e objectAtIndex:1];
    return (r2 == [NSNull null]) ? NULL : (CGImageRef)r2;
}

%group BackHooks

%hook UINavigationItemButtonView

- (void)drawRect:(CGRect)rect
{
    dsInBackDraw = YES;
    %orig(rect);
    dsInBackDraw = NO;
}

%end

%hookf(void, CGContextClipToMask, CGContextRef c, CGRect rect, CGImageRef mask)
{
    if (dsIsCal) {
        DSCalLog([NSString stringWithFormat:@"clipToMask rect %@\n", NSStringFromCGRect(rect)]);
    }
    %orig(c, rect, mask);
}

%hookf(void, CGContextDrawImage, CGContextRef c, CGRect rect, CGImageRef image)
{
    if (dsInKeyboardDraw && !dsInHook && image != NULL) {
        CGImageRef kb = DSKeyboardImage(image);
        if (kb != NULL) {
            %orig(c, rect, kb);
            return;
        }
    }
    if (dsIsMessages && dsInBalloonDraw && !dsInHook && image != NULL) {
        CGImageRef bb = DSBubbleImage(image);
        if (bb != NULL) {
            %orig(c, rect, bb);
            return;
        }
    }
    if (dsInMusicCell && rect.size.height <= 3.0 && rect.size.width >= 200.0) {
        return;                      // Music's own white divider picture
    }
    if (dsIsCal && !dsInStatusDraw && !dsInHook && image != NULL && !DSSmallClip(c) && rect.size.width >= 4 && rect.size.width <= 90 && rect.size.height <= 90) {
        CGImageRef gl = DSWhiteGlyph(image);
        if (gl != NULL) {
            CGContextSaveGState(c);
            CGContextSetShadowWithColor(c, CGSizeMake(0, -1), 1.0, [UIColor colorWithWhite:0.08 alpha:0.7].CGColor);
            %orig(c, rect, gl);
            CGContextRestoreGState(c);
            return;
        }
    }
    if (dsIsCal && !dsInStatusDraw && !dsInHook && image != NULL && !DSSmallClip(c) && rect.size.width >= 8 && rect.size.height >= 8) {
        dsInHook = YES;
        BOOL light = DSImageIsLight(image);
        dsInHook = NO;
        if (light) {
            // light gray tiles and bars (month grid, headers): draw them, then darken what was drawn
            %orig(c, rect, image);
            CGContextSaveGState(c);
            CGContextSetBlendMode(c, kCGBlendModeSourceAtop);
            CGContextSetGrayFillColor(c, 0.0, 0.84);
            CGContextFillRect(c, rect);
            CGContextRestoreGState(c);
            return;
        }
    }
    if (dsIsMusic && dsDrawMap && !dsInHook && !dsInBackDraw && !dsInBarBgDraw && image != NULL) {
        dsInHook = YES;
        CGImageRef gl = DSMusicDrawnGlyph(image);
        dsInHook = NO;
        if (gl != NULL) {
            %orig(c, rect, gl);
            return;
        }
    }
    if ((dsInBackDraw || dsInBarBgDraw) && !dsInHook && image != NULL) {
        dsInHook = YES;
        CGFloat savedSat = dsSatMin;
        dsSatMin = dsInBarBgDraw ? 0.08 : 0.12;
        CGImageRef g = DSGraphiteCGImageCreate(image);
        dsSatMin = savedSat;
        dsInHook = NO;
        if (g != NULL) {
            %orig(c, rect, g);
            CGImageRelease(g);
            return;
        }
    }
    %orig(c, rect, image);
}

%end

// ---------- Messages: temporary nav bar background flashes blue during push/pop ----------

static void DSNavBgDraw(id self, SEL _cmd, CGRect rect) {
    BOOL mine = (dsNavBgClass != Nil && [self isKindOfClass:dsNavBgClass]);
    BOOL prev = dsInBarBgDraw;
    if (mine) {
        dsInBarBgDraw = YES;
    }
    if (dsOrigBgDraw != NULL) {
        ((void (*)(id, SEL, CGRect))dsOrigBgDraw)(self, _cmd, rect);
    }
    dsInBarBgDraw = prev;
}

static void DSInstallNavBgHook(void) {
    dsNavBgClass = NSClassFromString(@"_UINavigationBarBackground");
    if (dsNavBgClass == Nil) return;
    Method m = class_getInstanceMethod(dsNavBgClass, @selector(drawRect:));
    Method um = class_getInstanceMethod([UIView class], @selector(drawRect:));
    // only if the class really draws itself; otherwise adding a drawRect: would blank it
    if (m != NULL && um != NULL && method_getImplementation(m) != method_getImplementation(um)) {
        dsOrigBgDraw = method_getImplementation(m);
        method_setImplementation(m, (IMP)DSNavBgDraw);
    }
}

// ---------- Music: section header bars that draw their own text ----------

static NSMutableDictionary *dsHdrOrig = nil;

static void DSHeaderDraw(id self, SEL _cmd, CGRect rect) {
    IMP orig = NULL;
    for (Class k = object_getClass(self); k != Nil && orig == NULL; k = class_getSuperclass(k)) {
        NSValue *v = [dsHdrOrig objectForKey:[NSValue valueWithPointer:(const void *)k]];
        if (v != nil) {
            orig = (IMP)[v pointerValue];
        }
    }
    BOOL prev = dsInHeaderDraw;
    dsInHeaderDraw = YES;
    if (orig != NULL) {
        ((void (*)(id, SEL, CGRect))orig)(self, _cmd, rect);
    }
    dsInHeaderDraw = prev;
}

static void DSInstallHeaderHooks(void) {
    if (dsHdrOrig == nil) {
        dsHdrOrig = [[NSMutableDictionary alloc] init];
    }
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    NSMutableData *buf = [NSMutableData dataWithLength:sizeof(Class) * count];
    Class *list = (Class *)[buf mutableBytes];
    count = objc_getClassList(list, count);
    Class uiview = [UIView class];
    for (int i = 0; i < count; i++) {
        Class k = list[i];
        const char *n = class_getName(k);
        if (!(DSContains(n, "SectionHeader") || DSContains(n, "HeaderFooter") || DSHasPrefix(n, "UITableViewHeaderView"))) continue;
        BOOL isView = NO;
        for (Class s2 = k; s2 != Nil; s2 = class_getSuperclass(s2)) {
            if (s2 == uiview) {
                isView = YES;
                break;
            }
        }
        if (!isView) continue;
        NSValue *key = [NSValue valueWithPointer:(const void *)k];
        if ([dsHdrOrig objectForKey:key] != nil) continue;
        unsigned int mc = 0;
        Method *ms = class_copyMethodList(k, &mc);
        Method own = NULL;
        for (unsigned int j = 0; j < mc; j++) {
            if (method_getName(ms[j]) == @selector(drawRect:)) {
                own = ms[j];
                break;
            }
        }
        if (own != NULL) {
            [dsHdrOrig setObject:[NSValue valueWithPointer:(const void *)method_getImplementation(own)] forKey:key];
            method_setImplementation(own, (IMP)DSHeaderDraw);
        }
        if (ms != NULL) {
            free(ms);
        }
    }
}

// ---------- Messages: text drawn by the balloon itself is white ----------

static void DSBalloonInk(void) {
    if (!dsInBalloonDraw) return;
    CGContextRef c = UIGraphicsGetCurrentContext();
    if (c != NULL) {
        CGContextSetGrayFillColor(c, 1.0, 1.0);
    }
}

%group BalloonText

%hook NSString

- (CGSize)drawAtPoint:(CGPoint)point withFont:(UIFont *)font
{
    DSBalloonInk();
    return %orig(point, font);
}

- (CGSize)drawInRect:(CGRect)rect withFont:(UIFont *)font
{
    DSBalloonInk();
    return %orig(rect, font);
}

- (CGSize)drawInRect:(CGRect)rect withFont:(UIFont *)font lineBreakMode:(NSLineBreakMode)mode
{
    DSBalloonInk();
    return %orig(rect, font, mode);
}

- (CGSize)drawInRect:(CGRect)rect withFont:(UIFont *)font lineBreakMode:(NSLineBreakMode)mode alignment:(NSTextAlignment)alignment
{
    DSBalloonInk();
    return %orig(rect, font, mode, alignment);
}

%end

%end

// apps where the other drawing hooks are not installed still need the keyboard picture hook
%group KeyboardDraw

%hookf(void, CGContextDrawImage, CGContextRef c, CGRect rect, CGImageRef image)
{
    if (dsInKeyboardDraw && !dsInHook && image != NULL) {
        CGImageRef kb = DSKeyboardImage(image);
        if (kb != NULL) {
            %orig(c, rect, kb);
            return;
        }
    }
    %orig(c, rect, image);
}

%end

// ---------- Home screen icons (inside SpringBoard) ----------
// The icon SpringBoard hands out for an app (rounded, with gloss) is recolored: the colored background goes black and
// the shape takes the color, so Messages becomes a green bubble on black. Done in memory, nothing is written to disk.

typedef struct { const char *bid; int mode; } DSIconRule;

// 1 = white shape on colour -> colour shape on black   2 = dark shape on colour -> colour shape on black
// 3 = plain edge background goes black, picture stays  4 = paper icons light <-> dark   5 = darker
// Left alone: Compass, Calendar (SpringBoard draws the date on it), Clock, Stocks, Calculator, Videos, Contacts, Passbook.
static const DSIconRule dsIconRules[] = {
    {"com.apple.MobileSMS", 1}, {"com.apple.mobilephone", 1}, {"com.apple.mobilemail", 1}, {"com.apple.facetime", 1},
    {"com.apple.AppStore", 11}, {"com.apple.MobileStore", 11},
    {"com.apple.mobileipod", 2},
    {"com.apple.mobilesafari", 3}, {"com.apple.mobileslideshow", 3}, {"com.apple.camera", 3}, {"com.apple.VoiceMemos", 3},
    {"com.apple.Preferences", 8}, {"com.apple.weather", 7},
    {"com.apple.newsstand", 5},
    {NULL, 0}
};

static NSMutableDictionary *dsIconCache = nil;     // source image pointer -> [source, result]
static NSMutableSet *dsIconOutputs = nil;          // pointers of the images we made (never process them twice)

static int DSIconModeFor(NSString *bid) {
    if (bid == nil) return 0;
    const char *b = [bid UTF8String];
    for (int i = 0; dsIconRules[i].bid != NULL; i++) {
        if (strcmp(dsIconRules[i].bid, b) == 0) return dsIconRules[i].mode;
    }
    return 0;
}

static UIImage *DSMakeDarkIcon(UIImage *src, int mode) {
    CGImageRef cg = src.CGImage;
    if (cg == NULL) return nil;
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    if (w < 50 || w > 220 || h < 50 || h > 220) return nil;   // only Home screen sizes (the picture can carry a few extra rows, e.g. 118 x 124)
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef bc = CGBitmapContextCreate(NULL, w, h, 8, w * 4, cs, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (bc == NULL) return nil;
    CGContextDrawImage(bc, CGRectMake(0, 0, w, h), cg);
    unsigned char *px = (unsigned char *)CGBitmapContextGetData(bc);
    size_t rb = CGBitmapContextGetBytesPerRow(bc);
    UIImage *result = nil;
    if (px != NULL) {
        // find the icon itself inside the picture (the picture can be a little larger than the icon)
        size_t minx = w, maxx = 0, miny = h, maxy = 0;
        for (size_t y = 0; y < h; y++) {
            unsigned char *row = px + y * rb;
            for (size_t x = 0; x < w; x++) {
                if (row[x * 4 + 3] > 128) {
                    if (x < minx) minx = x;
                    if (x > maxx) maxx = x;
                    if (y < miny) miny = y;
                    if (y > maxy) maxy = y;
                }
            }
        }
        size_t cw = (maxx >= minx) ? maxx - minx + 1 : 0, ch = (maxy >= miny) ? maxy - miny + 1 : 0;
        if (cw >= 48 && ch >= 48) {
            unsigned char *tight = (unsigned char *)malloc(cw * ch * 4);
            if (tight != NULL) {
                for (size_t y = 0; y < ch; y++) memcpy(tight + y * cw * 4, px + (miny + y) * rb + minx * 4, cw * 4);
                ds_process(tight, (int)cw, (int)ch, mode);
                for (size_t y = 0; y < ch; y++) memcpy(px + (miny + y) * rb + minx * 4, tight + y * cw * 4, cw * 4);
                free(tight);
                CGImageRef out = CGBitmapContextCreateImage(bc);
                if (out != NULL) {
                    result = [UIImage imageWithCGImage:out scale:src.scale orientation:UIImageOrientationUp];
                    CGImageRelease(out);
                }
            }
        }
    }
    CGContextRelease(bc);
    return result;
}


// Brand-new dark icon set shipped with DarkSix: /usr/share/DarkSix/icons/<bundle id>.png (114x114, rounded, glossy, already finished).
// The new picture is drawn into the exact spot of the icon SpringBoard handed out, so any size works.
static UIImage *DSCustomIcon(UIImage *src, NSString *bid) {
    if (bid == nil) return nil;
    CGImageRef cg = src.CGImage;
    if (cg == NULL) return nil;
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    if (w < 50 || w > 220 || h < 50 || h > 220) return nil;
    NSString *path = [NSString stringWithFormat:@"/usr/share/DarkSix/icons/%@.png", bid];
    UIImage *art = [UIImage imageWithContentsOfFile:path];
    if (art == nil || art.CGImage == NULL) return nil;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef bc = CGBitmapContextCreate(NULL, w, h, 8, w * 4, cs, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (bc == NULL) return nil;
    CGContextDrawImage(bc, CGRectMake(0, 0, w, h), cg);
    unsigned char *px = (unsigned char *)CGBitmapContextGetData(bc);
    size_t rb = CGBitmapContextGetBytesPerRow(bc);
    UIImage *result = nil;
    if (px != NULL) {
        size_t minx = w, maxx = 0, miny = h, maxy = 0;
        for (size_t y = 0; y < h; y++) {
            unsigned char *row = px + y * rb;
            for (size_t x = 0; x < w; x++) {
                if (row[x * 4 + 3] > 128) {
                    if (x < minx) minx = x;
                    if (x > maxx) maxx = x;
                    if (y < miny) miny = y;
                    if (y > maxy) maxy = y;
                }
            }
        }
        size_t cw = (maxx >= minx) ? maxx - minx + 1 : 0, ch = (maxy >= miny) ? maxy - miny + 1 : 0;
        if (cw >= 48 && ch >= 48) {
            CGContextClearRect(bc, CGRectMake(0, 0, w, h));
            CGContextSetInterpolationQuality(bc, kCGInterpolationHigh);
            // bitmap origin is bottom-left; rows were counted from the top
            CGContextDrawImage(bc, CGRectMake(minx, h - (miny + ch), cw, ch), art.CGImage);
            CGImageRef out = CGBitmapContextCreateImage(bc);
            if (out != NULL) {
                result = [UIImage imageWithCGImage:out scale:src.scale orientation:UIImageOrientationUp];
                CGImageRelease(out);
            }
        }
    }
    CGContextRelease(bc);
    return result;
}

static id DSIconBundleID(id icon) {
    if ([icon respondsToSelector:@selector(applicationBundleID)]) {
        return [icon performSelector:@selector(applicationBundleID)];
    }
    if ([icon respondsToSelector:@selector(application)]) {
        id app = [icon performSelector:@selector(application)];
        if ([app respondsToSelector:@selector(displayIdentifier)]) {
            return [app performSelector:@selector(displayIdentifier)];
        }
        if ([app respondsToSelector:@selector(bundleIdentifier)]) {
            return [app performSelector:@selector(bundleIdentifier)];
        }
    }
    return nil;
}

static void DSIconLog(NSString *line);
static NSObject *dsIconLock = nil;
static UIImage *DSIconFor(id icon, UIImage *img) {
    if (!dsOptIcons || img == nil || ![img isKindOfClass:[UIImage class]]) return img;
    @try {
      @synchronized(dsIconLock) {
        if (dsIconOutputs == nil) {
            dsIconOutputs = [[NSMutableSet alloc] init];
            dsIconCache = [[NSMutableDictionary alloc] init];
        }
        NSValue *pv = [NSValue valueWithPointer:(const void *)img];
        if ([dsIconOutputs containsObject:pv]) return img;
        NSArray *hit = [dsIconCache objectForKey:pv];
        if (hit != nil) {
            id r = [hit objectAtIndex:1];
            return (r == [NSNull null]) ? img : (UIImage *)r;
        }
        id bid = DSIconBundleID(icon);
        int mode = ([bid isKindOfClass:[NSString class]]) ? DSIconModeFor((NSString *)bid) : 0;
        UIImage *out = nil;
        if ([bid isKindOfClass:[NSString class]]) out = DSCustomIcon(img, (NSString *)bid);
        if (out == nil && mode != 0) out = DSMakeDarkIcon(img, mode);
        DSIconLog([NSString stringWithFormat:@"icon %@ mode %d size %.0fx%.0f scale %.0f -> %@\n", bid, mode, img.size.width, img.size.height, img.scale, (out != nil ? @"dark" : @"unchanged")]);
        if ([dsIconCache count] > 400) {
            [dsIconCache removeAllObjects];
            [dsIconOutputs removeAllObjects];
        }
        [dsIconCache setObject:[NSArray arrayWithObjects:img, (out != nil ? (id)out : (id)[NSNull null]), nil] forKey:pv];
        if (out != nil) {
            [dsIconOutputs addObject:[NSValue valueWithPointer:(const void *)out]];
            return out;
        }
      }
    } @catch (NSException *e) {
    }
    return img;
}

static NSMutableDictionary *dsIconOrig = nil;      // "class|selector" -> original IMP

static void DSIconLog(NSString *line) {
    static int count = 0;
    if (count > 80) return;
    count++;
    DSWriteDiag(@"DarkSix-icons.txt", line, YES);
}

static void DSInstallIconHooks(void) {
    if (dsIconOrig == nil) dsIconOrig = [[NSMutableDictionary alloc] init];
    if (dsIconLock == nil) dsIconLock = [[NSObject alloc] init];
    Class base = NSClassFromString(@"SBIcon");
    if (base == Nil) {
        DSIconLog(@"SBIcon class not found\n");
        return;
    }
    SEL sels[3] = { @selector(getIconImage:), @selector(generateIconImage:), @selector(getCachedIconImage:) };
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    NSMutableData *buf = [NSMutableData dataWithLength:sizeof(Class) * count];
    Class *list = (Class *)[buf mutableBytes];
    count = objc_getClassList(list, count);
    for (int i = 0; i < count; i++) {
        Class k = list[i];
        BOOL isIcon = NO;
        for (Class s2 = k; s2 != Nil; s2 = class_getSuperclass(s2)) {
            if (s2 == base) {
                isIcon = YES;
                break;
            }
        }
        if (!isIcon) continue;
        unsigned int mc = 0;
        Method *ms = class_copyMethodList(k, &mc);
        for (unsigned int j = 0; j < mc; j++) {
            for (int q = 0; q < 3; q++) {
                if (method_getName(ms[j]) != sels[q]) continue;
                NSString *key = [NSString stringWithFormat:@"%p|%s", k, sel_getName(sels[q])];
                if ([dsIconOrig objectForKey:key] != nil) continue;
                [dsIconOrig setObject:@"1" forKey:key];
                IMP orig = method_getImplementation(ms[j]);
                SEL theSel = sels[q];
                // every hook carries its own original, so a subclass calling super can never loop
                IMP repl = imp_implementationWithBlock(^id(id selfObj, int type) {
                    id r = ((id (*)(id, SEL, int))orig)(selfObj, theSel, type);
                    return DSIconFor(selfObj, (UIImage *)r);
                });
                method_setImplementation(ms[j], repl);
                DSIconLog([NSString stringWithFormat:@"hooked -[%s %s]\n", class_getName(k), sel_getName(sels[q])]);
            }
        }
        if (ms != NULL) free(ms);
    }
}

// ---------- Dark Notification Center (inside SpringBoard) ----------
// When the "darknc" setting is on, the linen behind the Notification Center gets a dark layer on top.
// The setting is read every time Notification Center opens, so the Flipswitch toggle works without a respring.
#define DS_NC_TAG 0xD5A1
static BOOL DSNCEnabled(void) {
    NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.example.darksix.plist"];
    id v = [p objectForKey:@"darknc"];
    return (v != nil) && [v boolValue];
}
static void DSNCLog(NSString *line) {
    if (!DSDebugOn()) return;
    static int n = 0;
    if (n++ > 400) return;
    DSWriteDiag(@"DarkSix-nc.txt", line, YES);
    NSString *plain = @"/var/mobile/Library/Caches/DarkSix-nc.txt";
    NSString *old = [NSString stringWithContentsOfFile:plain encoding:NSUTF8StringEncoding error:NULL];
    [(old != nil ? [old stringByAppendingString:line] : line) writeToFile:plain atomically:NO encoding:NSUTF8StringEncoding error:NULL];
}
static BOOL DSNCLinenLike(UIView *v) {
    if (v.tag == DS_NC_TAG) return NO;
    CGSize b = v.bounds.size;
    if (b.width < 250 || b.height < 250) return NO;
    const char *cn = class_getName([v class]);
    if (strstr(cn, "inen") != NULL) return YES;
    CGColorRef c = v.backgroundColor.CGColor;
    if (c != NULL && CGColorGetPattern(c) != NULL) return YES;
    if ([v isKindOfClass:[UIImageView class]] && ((UIImageView *)v).image != nil) return YES;
    return NO;
}
// A dark gray band for the Notification Center dividers: gray gradient, a thin dark outline, a light line along the
// top edge and a shading line along the bottom edge (like the section headers in the dark Music list).
@interface DSNCBand : UIView {
    CALayer *topLine;
    CALayer *bottomLine;
}
@end
@implementation DSNCBand
+ (Class)layerClass { return [CAGradientLayer class]; }
- (id)initWithFrame:(CGRect)f {
    self = [super initWithFrame:f];
    if (self) {
        CAGradientLayer *g = (CAGradientLayer *)self.layer;
        g.colors = [NSArray arrayWithObjects:(id)[UIColor colorWithWhite:0.40 alpha:1.0].CGColor, (id)[UIColor colorWithWhite:0.24 alpha:1.0].CGColor, nil];
        g.borderColor = [UIColor colorWithWhite:0.0 alpha:0.55].CGColor;
        g.borderWidth = 1.0;
        topLine = [[CALayer alloc] init];
        topLine.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.20].CGColor;
        [g addSublayer:topLine];
        bottomLine = [[CALayer alloc] init];
        bottomLine.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.70].CGColor;
        [g addSublayer:bottomLine];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat px = 1.0 / ([[UIScreen mainScreen] scale] > 0 ? [[UIScreen mainScreen] scale] : 1.0);
    CGRect b = self.bounds;
    topLine.frame = CGRectMake(0, 1.0, b.size.width, px);
    bottomLine.frame = CGRectMake(0, b.size.height - 1.0 - px, b.size.width, px);
}
- (void)dealloc {
    [topLine release];
    [bottomLine release];
    [super dealloc];
}
@end

// The strip at the bottom of Notification Center fades the list into the linen. It gets a dark layer that fades in the
// same way, so the bottom matches the rest of the dark linen without a gray band.
@interface DSNCFade : UIView
@end
@implementation DSNCFade
+ (Class)layerClass { return [CAGradientLayer class]; }
- (id)initWithFrame:(CGRect)f {
    self = [super initWithFrame:f];
    if (self) {
        CAGradientLayer *g = (CAGradientLayer *)self.layer;
        g.colors = [NSArray arrayWithObjects:(id)[UIColor colorWithWhite:0.0 alpha:0.0].CGColor, (id)[UIColor colorWithWhite:0.0 alpha:0.62].CGColor, nil];
    }
    return self;
}
@end
static BOOL DSNCFadeLike(UIView *v) {
    return strstr(class_getName([v class]), "LinenFadeView") != NULL;
}

// the divider bands (section headers and strips between sections) get a gray band instead of the dark layer
// the strip at the very bottom is a linen segment inside the fade view: it must look like the plain dark linen, not a gray band
static BOOL DSNCInFade(UIView *v) {
    for (UIView *p = v.superview; p != nil; p = p.superview) {
        if (strstr(class_getName([p class]), "LinenFadeView") != NULL) return YES;
    }
    return NO;
}
static BOOL DSNCDividerLike(UIView *v) {
    const char *cn = class_getName([v class]);
    return ((strstr(cn, "LinenSegmentView") != NULL || strstr(cn, "LinenBackedCell") != NULL) && !DSNCInFade(v));
}
static BOOL DSNCFadeSegment(UIView *v) {
    return (strstr(class_getName([v class]), "LinenSegmentView") != NULL && DSNCInFade(v));
}
static void DSNCWalk(UIView *v, int depth, BOOL on, int *applied, BOOL dump) {
    if (v == nil || depth > 6) return;
    if (dump) DSNCLog([NSString stringWithFormat:@"%*s%s frame %.0fx%.0f tag %ld\n", depth * 2, "", class_getName([v class]), v.bounds.size.width, v.bounds.size.height, (long)v.tag]);
    // remove old layers first
    UIView *old = [v viewWithTag:DS_NC_TAG];
    if (!on) {
        if (old != nil && old.superview == v) { [old removeFromSuperview]; (*applied)++; }
    } else if (DSNCDividerLike(v) || DSNCFadeLike(v) || DSNCFadeSegment(v) || DSNCLinenLike(v)) {
        if (old != nil && old.superview == v && [old isKindOfClass:[DSNCBand class]] && !DSNCDividerLike(v)) {
            [old removeFromSuperview];    // an old gray band on a view that should be plain dark
            old = nil;
        }
        if (old == nil || old.superview != v) {
            BOOL band = DSNCDividerLike(v);
            BOOL fade = (!band && DSNCFadeLike(v));
            UIView *ov = band ? [[DSNCBand alloc] initWithFrame:v.bounds] : (fade ? [[DSNCFade alloc] initWithFrame:v.bounds] : [[UIView alloc] initWithFrame:v.bounds]);
            ov.tag = DS_NC_TAG;
            ov.userInteractionEnabled = NO;
            if (!band && !fade) ov.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.62];
            ov.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [v insertSubview:ov atIndex:0];
            [ov release];
            (*applied)++;
        }
        return;   // do not go inside a linen view
    }
    NSArray *subs = [NSArray arrayWithArray:v.subviews];
    for (UIView *sv in subs) {
        if (sv.tag == DS_NC_TAG) continue;
        DSNCWalk(sv, depth + 1, on, applied, dump);
    }
}
static void DSNCApply(id controller) {
    @try {
        UIView *root = nil;
        if ([controller isKindOfClass:[UIView class]]) root = controller;
        else if ([controller respondsToSelector:@selector(view)]) root = [controller performSelector:@selector(view)];
        if (![root isKindOfClass:[UIView class]]) return;
        BOOL on = DSNCEnabled();
        static BOOL dumped = NO;
        BOOL dump = (!dumped && on && DSDebugOn());
        int applied = 0;
        DSNCWalk(root, 0, on, &applied, dump);
        if (dump) dumped = YES;
        // one full picture of the Notification Center views (classes, frames, colors) to help with layout fixes
        static BOOL treeDumped = NO;
        if (on && DSDebugOn() && !treeDumped && [root respondsToSelector:@selector(recursiveDescription)] && root.bounds.size.height > 300) {
            treeDumped = YES;
            NSString *d = [root performSelector:@selector(recursiveDescription)];
            if (d != nil) {
                if ([d length] > 14000) d = [d substringToIndex:14000];
                DSNCLog([NSString stringWithFormat:@"TREE of %s:\n%@\n", class_getName([root class]), d]);
            }
        }
        if (applied > 0) DSNCLog([NSString stringWithFormat:@"dark layer %@ on %d view(s)\n", on ? @"added" : @"removed", applied]);
    } @catch (NSException *e) {
    }
}
static void DSNCHook(const char *cls, SEL sel) {
    Class k = objc_getClass(cls);
    if (k == Nil) return;
    Method m = class_getInstanceMethod(k, sel);
    if (m == NULL) return;
    IMP orig = method_getImplementation(m);
    IMP repl = imp_implementationWithBlock(^(id selfObj, BOOL animated) {
        ((void (*)(id, SEL, BOOL))orig)(selfObj, sel, animated);
        DSNCApply(selfObj);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ DSNCApply(selfObj); });
    });
    if (!class_addMethod(k, sel, repl, method_getTypeEncoding(m))) method_setImplementation(m, repl);   // inherited method: add to this class only
    DSNCLog([NSString stringWithFormat:@"hooked -[%s %s]\n", cls, sel_getName(sel)]);
}
static void DSNCHookView(Class k) {
    SEL sel = @selector(didMoveToWindow);
    Method m = class_getInstanceMethod(k, sel);
    if (m == NULL) return;
    IMP orig = method_getImplementation(m);
    IMP repl = imp_implementationWithBlock(^(id selfObj) {
        ((void (*)(id, SEL))orig)(selfObj, sel);
        if ([(UIView *)selfObj window] != nil) {
            DSNCLog([NSString stringWithFormat:@"view %s moved to window\n", class_getName([selfObj class])]);
            DSNCApply(selfObj);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ DSNCApply(selfObj); });
            // once, after everything has been laid out: log the whole window the list lives in
            static BOOL winDumped = NO;
            if (!winDumped && strcmp(class_getName([selfObj class]), "SBBulletinListView") == 0 && DSNCEnabled() && DSDebugOn()) {
                winDumped = YES;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    @try {
                        UIView *top = (UIView *)selfObj;
                        NSMutableString *chain = [NSMutableString string];
                        while (top.superview != nil) {
                            [chain appendFormat:@"  up: %s frame %.0f,%.0f %.0fx%.0f\n", class_getName([top class]), top.frame.origin.x, top.frame.origin.y, top.frame.size.width, top.frame.size.height];
                            top = top.superview;
                        }
                        DSNCLog([NSString stringWithFormat:@"ANCESTORS of the list:\n%@", chain]);
                        UIView *w = ((UIView *)selfObj).window != nil ? (UIView *)((UIView *)selfObj).window : top;
                        if ([w respondsToSelector:@selector(recursiveDescription)]) {
                            NSString *d = [w performSelector:@selector(recursiveDescription)];
                            if (d != nil) {
                                // drop the long status bar lines to keep the log readable
                                NSMutableString *out = [NSMutableString string];
                                for (NSString *ln in [d componentsSeparatedByString:@"\n"]) {
                                    if ([ln rangeOfString:@"UIStatusBar"].location != NSNotFound) continue;
                                    [out appendFormat:@"%@\n", ln];
                                }
                                if ([out length] > 30000) [out deleteCharactersInRange:NSMakeRange(30000, [out length] - 30000)];
                                DSNCLog([NSString stringWithFormat:@"WINDOW TREE (%s):\n%@\n", class_getName([w class]), out]);
                            }
                        }
                    } @catch (NSException *e) {
                    }
                });
            }
        }
    });
    if (!class_addMethod(k, sel, repl, method_getTypeEncoding(m))) method_setImplementation(m, repl);   // inherited method: add to this class only
    DSNCLog([NSString stringWithFormat:@"hooked -[%s didMoveToWindow]\n", class_getName(k)]);
}
static void DSInstallNCHooks(void) {
    DSNCLog(@"DarkSix Notification Center hooks starting\n");
    DSNCHook("SBNotificationCenterViewController", @selector(viewWillAppear:));
    DSNCHook("SBNotificationCenterViewController", @selector(viewDidAppear:));
    // list the Notification Center classes this system has (helps if the names ever differ)
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    NSMutableData *buf = [NSMutableData dataWithLength:sizeof(Class) * count];
    Class *list = (Class *)[buf mutableBytes];
    count = objc_getClassList(list, count);
    for (int i = 0; i < count; i++) {
        const char *n = class_getName(list[i]);
        BOOL nc = (strncmp(n, "SBNotificationCenter", 20) == 0);
        BOOL bl = (strncmp(n, "SBBulletin", 10) == 0 || strncmp(n, "SBNotification", 14) == 0 || strstr(n, "Linen") != NULL);
        if (nc || bl) {
            DSNCLog([NSString stringWithFormat:@"class %s\n", n]);
            Class k = list[i];
            BOOL hookIt = nc || strncmp(n, "SBBulletinList", 14) == 0 || strstr(n, "Linen") != NULL || strstr(n, "NotificationsView") != NULL;
            if (hookIt && [k isSubclassOfClass:[UIView class]]) {
                DSNCHookView(k);
            } else if (hookIt && [k isSubclassOfClass:[UIViewController class]] && strcmp(n, "SBNotificationCenterViewController") != 0) {
                DSNCHook(n, @selector(viewWillAppear:));
                DSNCHook(n, @selector(viewDidAppear:));
            }
        }
    }
}

// ---------- Black launch screen (inside SpringBoard) ----------
// When an app opens, SpringBoard zooms in the app's launch picture (Default.png), which is light. For every app that
// DarkSix darkens, that picture is replaced with a black one of the same size, so the animation starts dark.
static void DSLaunchLog(NSString *line) {
    if (!DSDebugOn()) return;
    static int lines = 0;
    if (lines++ > 100) return;
    NSString *path = @"/var/mobile/Library/Caches/DarkSix-launch.txt";
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (fh == nil) {
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:path];
    }
    if (fh == nil) return;
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

static BOOL DSLaunchAppIsDark(id app) {
    NSString *bid = nil;
    if ([app respondsToSelector:@selector(displayIdentifier)]) bid = [app performSelector:@selector(displayIdentifier)];
    if (bid == nil && [app respondsToSelector:@selector(bundleIdentifier)]) bid = [app performSelector:@selector(bundleIdentifier)];
    if (![bid isKindOfClass:[NSString class]]) return NO;
    NSArray *fullList = [NSArray arrayWithObjects:@"com.apple.Preferences", @"com.apple.MobileSMS", @"com.apple.mobilemail",
        @"com.apple.MobileAddressBook", @"com.apple.mobilephone", @"com.apple.mobileipod", @"com.apple.mobilecal",
        @"com.apple.mobileslideshow", @"com.apple.videos", nil];
    if (![fullList containsObject:bid]) return NO;
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.example.darksix.plist"];
    id en = [prefs objectForKey:@"enabled"];
    if (en != nil && ![en boolValue]) return NO;
    id ap = [prefs objectForKey:[@"app_" stringByAppendingString:bid]];
    return (ap == nil || [ap boolValue]);
}

static UIImage *DSBlackLike(UIImage *img) {
    CGSize sz = img.size;
    CGFloat sc = img.scale > 0 ? img.scale : 1.0;
    if (sz.width < 1 || sz.height < 1) return img;
    UIGraphicsBeginImageContextWithOptions(sz, YES, sc);
    [[UIColor blackColor] setFill];
    UIRectFill(CGRectMake(0, 0, sz.width, sz.height));
    UIImage *r = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return r != nil ? r : img;
}

static CGImageRef DSBlackCG(CGImageRef src) {
    size_t w = CGImageGetWidth(src), h = CGImageGetHeight(src);
    if (w < 1 || h < 1) return NULL;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(NULL, w, h, 8, 0, cs, kCGImageAlphaNoneSkipLast);
    CGColorSpaceRelease(cs);
    if (c == NULL) return NULL;
    CGContextSetRGBFillColor(c, 0, 0, 0, 1);
    CGContextFillRect(c, CGRectMake(0, 0, w, h));
    CGImageRef out = CGBitmapContextCreateImage(c);
    CGContextRelease(c);
    return out;
}

// SBDefaultImageInfo holds the launch picture. Replace any picture it carries with a black one.
static void DSPatchInfo(id info, BOOL dark, NSString *hname) {
    static int dumps = 0;
    BOOL log = (dumps < 3);
    if (log) { dumps++; DSLaunchLog([NSString stringWithFormat:@"-- %@ info class %s dark=%d\n", hname, class_getName(object_getClass(info)), dark]); }
    for (Class k = object_getClass(info); k != Nil && k != [NSObject class]; k = class_getSuperclass(k)) {
        unsigned int ic = 0;
        Ivar *iv = class_copyIvarList(k, &ic);
        for (unsigned int q = 0; q < ic; q++) {
            const char *en = ivar_getTypeEncoding(iv[q]);
            const char *iname = ivar_getName(iv[q]);
            if (en == NULL) continue;
            if (en[0] == '@') {
                id val = object_getIvar(info, iv[q]);
                if (log) DSLaunchLog([NSString stringWithFormat:@"   ivar %s @ %s\n", iname, val ? class_getName(object_getClass(val)) : "nil"]);
                if (dark && val != nil && [val isKindOfClass:[UIImage class]]) {
                    UIImage *b = DSBlackLike((UIImage *)val);
                    if (b != val) { [b retain]; object_setIvar(info, iv[q], b); }
                }
            } else if (strstr(en, "CGImage") != NULL) {
                CGImageRef *p = (CGImageRef *)((char *)info + ivar_getOffset(iv[q]));
                if (log) DSLaunchLog([NSString stringWithFormat:@"   ivar %s CGImage %p\n", iname, (void *)*p]);
                if (dark && *p != NULL) {
                    CGImageRef b = DSBlackCG(*p);
                    if (b != NULL) *p = b;
                }
            } else if (log) {
                DSLaunchLog([NSString stringWithFormat:@"   ivar %s %s\n", iname, en]);
            }
        }
        if (iv != NULL) free(iv);
    }
}

static NSObject *dsLaunchHooked = nil;

static void DSInstallLaunchHooks(void) {
    [[NSFileManager defaultManager] removeItemAtPath:@"/var/mobile/Library/Caches/DarkSix-launch.txt" error:NULL];
    if (dsLaunchHooked == nil) dsLaunchHooked = [[NSMutableSet alloc] init];
    NSMutableSet *done = (NSMutableSet *)dsLaunchHooked;
    Class base = NSClassFromString(@"SBApplication");
    if (base == Nil) {
        DSLaunchLog(@"SBApplication not found\n");
        return;
    }
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    NSMutableData *buf = [NSMutableData dataWithLength:sizeof(Class) * count];
    Class *list = (Class *)[buf mutableBytes];
    count = objc_getClassList(list, count);
    for (int i = 0; i < count; i++) {
        Class k = list[i];
        const char *cn = class_getName(k);
        if (cn == NULL || cn[0] != 'S' || cn[1] != 'B') continue;
        BOOL isApp = NO;
        for (Class s2 = k; s2 != Nil; s2 = class_getSuperclass(s2)) {
            if (s2 == base) { isApp = YES; break; }
        }
        unsigned int mc = 0;
        Method *ms = class_copyMethodList(k, &mc);
        for (unsigned int j = 0; j < mc; j++) {
            const char *nm = sel_getName(method_getName(ms[j]));
            if (nm == NULL) continue;
            if (strcasestr(nm, "defaultimage") == NULL && strcasestr(nm, "launchimage") == NULL && strcasestr(nm, "defaultpng") == NULL) continue;
            char rt[16] = {0};
            method_getReturnType(ms[j], rt, sizeof(rt));
            unsigned int na = method_getNumberOfArguments(ms[j]);
            DSLaunchLog([NSString stringWithFormat:@"candidate -[%s %s] ret=%s args=%u app=%d\n", cn, nm, rt, na, isApp]);
            if (!isApp || rt[0] != '@' || na < 2 || na > 8) continue;
            if (strncmp(nm, "defaultImage:", 13) != 0 && strstr(nm, "DefaultImageInfo") == NULL && strstr(nm, "defaultPNGForLaunching") == NULL) continue;
            BOOL okArgs = YES;
            for (unsigned int a = 2; a < na; a++) {
                char *t = method_copyArgumentType(ms[j], a);
                if (t == NULL || strchr("cCBiIsSlLf@", t[0]) == NULL) { okArgs = NO; DSLaunchLog([NSString stringWithFormat:@"  rejected %s arg %u type %s\n", nm, a, t ? t : "?"]); }
                if (t != NULL) free(t);
            }
            if (!okArgs) continue;
            NSString *key = [NSString stringWithFormat:@"%p|%s", k, nm];
            if ([done containsObject:key]) continue;
            [done addObject:key];
            IMP orig = method_getImplementation(ms[j]);
            SEL theSel = method_getName(ms[j]);
            NSString *hname = [NSString stringWithFormat:@"-[%s %s]", cn, nm];
            // all extra arguments are 32-bit words (ints, BOOLs, objects, floats), so they are passed on unchanged as words
            #define DS_FIX(r, selfObj) ({ id _r = (r); \
                if ([_r isKindOfClass:[UIImage class]]) { if (strncmp(nm, "_new", 4) != 0 && DSLaunchAppIsDark(selfObj)) _r = DSBlackLike((UIImage *)_r); } \
                else if (_r != nil) { DSPatchInfo(_r, DSLaunchAppIsDark(selfObj), hname); } \
                _r; })
            IMP repl = NULL;
            typedef intptr_t W;
            switch (na) {
                case 2: repl = imp_implementationWithBlock(^id(id o) { return DS_FIX(((id (*)(id, SEL))orig)(o, theSel), o); }); break;
                case 3: repl = imp_implementationWithBlock(^id(id o, W a1) { return DS_FIX(((id (*)(id, SEL, W))orig)(o, theSel, a1), o); }); break;
                case 4: repl = imp_implementationWithBlock(^id(id o, W a1, W a2) { return DS_FIX(((id (*)(id, SEL, W, W))orig)(o, theSel, a1, a2), o); }); break;
                case 5: repl = imp_implementationWithBlock(^id(id o, W a1, W a2, W a3) { return DS_FIX(((id (*)(id, SEL, W, W, W))orig)(o, theSel, a1, a2, a3), o); }); break;
                case 6: repl = imp_implementationWithBlock(^id(id o, W a1, W a2, W a3, W a4) { return DS_FIX(((id (*)(id, SEL, W, W, W, W))orig)(o, theSel, a1, a2, a3, a4), o); }); break;
                case 7: repl = imp_implementationWithBlock(^id(id o, W a1, W a2, W a3, W a4, W a5) { return DS_FIX(((id (*)(id, SEL, W, W, W, W, W))orig)(o, theSel, a1, a2, a3, a4, a5), o); }); break;
                default: repl = imp_implementationWithBlock(^id(id o, W a1, W a2, W a3, W a4, W a5, W a6) { return DS_FIX(((id (*)(id, SEL, W, W, W, W, W, W))orig)(o, theSel, a1, a2, a3, a4, a5, a6), o); }); break;
            }
            #undef DS_FIX
            method_setImplementation(ms[j], repl);
            DSLaunchLog([NSString stringWithFormat:@"hooked -[%s %s]\n", cn, nm]);
        }
        if (ms != NULL) free(ms);
    }
}

// ---------- Settings: the light line under the end of each group ----------
static void DSLinesLog(NSString *line) {
    if (!DSDebugOn()) return;
    static int n = 0;
    if (n++ > 150) return;
    NSString *path = @"/var/mobile/Library/Caches/DarkSix-lines.txt";
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (fh == nil) {
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:path];
    }
    if (fh == nil) return;
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

static int dsColorLogs = 0;
static void DSColorLog(const char *fn, CGFloat a, CGFloat b, CGFloat c2, CGFloat d, BOOL fixed) {
    if (!dsInCellBg || dsColorLogs > 40) return;
    dsColorLogs++;
    DSLinesLog([NSString stringWithFormat:@"cellbg %s %.2f %.2f %.2f %.2f %s\n", fn, (double)a, (double)b, (double)c2, (double)d, fixed ? "-> dark" : ""]);
}

// light colors used while a grouped cell background draws become near-black
static CGColorRef DSLineFix(CGColorRef color, BOOL *changed) {
    *changed = NO;
    if (!dsInCellBg || color == NULL) return color;
    size_t n = CGColorGetNumberOfComponents(color);
    const CGFloat *p = CGColorGetComponents(color);
    CGFloat L = -1, A = 1;
    if (n == 2) { L = p[0]; A = p[1]; }
    else if (n == 4) { L = 0.299 * p[0] + 0.587 * p[1] + 0.114 * p[2]; A = p[3]; }
    DSColorLog("color", L, A, 0, 0, (L > 0.55 && A > 0.02));
    if (L > 0.55 && A > 0.02) {
        *changed = YES;
        return [UIColor colorWithWhite:0.04 alpha:1.0].CGColor;
    }
    return color;
}

%group SettingsLines

%hookf(void, CGContextSetShadowWithColor, CGContextRef c, CGSize offset, CGFloat blur, CGColorRef color)
{
    BOOL ch = NO;
    CGColorRef use = DSLineFix(color, &ch);
    %orig(c, offset, blur, use);
}

%hookf(void, CGContextSetStrokeColorWithColor, CGContextRef c, CGColorRef color)
{
    BOOL ch = NO;
    CGColorRef use = DSLineFix(color, &ch);
    %orig(c, use);
}

%hookf(void, CGContextSetFillColorWithColor, CGContextRef c, CGColorRef color)
{
    BOOL ch = NO;
    CGColorRef use = DSLineFix(color, &ch);
    %orig(c, use);
}

%hookf(void, CGContextSetGrayStrokeColor, CGContextRef c, CGFloat gray, CGFloat alpha)
{
    CGFloat g = gray, al = alpha;
    DSColorLog("gray", gray, alpha, 0, 0, (dsInCellBg && gray > 0.55 && alpha > 0.02));
    if (dsInCellBg && gray > 0.55 && alpha > 0.02) {
        g = 0.04;
        al = 1.0;
    }
    %orig(c, g, al);
}

%hookf(void, CGContextSetGrayFillColor, CGContextRef c, CGFloat gray, CGFloat alpha)
{
    CGFloat g = gray, al = alpha;
    DSColorLog("gray", gray, alpha, 0, 0, (dsInCellBg && gray > 0.55 && alpha > 0.02));
    if (dsInCellBg && gray > 0.55 && alpha > 0.02) {
        g = 0.04;
        al = 1.0;
    }
    %orig(c, g, al);
}

%hookf(void, CGContextSetRGBStrokeColor, CGContextRef c, CGFloat r, CGFloat g, CGFloat b, CGFloat alpha)
{
    CGFloat nr = r, ng = g, nb = b, na = alpha;
    DSColorLog("rgb", r, g, b, alpha, (dsInCellBg && (0.299 * r + 0.587 * g + 0.114 * b) > 0.55 && alpha > 0.02));
    if (dsInCellBg && (0.299 * r + 0.587 * g + 0.114 * b) > 0.55 && alpha > 0.02) {
        nr = 0.04;
        ng = 0.04;
        nb = 0.04;
        na = 1.0;
    }
    %orig(c, nr, ng, nb, na);
}

%hookf(void, CGContextSetRGBFillColor, CGContextRef c, CGFloat r, CGFloat g, CGFloat b, CGFloat alpha)
{
    CGFloat nr = r, ng = g, nb = b, na = alpha;
    DSColorLog("rgb", r, g, b, alpha, (dsInCellBg && (0.299 * r + 0.587 * g + 0.114 * b) > 0.55 && alpha > 0.02));
    if (dsInCellBg && (0.299 * r + 0.587 * g + 0.114 * b) > 0.55 && alpha > 0.02) {
        nr = 0.04;
        ng = 0.04;
        nb = 0.04;
        na = 1.0;
    }
    %orig(c, nr, ng, nb, na);
}

%hookf(void, CGContextDrawImage, CGContextRef c, CGRect rect, CGImageRef image)
{
    CGImageRef use = image;
    if (dsInCellBg && image != NULL) {
        static NSMutableDictionary *cache = nil;
        if (cache == nil) cache = [[NSMutableDictionary alloc] init];
        NSString *k = [NSString stringWithFormat:@"%p", image];
        UIImage *dk = [cache objectForKey:k];
        if (dk == nil) {
            dk = DSLightToDarkImage([UIImage imageWithCGImage:image]);
            if ([cache count] > 300) [cache removeAllObjects];
            if (dk != nil) [cache setObject:dk forKey:k];
            DSLinesLog([NSString stringWithFormat:@"image drawn in cell background: %.0fx%.0f at %@ (changed=%d)\n", (double)CGImageGetWidth(image), (double)CGImageGetHeight(image), NSStringFromCGRect(rect), (int)(dk.CGImage != image)]);
        }
        if (dk.CGImage != NULL) use = dk.CGImage;
    }
    %orig(c, rect, use);
}

%end

// Settings: a grouped cell may draw its edge (and the light line under the end of a group) from a picture.
// Any light pixels in such a picture become near-black; the shape and the transparency stay.
static UIImage *DSLightToDarkImage(UIImage *src) {
    if (src == nil || src.CGImage == NULL) return src;
    CGImageRef cg = src.CGImage;
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    if (w < 1 || h < 1 || w * h > 600 * 600) return src;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef cx = CGBitmapContextCreate(NULL, w, h, 8, w * 4, cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (cx == NULL) return src;
    CGContextDrawImage(cx, CGRectMake(0, 0, w, h), cg);
    unsigned char *px = (unsigned char *)CGBitmapContextGetData(cx);
    int changed = 0;
    for (size_t i = 0; i < w * h; i++) {
        unsigned char a = px[i * 4 + 3];
        if (a < 8) continue;
        float r = px[i * 4] / (float)a, g = px[i * 4 + 1] / (float)a, b = px[i * 4 + 2] / (float)a;
        float L = 0.299f * r + 0.587f * g + 0.114f * b;
        if (L > 0.55f) {
            unsigned char v = (unsigned char)(0.04f * a);
            px[i * 4] = v; px[i * 4 + 1] = v; px[i * 4 + 2] = v;
            changed++;
        }
    }
    CGImageRef out = (changed > 0) ? CGBitmapContextCreateImage(cx) : NULL;
    CGContextRelease(cx);
    if (out == NULL) return src;
    UIImage *r = [UIImage imageWithCGImage:out scale:src.scale orientation:UIImageOrientationUp];
    CGImageRelease(out);
    UIEdgeInsets ci = src.capInsets;
    if (ci.top > 0 || ci.left > 0 || ci.bottom > 0 || ci.right > 0) {
        r = [r resizableImageWithCapInsets:ci];
    }
    return r;
}

static NSMutableSet *dsDarkenedImgs = nil;

static void DSDarkenCellBgViews(UIView *v, int depth, BOOL dump, NSMutableString *log) {
    if (v == nil || depth > 3) return;
    for (UIView *x in [NSArray arrayWithArray:v.subviews]) {
        if (x.tag == 0xD5B1) continue;
        if (dump) {
            id cont = x.layer.contents;
            [log appendFormat:@"%*s%s frame=%@ hidden=%d alpha=%.2f bg=%@ contents=%s%@\n", depth * 2, "", class_getName(object_getClass(x)), NSStringFromCGRect(x.frame), x.hidden, x.alpha, x.backgroundColor, cont ? class_getName(object_getClass(cont)) : "nil",
                [x isKindOfClass:[UIImageView class]] ? [NSString stringWithFormat:@" image=%@", ((UIImageView *)x).image] : @""];
        }
        if ([x isKindOfClass:[UIImageView class]] && depth <= 2) {
            UIImageView *iv = (UIImageView *)x;
            UIImage *im = iv.image;
            if (im != nil && (iv.frame.size.width >= 100 || iv.frame.size.width <= 0 || depth == 0)) {
                NSString *k = [NSString stringWithFormat:@"%p", im];
                if (![dsDarkenedImgs containsObject:k]) {
                    UIImage *d = DSLightToDarkImage(im);
                    if (d != im) {
                        [dsDarkenedImgs addObject:[NSString stringWithFormat:@"%p", d]];
                        iv.image = d;
                    }
                    [dsDarkenedImgs addObject:k];
                }
            }
        }
        DSDarkenCellBgViews(x, depth + 1, dump, log);
    }
}

static void DSSettingsCellBg(UITableViewCell *cell) {
    static int dumps = 0;
    if (dsDarkenedImgs == nil) dsDarkenedImgs = [[NSMutableSet alloc] init];
    BOOL dump = (dumps < 5);
    NSMutableString *log = dump ? [NSMutableString stringWithFormat:@"-- cell %@ frame=%@ bg=%@ backgroundView=%@ selectedBackgroundView=%@\n", NSStringFromClass([cell class]), NSStringFromCGRect(cell.frame), cell.backgroundColor, cell.backgroundView, cell.selectedBackgroundView] : nil;
    if (cell.backgroundView != nil) {
        UIView *bv = cell.backgroundView;
        if ([bv isKindOfClass:[UIImageView class]]) {
            UIImageView *iv = (UIImageView *)bv;
            NSString *k = [NSString stringWithFormat:@"%p", iv.image];
            if (iv.image != nil && ![dsDarkenedImgs containsObject:k]) {
                UIImage *d = DSLightToDarkImage(iv.image);
                if (d != iv.image) {
                    [dsDarkenedImgs addObject:[NSString stringWithFormat:@"%p", d]];
                    iv.image = d;
                }
                [dsDarkenedImgs addObject:k];
            }
        }
        DSDarkenCellBgViews(bv, 0, dump, log);
    }
    DSDarkenCellBgViews(cell, 0, dump, log);
    if (dump) {
        dumps++;
        DSLinesLog(log);
    }
}

// every view class that draws a grouped cell's background gets a "drawing now" flag around its drawRect:
static void DSInstallCellBgHooks(void) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    NSMutableData *buf = [NSMutableData dataWithLength:sizeof(Class) * count];
    Class *list = (Class *)[buf mutableBytes];
    count = objc_getClassList(list, count);
    for (int i = 0; i < count; i++) {
        Class k = list[i];
        const char *cn = class_getName(k);
        if (cn == NULL || cn[0] != 'U' || cn[1] != 'I') continue;
        if (!(DSContains(cn, "GroupTableViewCell") || DSContains(cn, "CellBackground") || DSContains(cn, "GroupedCell") || DSContains(cn, "TableViewCellGroup"))) continue;
        BOOL isView = NO;
        for (Class s2 = k; s2 != Nil; s2 = class_getSuperclass(s2)) {
            if (s2 == [UIView class]) { isView = YES; break; }
        }
        if (!isView) continue;
        Method dm = class_getInstanceMethod(k, @selector(drawRect:));
        if (dm == NULL) continue;
        IMP orig = class_getMethodImplementation(k, @selector(drawRect:));      // may be inherited
        IMP repl = imp_implementationWithBlock(^void(id selfObj, CGRect r) {
            BOOL prev = dsInCellBg;
            dsInCellBg = YES;
            ((void (*)(id, SEL, CGRect))orig)(selfObj, @selector(drawRect:), r);
            dsInCellBg = prev;
        });
        class_replaceMethod(k, @selector(drawRect:), repl, method_getTypeEncoding(dm));
        DSLinesLog([NSString stringWithFormat:@"hooked drawRect: of %s (own or inherited)\n", cn]);
    }
}

// key legends that are drawn in code (the $ and currency keys): dark text -> white, white emboss -> dark shadow.
// Only for small drawing surfaces: the big full-keyboard picture is drawn the same way, and its dark legends must stay
// dark so the picture recolor (kb_core.c) can find them.
static BOOL DSKbTextCtx(CGContextRef c)
{
    if (!dsInKeyboardDraw || dsInHook || c == NULL) return NO;
    size_t cw = CGBitmapContextGetWidth(c);
    return (cw > 0 && cw <= 240);
}

%group KeyboardText

%hookf(void, CGContextSetFillColorWithColor, CGContextRef c, CGColorRef color)
{
    CGColorRef use = color;
    if (DSKbTextCtx(c) && color != NULL) {
        size_t nc = CGColorGetNumberOfComponents(color);
        const CGFloat *pc = CGColorGetComponents(color);
        CGFloat lum = -1, al = 1;
        if (nc == 2) {
            lum = pc[0];
            al = pc[1];
        } else if (nc == 4) {
            lum = 0.299 * pc[0] + 0.587 * pc[1] + 0.114 * pc[2];
            al = pc[3];
        }
        if (lum >= 0 && lum < 0.35 && al > 0.3) {
            use = [UIColor whiteColor].CGColor;
        }
    }
    %orig(c, use);
}

%hookf(void, CGContextSetGrayFillColor, CGContextRef c, CGFloat gray, CGFloat alpha)
{
    CGFloat g2 = gray;
    if (DSKbTextCtx(c) && gray < 0.35 && alpha > 0.3) {
        g2 = 1.0;
    }
    %orig(c, g2, alpha);
}

%hookf(void, CGContextSetRGBFillColor, CGContextRef c, CGFloat r, CGFloat g, CGFloat b, CGFloat alpha)
{
    CGFloat r2 = r, g2 = g, b2 = b;
    if (DSKbTextCtx(c) && alpha > 0.3 && (0.299 * r + 0.587 * g + 0.114 * b) < 0.35) {
        r2 = 1.0;
        g2 = 1.0;
        b2 = 1.0;
    }
    %orig(c, r2, g2, b2, alpha);
}

%hookf(void, CGContextSetShadowWithColor, CGContextRef c, CGSize offset, CGFloat blur, CGColorRef color)
{
    CGColorRef use = color;
    if (DSKbTextCtx(c) && color != NULL) {
        size_t nc = CGColorGetNumberOfComponents(color);
        const CGFloat *pc = CGColorGetComponents(color);
        CGFloat lum = -1, al = 1;
        if (nc == 2) {
            lum = pc[0];
            al = pc[1];
        } else if (nc == 4) {
            lum = 0.299 * pc[0] + 0.587 * pc[1] + 0.114 * pc[2];
            al = pc[3];
        }
        if (lum > 0.7 && al > 0.05) {
            use = [UIColor colorWithWhite:0.0 alpha:0.85].CGColor;
        }
    }
    %orig(c, offset, blur, use);
}

%end

// apps that only get the keyboard (everything that is not one of the stock apps DarkSix restyles)
%group KeyboardLayer

%hook CALayer

- (void)setContents:(id)contents
{
    id use = contents;
    if (!dsInHook && contents != nil && CFGetTypeID((CFTypeRef)contents) == CGImageGetTypeID() && DSLayerInKeyboard(self)) {
        CGImageRef kb = DSKeyboardImage((CGImageRef)contents);
        if (kb != NULL) use = (id)kb;
    }
    %orig(use);
}

%end

%end

// every text box asks for the dark keyboard style
%group KeyboardTraits

%hook UITextField
- (UIKeyboardAppearance)keyboardAppearance
{
    return (UIKeyboardAppearance)1;
}
%end

%hook UITextView
- (UIKeyboardAppearance)keyboardAppearance
{
    return (UIKeyboardAppearance)1;
}
%end

%hook UIWebBrowserView
- (UIKeyboardAppearance)keyboardAppearance
{
    return (UIKeyboardAppearance)1;
}
%end

%end

// ---------- setup ----------

%ctor
{
    // On/off switch from Settings > DarkSix. Missing setting = on.
    BOOL enabled = YES;
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.example.darksix.plist"];
    id v = [prefs objectForKey:@"enabled"];
    if (v != nil) {
        enabled = [v boolValue];
    }

    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (!enabled || bid == nil) return;

    // Home screen: dark icons (only SpringBoard)
    if ([bid isEqualToString:@"com.apple.springboard"]) {
        DSInstallLaunchHooks();
        DSInstallNCHooks();
        // welcome pop-up after DarkSix is installed
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            @try {
                // shown once per installed build: the marker file remembers which build already showed it
                NSString *mark = @"/var/mobile/Library/Preferences/com.example.darksix.welcomed";
                NSString *build = @__DATE__ @" " @__TIME__;
                NSString *seen = [NSString stringWithContentsOfFile:mark encoding:NSUTF8StringEncoding error:NULL];
                if (seen == nil || ![seen isEqualToString:build]) {
                    [build writeToFile:mark atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                    UIAlertView *av = [[UIAlertView alloc] initWithTitle:@"Thank you for installing DarkSix!"
                                                                 message:@"Check out DarkSix settings to change it to your liking and test out experimental features!"
                                                                delegate:nil
                                                       cancelButtonTitle:@"OK"
                                                       otherButtonTitles:nil];
                    [av show];
                    [av release];
                }
            } @catch (NSException *ex) {
            }
        });
        id iv = [prefs objectForKey:@"darkicons"];
        dsOptIcons = (iv != nil) && [iv boolValue];      // off until the user turns it on
        if (dsOptIcons) {
            // crash breaker: if SpringBoard died last time before it finished starting, switch icons off
            NSString *marker = @"/var/mobile/Library/Caches/DarkSix-icons-starting";
            if ([[NSFileManager defaultManager] fileExistsAtPath:marker]) {
                [[NSFileManager defaultManager] removeItemAtPath:marker error:NULL];
                NSMutableDictionary *np = [NSMutableDictionary dictionaryWithDictionary:(prefs != nil ? prefs : [NSDictionary dictionary])];
                [np setObject:[NSNumber numberWithBool:NO] forKey:@"darkicons"];
                [np writeToFile:@"/var/mobile/Library/Preferences/com.example.darksix.plist" atomically:YES];
                dsOptIcons = NO;
                DSIconLog(@"SpringBoard did not finish starting last time: Dark Icons switched off\n");
            } else {
                [@"1" writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                DSInstallIconHooks();
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [[NSFileManager defaultManager] removeItemAtPath:@"/var/mobile/Library/Caches/DarkSix-icons-starting" error:NULL];
                });
            }
        }
        return;
    }

    id kv = [prefs objectForKey:@"darkkeyboard"];
    dsOptKeyboard = (kv != nil) && [kv boolValue];     // off until the user turns it on

    // the stock apps that get the full dark treatment; every other app only gets the dark keyboard
    NSArray *fullList = [NSArray arrayWithObjects:@"com.apple.Preferences", @"com.apple.MobileSMS", @"com.apple.mobilemail",
        @"com.apple.MobileAddressBook", @"com.apple.mobilephone", @"com.apple.mobileipod", @"com.apple.mobilecal",
        @"com.apple.mobileslideshow", @"com.apple.videos", nil];
    id appPref = [prefs objectForKey:[@"app_" stringByAppendingString:bid]];     // per-app switch, default on
    BOOL full = [fullList containsObject:bid] && (appPref == nil || [appPref boolValue]);

    if (full) {
        if ([bid isEqualToString:@"com.apple.MobileSMS"]) {
            dsIsMessages = YES;
        }
        if ([bid isEqualToString:@"com.apple.Preferences"]) {
            dsIsSettings = YES;
        }
        if ([bid isEqualToString:@"com.apple.mobileipod"]) {
            dsIsMusic = YES;
        }
        if ([bid isEqualToString:@"com.apple.mobilecal"] ||
            [bid isEqualToString:@"com.apple.mobileslideshow"] ||
            [bid isEqualToString:@"com.apple.videos"]) {
            dsIsExtra = YES;
            dsIsCal = [bid isEqualToString:@"com.apple.mobilecal"];
        }
        if (dsIsCal) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                DSCalTick();
            });
        }
        id lv = [prefs objectForKey:@"linen"];
        dsOptLinen = (lv != nil) && [lv boolValue];
        id pv = [prefs objectForKey:@"pinstripes"];
        dsOptPinstripes = (pv != nil) && [pv boolValue];
        %init;
        if (dsIsSettings) {
            %init(SettingsLines);
            DSInstallCellBgHooks();
        }
        if (dsIsMessages) {
            %init(BalloonText);
        }
        if (dsIsMessages || dsIsMusic || dsIsExtra) {
            %init(BackHooks);
            DSInstallNavBgHook();
        }
        if ([bid isEqualToString:@"com.apple.mobilemail"] ||
            [bid isEqualToString:@"com.apple.MobileAddressBook"] ||
            [bid isEqualToString:@"com.apple.mobilecal"] ||
            dsIsMusic) {
            dsDrawMap = YES;
            %init(DrawHooks);
            if (dsIsMusic) {
                DSInstallHeaderHooks();
            }
        }
    }

    // the dark keyboard (every app that uses UIKit)
    if (full || dsOptKeyboard) {
        if (dsOptKeyboard) {
            %init(KeyboardTraits);
            %init(KeyboardText);
        }
        if (!(dsIsMessages || dsIsMusic || dsIsExtra)) {
            %init(KeyboardDraw);
        }
        if (!full) {
            %init(KeyboardLayer);
        }
        DSInstallKeyboardHooks();
        [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardDidShowNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
            @try {
                DSDumpKeyboard();
            } @catch (NSException *ex) {
            }
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardWillShowNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
            dsKbVisible = YES;
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardDidHideNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
            dsKbVisible = NO;
        }];
        if (dsOptKeyboard) {
            [NSTimer scheduledTimerWithTimeInterval:0.2 target:[NSBlockOperation blockOperationWithBlock:^{
                @try {
                    DSKbSweep();
                } @catch (NSException *ex) {
                }
            }] selector:@selector(main) userInfo:nil repeats:YES];
        }
    }
}
