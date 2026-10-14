#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>

// Minimal declaration of Apple's private Preferences class (same layout the Theos headers use).
@interface PSListController : UIViewController {
@protected
    NSArray *_specifiers;
}
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
- (void)setPreferenceValue:(id)value specifier:(id)specifier;
@end

@interface DSRootListController : PSListController
- (void)respring;
- (void)dsStyleTexts;
@end

@interface DSAppsListController : DSRootListController
@end

@interface DSExperimentalListController : DSRootListController
@end

static BOOL DSIsPaneText(NSString *t)
{
    if (t == nil) return NO;
    return [t isEqualToString:@"Dark mode"] ||
           [t isEqualToString:@"Backgrounds"] ||
           [t hasPrefix:@"Flip the switches"] ||
           [t hasPrefix:@"Apple Linen:"] ||
           [t isEqualToString:@"Keyboard"] ||
           [t hasPrefix:@"Dark Keyboard:"] ||
           [t isEqualToString:@"Experimental"] ||
           [t isEqualToString:@"Home screen"] ||
           [t hasPrefix:@"A list of work in progress"] ||
           [t hasPrefix:@"Dark Icons:"] ||
           [t isEqualToString:@"Per-app dark mode"] ||
           [t isEqualToString:@"Choose which apps get dark mode."] ||
           [t isEqualToString:@"Dark mode in these apps"] ||
           [t hasPrefix:@"Turn an app off"];
}

static char DSOrigKey;

static BOOL DSIsEnabled(void)
{
    CFPreferencesAppSynchronize(CFSTR("com.example.darksix"));
    CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR("enabled"), CFSTR("com.example.darksix"));
    BOOL on = YES;   // the pane's default is ON
    if (v != NULL) {
        if (CFGetTypeID(v) == CFBooleanGetTypeID()) {
            on = CFBooleanGetValue((CFBooleanRef)v) ? YES : NO;
        } else if (CFGetTypeID(v) == CFNumberGetTypeID()) {
            int n = 1;
            CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &n);
            on = (n != 0);
        }
        CFRelease(v);
    }
    return on;
}

static void DSStyleLabels(UIView *v, int depth, BOOL on)
{
    if (v == nil || depth > 12) return;
    if ([v isKindOfClass:[UILabel class]]) {
        UILabel *l = (UILabel *)v;
        if (DSIsPaneText(l.text)) {
            NSDictionary *orig = objc_getAssociatedObject(l, &DSOrigKey);
            if (on) {
                if (orig == nil) {
                    // remember how the label looked before we touched it
                    orig = [NSDictionary dictionaryWithObjectsAndKeys:
                            l.textColor, @"c",
                            (l.shadowColor != nil ? (id)l.shadowColor : (id)[NSNull null]), @"s",
                            [NSValue valueWithCGSize:l.shadowOffset], @"o", nil];
                    objc_setAssociatedObject(l, &DSOrigKey, orig, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
                l.textColor = [UIColor whiteColor];
                l.shadowColor = [UIColor colorWithWhite:0.3 alpha:1.0];
                l.shadowOffset = CGSizeMake(0, 1);
            } else if (orig != nil) {
                l.textColor = [orig objectForKey:@"c"];
                id sc = [orig objectForKey:@"s"];
                l.shadowColor = (sc == [NSNull null]) ? nil : sc;
                l.shadowOffset = [[orig objectForKey:@"o"] CGSizeValue];
                objc_setAssociatedObject(l, &DSOrigKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
    }
    NSArray *subs = [NSArray arrayWithArray:v.subviews];
    for (UIView *s in subs) {
        DSStyleLabels(s, depth + 1, on);
    }
}

@implementation DSRootListController

- (NSArray *)specifiers
{
    if (_specifiers == nil) {
        _specifiers = [[self loadSpecifiersFromPlistName:@"Root" target:self] retain];
    }
    return _specifiers;
}

- (void)dsStyleTexts
{
    if ([self isViewLoaded]) {
        DSStyleLabels(self.view, 0, DSIsEnabled());
    }
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self dsStyleTexts];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [self dsStyleTexts];
    [self performSelector:@selector(dsStyleTexts) withObject:nil afterDelay:0.1];
    [self performSelector:@selector(dsStyleTexts) withObject:nil afterDelay:0.5];
}

- (void)setPreferenceValue:(id)value specifier:(id)specifier
{
    [super setPreferenceValue:value specifier:specifier];
    [self performSelector:@selector(dsStyleTexts) withObject:nil afterDelay:0.05];
    [self performSelector:@selector(dsStyleTexts) withObject:nil afterDelay:0.4];
}

- (void)respring
{
    // make sure the switch has been written to disk before SpringBoard restarts
    CFPreferencesAppSynchronize(CFSTR("com.example.darksix"));

    // system() is blocked at compile time in newer SDKs, so look it up at run time
    typedef int (*DSSystemFn)(const char *);
    DSSystemFn fn = (DSSystemFn)dlsym(RTLD_DEFAULT, "system");
    if (fn != NULL) {
        fn("killall -9 SpringBoard || launchctl stop com.apple.SpringBoard");
    }
}

@end

@implementation DSAppsListController

- (NSArray *)specifiers
{
    if (_specifiers == nil) {
        _specifiers = [[self loadSpecifiersFromPlistName:@"Apps" target:self] retain];
    }
    return _specifiers;
}

@end

@implementation DSExperimentalListController

- (NSArray *)specifiers
{
    if (_specifiers == nil) {
        _specifiers = [[self loadSpecifiersFromPlistName:@"Experimental" target:self] retain];
    }
    return _specifiers;
}

@end
