#import "AccessibilityTree.h"
#import "Process.h"
#import <CoreGraphics/CoreGraphics.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <unistd.h>

// iOS AXRuntime exports are resolved at runtime so the tweak does not link
// against an SDK that lacks private accessibility headers.
typedef CFTypeRef (*ZXCreateApplication)(pid_t);
typedef int32_t (*ZXCopyAttribute)(CFTypeRef, CFStringRef, CFTypeRef *);
typedef int32_t (*ZXSetTimeout)(CFTypeRef, float);
typedef int32_t (*ZXValueType)(CFTypeRef);
typedef Boolean (*ZXValueGet)(CFTypeRef, int32_t, void *);
typedef pid_t (*ZXFocusedPID)(void);
typedef void (*ZXAssociatePID)(pid_t, pid_t, int);

static ZXCopyAttribute zxCopyAttribute = NULL;
static ZXValueType zxValueType = NULL;
static ZXValueGet zxValueGet = NULL;
static const NSUInteger zxMaxNodes = 2000;
static const NSUInteger zxMaxDepth = 64;

static NSString *zxString(CFTypeRef value)
{
    if (!value) return nil;
    if (CFGetTypeID(value) == CFStringGetTypeID()) return (__bridge NSString *)value;
    if (CFGetTypeID(value) == CFNumberGetTypeID()) return [(__bridge NSNumber *)value stringValue];
    return nil;
}

static CFTypeRef zxAttribute(CFTypeRef element, CFStringRef key)
{
    CFTypeRef value = NULL;
    int32_t status = zxCopyAttribute(element, key, &value);
    if (status != 0) {
        if (value) CFRelease(value);
        return NULL;
    }
    return value;
}

static NSDictionary *zxFrame(CFTypeRef element)
{
    CFTypeRef raw = zxAttribute(element, CFSTR("AXFrame"));
    if (!raw) return nil;
    CGRect frame = CGRectZero;
    // AXValue type 3 is kAXValueCGRectType on iOS AXRuntime.
    BOOL valid = zxValueType && zxValueGet && zxValueType(raw) == 3 &&
                 zxValueGet(raw, 3, &frame);
    CFRelease(raw);
    if (!valid) return nil;
    return @{@"x": @(frame.origin.x), @"y": @(frame.origin.y),
             @"width": @(frame.size.width), @"height": @(frame.size.height)};
}

static NSDictionary *zxNode(CFTypeRef element, NSUInteger depth, NSUInteger *count)
{
    if (*count >= zxMaxNodes || depth >= zxMaxDepth) return nil;
    ++*count;
    NSMutableDictionary *node = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"AXIdentifier", @"AXLabel", @"AXValue", @"AXRole", @"AXDescription"]) {
        CFTypeRef raw = zxAttribute(element, (__bridge CFStringRef)key);
        if (raw) {
            NSString *text = zxString(raw);
            if (text) {
                NSString *field = [key substringFromIndex:2];
                node[[field stringByReplacingCharactersInRange:NSMakeRange(0, 1)
                                                      withString:[[field substringToIndex:1] lowercaseString]]] = text;
            }
            CFRelease(raw);
        }
    }
    NSDictionary *frame = zxFrame(element);
    if (frame) node[@"frame"] = frame;
    CFTypeRef rawEnabled = zxAttribute(element, CFSTR("AXEnabled"));
    if (rawEnabled) {
        if (CFGetTypeID(rawEnabled) == CFBooleanGetTypeID())
            node[@"enabled"] = @((BOOL)CFBooleanGetValue((CFBooleanRef)rawEnabled));
        CFRelease(rawEnabled);
    }
    NSMutableArray *children = [NSMutableArray array];
    CFTypeRef rawChildren = zxAttribute(element, CFSTR("AXChildren"));
    if (rawChildren) {
        if (CFGetTypeID(rawChildren) == CFArrayGetTypeID()) {
            CFArrayRef array = (CFArrayRef)rawChildren;
            for (CFIndex i = 0; i < CFArrayGetCount(array) && *count < zxMaxNodes; ++i) {
                CFTypeRef child = CFArrayGetValueAtIndex(array, i);
                if (!child || CFGetTypeID(child) != CFGetTypeID(element)) continue;
                NSDictionary *entry = zxNode(child, depth + 1, count);
                if (entry) [children addObject:entry];
            }
        }
        CFRelease(rawChildren);
    }
    node[@"children"] = children;
    return node;
}

NSData *zxCopyAccessibilityTree(NSError **error)
{
    @synchronized([NSProcessInfo processInfo]) {
    void *frontBoard = dlopen("/System/Library/PrivateFrameworks/AXFrontBoardUtils.framework/AXFrontBoardUtils", RTLD_LAZY);
    ZXFocusedPID focusedPID = frontBoard ? (ZXFocusedPID)dlsym(frontBoard, "AXFrontBoardFocusedAppPID") : NULL;
    pid_t pid = focusedPID ? focusedPID() : 0;
    if (pid <= 0) {
        id app = getFrontMostApplication();
        for (NSString *name in @[@"processIdentifier", @"pid"]) {
            SEL selector = NSSelectorFromString(name);
            if (app && [app respondsToSelector:selector]) {
                pid = ((pid_t (*)(id, SEL))objc_msgSend)(app, selector);
                break;
            }
        }
    }
    const char *frameworks[] = {
        "/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime",
        "/System/Library/Frameworks/Accessibility.framework/Accessibility",
        "/System/Library/PrivateFrameworks/Accessibility.framework/Accessibility"
    };
    void *runtime = NULL;
    ZXCreateApplication create = NULL;
    zxCopyAttribute = NULL;
    zxValueType = NULL;
    zxValueGet = NULL;
    for (NSUInteger i = 0; i < sizeof(frameworks) / sizeof(frameworks[0]); ++i) {
        void *candidate = dlopen(frameworks[i], RTLD_LAZY | RTLD_GLOBAL);
        if (!candidate) continue;
        ZXCreateApplication nextCreate = (ZXCreateApplication)dlsym(candidate, "AXUIElementCreateApplication");
        if (!nextCreate) nextCreate = (ZXCreateApplication)dlsym(candidate, "_AXUIElementCreateAppElementWithPid");
        ZXCopyAttribute nextCopy = (ZXCopyAttribute)dlsym(candidate, "AXUIElementCopyAttributeValue");
        if (nextCreate && nextCopy) {
            runtime = candidate;
            create = nextCreate;
            zxCopyAttribute = nextCopy;
            zxValueType = (ZXValueType)dlsym(candidate, "AXValueGetType");
            zxValueGet = (ZXValueGet)dlsym(candidate, "AXValueGetValue");
            break;
        }
    }
    if (pid <= 0 || !create || !zxCopyAttribute) {
        if (error) *error = [NSError errorWithDomain:@"ZXTouchAX" code:1
                                            userInfo:@{NSLocalizedDescriptionKey: @"AX runtime or foreground PID unavailable"}];
        return nil;
    }
    ZXAssociatePID associate = (ZXAssociatePID)dlsym(runtime, "_AXAddAssociatedPid");
    if (associate) {
        associate(getpid(), pid, 1);
        associate(pid, getpid(), 1);
    }
    CFTypeRef application = create(pid);
    if (!application) {
        if (error) *error = [NSError errorWithDomain:@"ZXTouchAX" code:2
                                            userInfo:@{NSLocalizedDescriptionKey: @"AX application element unavailable"}];
        return nil;
    }
    ZXSetTimeout setTimeout = (ZXSetTimeout)dlsym(runtime, "AXUIElementSetMessagingTimeout");
    if (setTimeout) setTimeout(application, 5.0f);
    NSUInteger count = 0;
    NSDictionary *tree = nil;
    const useconds_t delays[] = {150000, 450000, 900000};
    for (NSUInteger attempt = 0; attempt < 4; ++attempt) {
        count = 0;
        tree = zxNode(application, 0, &count);
        if (count > 1) break;
        if (attempt < 3) usleep(delays[attempt]);
    }
    CFRelease(application);
    if (count <= 1) {
        if (error) *error = [NSError errorWithDomain:@"ZXTouchAX" code:3
                                            userInfo:@{NSLocalizedDescriptionKey: @"AX application returned no child elements"}];
        return nil;
    }
    return [NSJSONSerialization dataWithJSONObject:@{@"pid": @(pid), @"count": @(count),
                                                     @"root": tree} options:0 error:error];
    }
}
