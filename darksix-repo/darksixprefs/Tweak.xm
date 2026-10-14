// DarkSix - experimental dark mode for stock iOS 6 apps.
// Idea: remap light backgrounds to dark and dark text to light at the point
// where apps set their colors, then fix up tables, cells, bars and keyboards.
// No libc string functions are used (they fail to link with the new toolchain).

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

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
static BOOL dsOptKeyboard = YES;   // setting: dark keyboard (default on)
static BOOL dsOptPinstripes = NO;  // setting: dark "Apple Pinstripes" in Settings
static BOOL dsIsSettings = NO;     // running inside Settings
static int dsMusicDumps = 0;
static int dsHdrTries = 0;
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

// opaque white / near white
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

static BOOL DSLayerInBalloon(CALayer *l) {
    id dg = l.delegate;
    if (dg != nil && [dg isKindOfClass:[UIView class]]) {
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
    if (src == NULL || dsInHook) return NULL;
    size_t w = CGImageGetWidth(src), h = CGImageGetHeight(src);
    if (w < 8 || h < 8 || w > 1024 || h > 1024) return NULL;
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
    dsInBalloonDraw = YES;
    if (orig != NULL) {
        ((void (*)(id, SEL, CGRect))orig)(self, _cmd, rect);
    }
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

static BOOL DSViewInKeyboard(UIView *v) {
    int d = 0;
    for (UIView *x = v; x != nil && d < 10; x = x.superview, d++) {
        const char *n = class_getName(object_getClass(x));
        if (DSHasPrefix(n, "UIKB") || DSHasPrefix(n, "UIKeyboard")) return YES;
    }
    return NO;
}

static BOOL DSLayerInKeyboard(CALayer *l) {
    int d = 0;
    for (CALayer *x = l; x != nil && d < 10; x = x.superlayer, d++) {
        id dg = x.delegate;
        if (dg != nil && [dg isKindOfClass:[UIView class]]) {
            return DSViewInKeyboard((UIView *)dg);
        }
    }
    return NO;
}

static void DSKbLog(NSString *line) {
    static int count = 0;
    if (count > 40) return;
    count++;
    DSWriteDiag(@"DarkSix-kb.txt", line, YES);
}

static CGFloat DSKbMap(CGFloat l) {
    if (l <= 0.30) return l * 0.10;                                   // keyboard background -> black
    if (l <= 0.62) return 0.03 + (l - 0.30) / 0.32 * 0.24;            // keys -> dark gray
    if (l <= 0.85) return 0.27 + (l - 0.62) / 0.23 * 0.63;            // edges and glyphs -> bright
    return 0.90 + (l - 0.85) / 0.15 * 0.10;                           // text -> white
}

static NSMutableDictionary *dsKbCache = nil;

// returns a dark copy of a keyboard picture (not retained), or NULL to leave it alone
static CGImageRef DSKeyboardImage(CGImageRef src) {
    if (src == NULL || dsInHook || !dsOptKeyboard) return NULL;
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
                long cnt = 0;
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
                        int bin = (int)(l * 10);
                        if (bin > 9) bin = 9;
                        if (bin < 0) bin = 0;
                        hist[bin]++;
                    }
                }
                double mean = (cnt > 0) ? sum / cnt : 1.0;
                DSKbLog([NSString stringWithFormat:@"image %lux%lu opaque %ld mean %.2f hist %d %d %d %d %d %d %d %d %d %d drawing %d\n",
                    (unsigned long)w, (unsigned long)h, cnt, mean, hist[0], hist[1], hist[2], hist[3], hist[4], hist[5], hist[6], hist[7], hist[8], hist[9], (int)dsInKeyboardDraw]);
                if (cnt > 20 && mean < 0.62) {
                    for (size_t y = 0; y < h; y++) {
                        unsigned char *row = px + y * rb;
                        for (size_t x = 0; x < w; x++) {
                            unsigned char *q = row + x * 4;
                            if (q[3] == 0) continue;
                            CGFloat a = q[3] / 255.0;
                            CGFloat l = (0.299 * q[0] + 0.587 * q[1] + 0.114 * q[2]) / 255.0 / a;
                            if (l > 1) l = 1;
                            unsigned char v = (unsigned char)(DSKbMap(l) * a * 255.0 + 0.5);
                            q[0] = v;
                            q[1] = v;
                            q[2] = v;
                        }
                    }
                    out = CGBitmapContextCreateImage(bc);
                }
            }
            CGContextRelease(bc);
        }
        id second = (out != NULL) ? (id)out : (id)[NSNull null];
        e = [NSArray arrayWithObjects:(id)src, second, nil];
        [dsKbCache setObject:e forKey:key];
        if (out != NULL) CGImageRelease(out);
    }
    id r2 = [e objectAtIndex:1];
    return (r2 == [NSNull null]) ? NULL : (CGImageRef)r2;
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
    dsInKeyboardDraw = YES;
    if (orig != NULL) {
        ((void (*)(id, SEL, CGRect))orig)(self, _cmd, rect);
    }
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
    if (!dsCellDumped && [cell respondsToSelector:@selector(recursiveDescription)]) {
        dsCellDumped = YES;
        NSString *d = [cell performSelector:@selector(recursiveDescription)];
        NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
        NSString *dir = ([dirs count] > 0) ? [dirs objectAtIndex:0] : NSTemporaryDirectory();
        [[NSString stringWithFormat:@"cell class %s\n%@\n", class_getName(object_getClass(cell)), d]
            writeToFile:[dir stringByAppendingPathComponent:@"DarkSix-cell.txt"] atomically:YES
            encoding:NSUTF8StringEncoding error:NULL];
    }
}

// Music: our own song dividers - a dark gray line with a darker (near black) line under it,
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

%hook UITableViewCell

%new
- (void)dsCleanLater
{
    @try {
        DSMusicCellClean(self);
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

%hook CALayer

- (void)setContents:(id)contents
{
    id use = contents;
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

    if (enabled) {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
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
        id kv = [prefs objectForKey:@"darkkeyboard"];
        dsOptKeyboard = (kv == nil) || [kv boolValue];
        %init;
        if (dsIsMessages) {
            %init(BalloonText);
        }
        if (!(dsIsMessages || dsIsMusic || dsIsExtra)) {
            %init(KeyboardDraw);
        }
        DSInstallKeyboardHooks();
        [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardDidShowNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
            @try {
                DSDumpKeyboard();
            } @catch (NSException *ex) {
            }
        }];
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
}
