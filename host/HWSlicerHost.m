#import <AppKit/AppKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "hw_slicer_application.h"

static const HW_Slicer_Application_API *g_application;
static bool g_application_initialized;
static HW_Slicer_Host g_host;
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
    return g_application && g_application->activate_control(self.controlID);
}
@end

@interface HWSlicerView : NSView
@property(nonatomic) NSTrackingArea *trackingArea;
@property(nonatomic) NSArray<HWSlicerAXElement *> *accessibilityControlElements;
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
- (BOOL)isAccessibilityElement { return YES; }
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
    if (!g_application) { return @[]; }
    NSMutableArray *children = [NSMutableArray array];
    size_t count = g_application->control_count();
    for (size_t index = 0; index < count; ++index) {
        HW_Slicer_Control control = {0};
        if (!g_application->control_at(index, &control)) { continue; }
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
        if (control.role == 1) {
            element.accessibilityValue = @(control.selected);
        }
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
    self.accessibilityControlElements = children;
    return self.accessibilityControlElements;
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint point = slicer_event_point(self, event);
    if (g_application && point.y < 40 &&
        g_application->hit_test(point.x, point.y) == 0) {
        if (event.clickCount == 2) {
            [self.window zoom:nil];
        } else {
            [self.window performWindowDragWithEvent:event];
        }
        return;
    }
    if (g_application) {
        g_application->mouse(0, 0, point.x, point.y, 0, 0);
    }
}
- (void)mouseDragged:(NSEvent *)event {
    NSPoint point = slicer_event_point(self, event);
    if (g_application) {
        g_application->mouse(
            1, 0, point.x, point.y, event.deltaX, -event.deltaY
        );
    }
}
- (void)mouseUp:(NSEvent *)event {
    NSPoint point = slicer_event_point(self, event);
    if (g_application) {
        g_application->mouse(2, 0, point.x, point.y, 0, 0);
    }
}
- (void)rightMouseDown:(NSEvent *)event {
    NSPoint point = slicer_event_point(self, event);
    if (g_application) {
        g_application->mouse(0, 1, point.x, point.y, 0, 0);
    }
}
- (void)rightMouseDragged:(NSEvent *)event {
    NSPoint point = slicer_event_point(self, event);
    if (g_application) {
        g_application->mouse(
            1, 1, point.x, point.y, event.deltaX, -event.deltaY
        );
    }
}
- (void)rightMouseUp:(NSEvent *)event {
    NSPoint point = slicer_event_point(self, event);
    if (g_application) {
        g_application->mouse(2, 1, point.x, point.y, 0, 0);
    }
}
- (void)otherMouseDown:(NSEvent *)event {
    NSPoint point = slicer_event_point(self, event);
    if (g_application) {
        g_application->mouse(0, 2, point.x, point.y, 0, 0);
    }
}
- (void)otherMouseDragged:(NSEvent *)event {
    NSPoint point = slicer_event_point(self, event);
    if (g_application) {
        g_application->mouse(
            1, 2, point.x, point.y, event.deltaX, -event.deltaY
        );
    }
}
- (void)otherMouseUp:(NSEvent *)event {
    NSPoint point = slicer_event_point(self, event);
    if (g_application) {
        g_application->mouse(2, 2, point.x, point.y, 0, 0);
    }
}
- (void)scrollWheel:(NSEvent *)event {
    if (g_application) {
        g_application->scroll(event.scrollingDeltaX, event.scrollingDeltaY);
    }
}
- (void)mouseMoved:(NSEvent *)event {
    NSPoint point = slicer_event_point(self, event);
    if (g_application) {
        g_application->mouse(3, -1, point.x, point.y, 0, 0);
    }
}
- (void)keyDown:(NSEvent *)event {
    if (!g_application) { return; }
    const char *characters = event.charactersIgnoringModifiers.UTF8String ?: "";
    g_application->key(event.keyCode, characters, event.modifierFlags);
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

static bool slicer_open_document(char *path, size_t capacity) {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = NO;
    panel.allowedContentTypes = @[
        [UTType typeWithFilenameExtension:@"stl"],
        [UTType typeWithFilenameExtension:@"hwsdebug"],
        [UTType typeWithIdentifier:@"public.folder"]
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
    g_host.open_document = slicer_open_document;
    g_host.preference_get_int = slicer_preference_get_int;
    g_host.preference_set_int = slicer_preference_set_int;

    if (!g_application->initialize(&g_host)) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"HW Slicer could not initialize its viewer.";
        [alert runModal];
        [NSApp terminate:nil];
        return;
    }
    g_application_initialized = true;

    __block unsigned snapshotTick = 0;
    self.timer = [NSTimer
        scheduledTimerWithTimeInterval:1.0 / 60.0
        repeats:YES
        block:^(NSTimer *timer) {
            (void)timer;
            NSRect bounds = view.bounds;
            double scale = window.backingScaleFactor;
            layer.contentsScale = scale;
            layer.drawableSize = CGSizeMake(
                bounds.size.width * scale,
                bounds.size.height * scale
            );
            g_application->frame(bounds.size.width, bounds.size.height, scale);
            if (g_snapshot_path && ++snapshotTick % 30 == 0) {
                g_application->write_ui_snapshot(
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
    if (g_application_initialized) {
        g_application->shutdown();
        g_application_initialized = false;
    }
    free(g_resource_root_bytes);
    g_resource_root_bytes = NULL;
}
@end

int32_t hw_slicer_host_run(const HW_Slicer_Application_API *applicationAPI) {
    if (!applicationAPI || !applicationAPI->initialize ||
        !applicationAPI->shutdown || !applicationAPI->frame ||
        !applicationAPI->mouse || !applicationAPI->scroll ||
        !applicationAPI->key || !applicationAPI->control_count ||
        !applicationAPI->control_at || !applicationAPI->hit_test ||
        !applicationAPI->activate_control ||
        !applicationAPI->write_ui_snapshot) {
        return 2;
    }
    @autoreleasepool {
        g_application = applicationAPI;
        const char *snapshot = getenv("HW_SLICER_UI_SNAPSHOT");
        if (snapshot) {
            g_snapshot_path = [NSString stringWithUTF8String:snapshot];
        }
        NSApplication *application = [NSApplication sharedApplication];
        application.activationPolicy = NSApplicationActivationPolicyRegular;
        HWSlicerDelegate *delegate = [HWSlicerDelegate new];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
