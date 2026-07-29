#import <AppKit/AppKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <copyfile.h>
#import <dlfcn.h>
#import <sys/stat.h>

#import "hw_slicer_module.h"

static const HW_Slicer_Module_API *g_module;
static HW_Slicer_Host g_host;
static NSString *g_module_path;
static struct timespec g_module_time;
static unsigned long long g_generation;
static NSMutableArray<NSValue *> *g_loaded_handles;
static NSString *g_snapshot_path;
static NSString *g_resource_root;
static char *g_resource_root_bytes;

@interface HWSlicerWindow : NSWindow
@end

@implementation HWSlicerWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end

@interface HWSlicerAXElement : NSAccessibilityElement
@property(nonatomic) uint64_t controlID;
@end

@implementation HWSlicerAXElement
- (BOOL)accessibilityPerformPress {
    return g_module && g_module->activate_control(self.controlID);
}
@end

@interface HWSlicerView : NSView
@property(nonatomic) NSTrackingArea *trackingArea;
@end

static NSPoint slicer_event_point(HWSlicerView *view, NSEvent *event) {
    NSPoint point = [view convertPoint:event.locationInWindow fromView:nil];
    return NSMakePoint(point.x, view.bounds.size.height - point.y);
}

@implementation HWSlicerView
+ (Class)layerClass { return [CAMetalLayer class]; }
- (CALayer *)makeBackingLayer { return [CAMetalLayer layer]; }
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)isOpaque { return YES; }
- (BOOL)isAccessibilityElement { return NO; }
- (NSString *)accessibilityRole { return NSAccessibilityGroupRole; }
- (NSString *)accessibilityLabel { return @"HW Slicer"; }

- (void)updateTrackingAreas {
    if (self.trackingArea) {
        [self removeTrackingArea:self.trackingArea];
    }
    self.trackingArea = [[NSTrackingArea alloc]
        initWithRect:self.bounds
        options:NSTrackingMouseMoved | NSTrackingActiveInKeyWindow |
                NSTrackingInVisibleRect
        owner:self
        userInfo:nil];
    [self addTrackingArea:self.trackingArea];
    [super updateTrackingAreas];
}

- (NSArray *)accessibilityChildren {
    if (!g_module) { return @[]; }
    NSMutableArray *children = [NSMutableArray array];
    size_t count = g_module->control_count();
    for (size_t index = 0; index < count; ++index) {
        HW_Slicer_Control control = {0};
        if (!g_module->control_at(index, &control)) { continue; }
        HWSlicerAXElement *element = [HWSlicerAXElement new];
        element.controlID = control.id;
        element.accessibilityParent = self;
        element.accessibilityRole = control.role == 1
            ? NSAccessibilityRadioButtonRole
            : NSAccessibilityButtonRole;
        element.accessibilityLabel = [NSString
            stringWithUTF8String:control.label ? control.label : control.name];
        element.accessibilityIdentifier = [NSString
            stringWithUTF8String:control.name ? control.name : ""];
        element.accessibilityEnabled = control.enabled;
        NSRect local = NSMakeRect(
            control.rect.x,
            self.bounds.size.height - control.rect.y - control.rect.height,
            control.rect.width,
            control.rect.height
        );
        element.accessibilityFrame = [self.window convertRectToScreen:
            [self convertRect:local toView:nil]];
        [children addObject:element];
    }
    return children;
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint point = slicer_event_point(self, event);
    if (g_module && point.y < 40 &&
        g_module->hit_test(point.x, point.y) == 0) {
        if (event.clickCount == 2) {
            [self.window zoom:nil];
        } else {
            [self.window performWindowDragWithEvent:event];
        }
        return;
    }
    if (g_module) {
        g_module->mouse(0, 0, point.x, point.y, 0, 0);
    }
}
- (void)mouseDragged:(NSEvent *)event {
    NSPoint point = slicer_event_point(self, event);
    if (g_module) {
        g_module->mouse(
            1, 0, point.x, point.y, event.deltaX, -event.deltaY
        );
    }
}
- (void)mouseUp:(NSEvent *)event {
    NSPoint point = slicer_event_point(self, event);
    if (g_module) {
        g_module->mouse(2, 0, point.x, point.y, 0, 0);
    }
}
- (void)rightMouseDown:(NSEvent *)event {
    NSPoint point = slicer_event_point(self, event);
    if (g_module) { g_module->mouse(0, 1, point.x, point.y, 0, 0); }
}
- (void)rightMouseDragged:(NSEvent *)event {
    NSPoint point = slicer_event_point(self, event);
    if (g_module) {
        g_module->mouse(
            1, 1, point.x, point.y, event.deltaX, -event.deltaY
        );
    }
}
- (void)rightMouseUp:(NSEvent *)event {
    NSPoint point = slicer_event_point(self, event);
    if (g_module) { g_module->mouse(2, 1, point.x, point.y, 0, 0); }
}
- (void)otherMouseDown:(NSEvent *)event {
    NSPoint point = slicer_event_point(self, event);
    if (g_module) { g_module->mouse(0, 2, point.x, point.y, 0, 0); }
}
- (void)otherMouseDragged:(NSEvent *)event {
    NSPoint point = slicer_event_point(self, event);
    if (g_module) {
        g_module->mouse(
            1, 2, point.x, point.y, event.deltaX, -event.deltaY
        );
    }
}
- (void)otherMouseUp:(NSEvent *)event {
    NSPoint point = slicer_event_point(self, event);
    if (g_module) { g_module->mouse(2, 2, point.x, point.y, 0, 0); }
}
- (void)scrollWheel:(NSEvent *)event {
    if (g_module) { g_module->scroll(event.scrollingDeltaX, event.scrollingDeltaY); }
}
- (void)mouseMoved:(NSEvent *)event {
    NSPoint point = slicer_event_point(self, event);
    if (g_module) { g_module->mouse(3, -1, point.x, point.y, 0, 0); }
}
- (void)keyDown:(NSEvent *)event {
    if (!g_module) { return; }
    const char *characters = event.charactersIgnoringModifiers.UTF8String ?: "";
    g_module->key(event.keyCode, characters, event.modifierFlags);
}
@end

static void slicer_request_redraw(void) {
    [(__bridge NSView *)g_host.view setNeedsDisplay:YES];
}

static void slicer_window_close(void) {
    [(__bridge NSWindow *)g_host.window performClose:nil];
}

static void slicer_window_minimize(void) {
    [(__bridge NSWindow *)g_host.window miniaturize:nil];
}

static void slicer_window_zoom(void) {
    [(__bridge NSWindow *)g_host.window zoom:nil];
}

static bool slicer_open_stl_file(char *path, size_t capacity) {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    panel.allowedContentTypes = @[
        [UTType typeWithFilenameExtension:@"stl"]
    ];
    if ([panel runModal] != NSModalResponseOK) { return false; }
    const char *selected = panel.URL.path.fileSystemRepresentation;
    if (!selected || strlen(selected) + 1 > capacity) { return false; }
    strlcpy(path, selected, capacity);
    return true;
}

static int32_t slicer_preference_get_int(
    const char *key,
    int32_t fallback
) {
    NSString *name = [NSString stringWithUTF8String:key];
    NSNumber *value = [[NSUserDefaults standardUserDefaults] objectForKey:name];
    return value ? value.intValue : fallback;
}

static void slicer_preference_set_int(const char *key, int32_t value) {
    NSString *name = [NSString stringWithUTF8String:key];
    [[NSUserDefaults standardUserDefaults] setInteger:value forKey:name];
}

static bool slicer_module_stamp(NSString *path, struct timespec *stamp) {
    struct stat info = {0};
    if (stat(path.fileSystemRepresentation, &info) != 0) { return false; }
    *stamp = info.st_mtimespec;
    return true;
}

static bool slicer_same_stamp(struct timespec a, struct timespec b) {
    return a.tv_sec == b.tv_sec && a.tv_nsec == b.tv_nsec;
}

static bool slicer_load_module(bool initial) {
    struct timespec stamp = {0};
    if (!slicer_module_stamp(g_module_path, &stamp)) { return false; }
    if (!initial && slicer_same_stamp(stamp, g_module_time)) { return false; }
    g_module_time = stamp;

    NSString *directory = g_module_path.stringByDeletingLastPathComponent;
    NSString *shadow = [directory stringByAppendingPathComponent:
        [NSString stringWithFormat:@"slicer.generation-%llu.dylib",
            ++g_generation]];
    if (copyfile(
            g_module_path.fileSystemRepresentation,
            shadow.fileSystemRepresentation,
            NULL,
            COPYFILE_ALL
        ) != 0) {
        NSLog(@"HW Slicer could not stage module %@", shadow);
        return false;
    }

    void *handle = dlopen(shadow.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        NSLog(@"HW Slicer module load failed: %s", dlerror());
        return false;
    }
    HW_Slicer_Module_Entry entry = (HW_Slicer_Module_Entry)dlsym(
        handle,
        "hw_slicer_module_api"
    );
    if (!entry) {
        NSLog(@"HW Slicer module entry is missing");
        dlclose(handle);
        return false;
    }
    const HW_Slicer_Module_API *next = entry();
    if (!next || next->api_version != HW_SLICER_MODULE_API_VERSION ||
        next->snapshot_size > 4096) {
        NSLog(@"HW Slicer module contract is incompatible");
        dlclose(handle);
        return false;
    }

    _Alignas(16) uint8_t snapshot[4096] = {0};
    size_t snapshot_size = 0;
    if (g_module) {
        if (!g_module->can_reload()) {
            dlclose(handle);
            return false;
        }
        snapshot_size = g_module->snapshot_size;
        g_module->capture(snapshot, sizeof(snapshot));
        if (next->state_version != g_module->state_version ||
            next->snapshot_size != snapshot_size) {
            NSLog(@"HW Slicer state contract changed; restart required");
            dlclose(handle);
            return false;
        }
    }
    if (!next->initialize(
            &g_host,
            snapshot_size ? snapshot : NULL,
            snapshot_size
        )) {
        NSLog(@"HW Slicer rejected the staged module");
        dlclose(handle);
        return false;
    }

    const HW_Slicer_Module_API *previous = g_module;
    g_module = next;
    if (previous) { previous->shutdown(); }
    [g_loaded_handles addObject:[NSValue valueWithPointer:handle]];
    NSLog(@"HW Slicer activated module generation %llu", g_generation);
    return true;
}

@interface HWSlicerDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property(nonatomic) NSTimer *timer;
@end

@implementation HWSlicerDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    NSRect frame = NSMakeRect(0, 0, 1280, 800);
    HWSlicerWindow *window = [[HWSlicerWindow alloc]
        initWithContentRect:frame
        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered
        defer:NO];
    window.title = @"HW Slicer";
    window.delegate = self;
    window.opaque = YES;
    window.hasShadow = NO;
    window.backgroundColor = NSColor.blackColor;
    window.minSize = NSMakeSize(900, 600);
    window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;

    HWSlicerView *view = [[HWSlicerView alloc] initWithFrame:frame];
    view.wantsLayer = YES;
    CAMetalLayer *layer = (CAMetalLayer *)view.layer;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = YES;
    window.contentView = view;
    [window center];
    const char *activate = getenv("HW_SLICER_ACTIVATE_ON_LAUNCH");
    if (activate && strcmp(activate, "0") == 0) {
        [window orderBack:nil];
    } else {
        [window makeKeyAndOrderFront:nil];
    }
    [window makeFirstResponder:view];

    g_resource_root = NSBundle.mainBundle.resourcePath;
    g_resource_root_bytes = strdup(g_resource_root.fileSystemRepresentation);
    g_host.application = (__bridge void *)NSApp;
    g_host.window = (__bridge void *)window;
    g_host.view = (__bridge void *)view;
    g_host.layer = (__bridge void *)layer;
    g_host.resource_root = g_resource_root_bytes;
    g_host.request_redraw = slicer_request_redraw;
    g_host.window_close = slicer_window_close;
    g_host.window_minimize = slicer_window_minimize;
    g_host.window_zoom = slicer_window_zoom;
    g_host.open_stl_file = slicer_open_stl_file;
    g_host.preference_get_int = slicer_preference_get_int;
    g_host.preference_set_int = slicer_preference_set_int;

    if (!slicer_load_module(true)) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"HW Slicer could not load its viewer module.";
        alert.informativeText = g_module_path ?: @"No module path was supplied.";
        [alert runModal];
        [NSApp terminate:nil];
        return;
    }

    __block unsigned snapshotTick = 0;
    self.timer = [NSTimer
        scheduledTimerWithTimeInterval:1.0 / 60.0
        repeats:YES
        block:^(NSTimer *timer) {
            (void)timer;
            slicer_load_module(false);
            if (!g_module) { return; }
            NSRect bounds = view.bounds;
            double scale = window.backingScaleFactor;
            layer.contentsScale = scale;
            layer.drawableSize = CGSizeMake(
                bounds.size.width * scale,
                bounds.size.height * scale
            );
            g_module->frame(bounds.size.width, bounds.size.height, scale);
            if (g_snapshot_path && ++snapshotTick % 30 == 0) {
                g_module->write_ui_snapshot(
                    g_snapshot_path.fileSystemRepresentation
                );
            }
        }];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return YES;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    if (g_module) { g_module->shutdown(); }
    free(g_resource_root_bytes);
    g_resource_root_bytes = NULL;
}
@end

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        const char *module = getenv("HW_SLICER_MODULE");
        if (module) {
            g_module_path = [NSString stringWithUTF8String:module];
        } else {
            g_module_path = [[NSBundle mainBundle].executablePath
                .stringByDeletingLastPathComponent
                stringByAppendingPathComponent:@"slicer.dylib"];
        }
        const char *snapshot = getenv("HW_SLICER_UI_SNAPSHOT");
        if (snapshot) {
            g_snapshot_path = [NSString stringWithUTF8String:snapshot];
        }
        g_loaded_handles = [NSMutableArray array];
        NSApplication *application = [NSApplication sharedApplication];
        application.activationPolicy = NSApplicationActivationPolicyRegular;
        HWSlicerDelegate *delegate = [HWSlicerDelegate new];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
