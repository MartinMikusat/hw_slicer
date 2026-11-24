#import <AppKit/AppKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "hw_slicer_application.h"

static const HW_Slicer_Application_API *g_application;
static bool g_application_initialized;
static bool g_window_ready;
static HW_Slicer_Host g_host;
static NSString *g_snapshot_path;
static NSString *g_resource_root;
static char *g_resource_root_bytes;

static NSString *const kWindowFrameKey = @"HWSlicerWindowFrame";
static NSString *const kWindowZoomedKey = @"HWSlicerWindowZoomed";
static NSString *const kWindowRestoreFrameKey = @"HWSlicerWindowRestoreFrame";

static void slicer_window_zoom(void);
static NSScreen *slicer_screen_for_rect(NSRect r);

@interface HWSlicerWindow : NSWindow
@property(nonatomic) NSRect restoreFrame;
@property(nonatomic) NSRect zoomFrame;
@property(nonatomic) BOOL hasRestoreFrame;
@property(nonatomic) BOOL inWindowDrag;
@property(nonatomic) BOOL screenChangedDuringDrag;
@property(nonatomic) BOOL adjustingFrame;
@end

static void slicer_fit_window_to_screen(HWSlicerWindow *window);

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
- (BOOL)accessibilityPerformIncrement {
    return g_application && g_application->adjust_control(self.controlID, 1);
}
- (BOOL)accessibilityPerformDecrement {
    return g_application && g_application->adjust_control(self.controlID, -1);
}
@end

@interface HWSlicerView : NSView
@property(nonatomic) NSTrackingArea *trackingArea;
@property(nonatomic) NSArray<HWSlicerAXElement *> *accessibilityControlElements;
@end

static NSPoint slicer_event_point(HWSlicerView *view, NSEvent *event) {
    return [view convertPoint:event.locationInWindow fromView:nil];
}

@implementation HWSlicerView
+ (Class)layerClass { return [CAMetalLayer class]; }
- (CALayer *)makeBackingLayer { return [CAMetalLayer layer]; }
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (BOOL)isOpaque { return YES; }
- (BOOL)isAccessibilityElement { return YES; }
- (NSString *)accessibilityRole { return NSAccessibilityGroupRole; }
- (NSString *)accessibilityLabel { return @"hw_slicer"; }

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
        NSString *name = [[NSString alloc] initWithBytes:control.name
            length:control.name_length encoding:NSUTF8StringEncoding];
        NSString *label = [[NSString alloc] initWithBytes:control.label
            length:control.label_length encoding:NSUTF8StringEncoding];
        NSAssert(name && label, @"Control labels must be valid UTF-8");
        if (!name || !label) { continue; }
        HWSlicerAXElement *element = [HWSlicerAXElement new];
        element.controlID = control.id;
        element.accessibilityParent = self;
        switch (control.role) {
        case 1: element.accessibilityRole = NSAccessibilityRadioButtonRole; break;
        case 2: element.accessibilityRole = NSAccessibilityCheckBoxRole; break;
        case 3: element.accessibilityRole = NSAccessibilitySliderRole; break;
        default: element.accessibilityRole = NSAccessibilityButtonRole; break;
        }
        element.accessibilityLabel = label;
        element.accessibilityIdentifier = name;
        element.accessibilityEnabled = control.enabled;
        if (control.role == 1 || control.role == 2) {
            element.accessibilityValue = @(control.selected);
        } else if (control.role == 3) {
            element.accessibilityValue = @(control.value);
            element.accessibilityMinValue = @(control.minimum);
            element.accessibilityMaxValue = @(control.maximum);
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
            slicer_window_zoom();
        } else {
            HWSlicerWindow *window = (HWSlicerWindow *)self.window;
            window.inWindowDrag = YES;
            window.screenChangedDuringDrag = NO;
            [window performWindowDragWithEvent:event];
            window.inWindowDrag = NO;
            NSScreen *screen = window.screen ?: slicer_screen_for_rect(window.frame);
            if (screen) {
                NSRect visible = screen.visibleFrame;
                NSRect frame = window.frame;
                BOOL needsFit = window.screenChangedDuringDrag ||
                    frame.size.width > visible.size.width ||
                    frame.size.height > visible.size.height ||
                    NSMaxY(frame) > NSMaxY(visible) ||
                    NSMaxY(frame) < visible.origin.y + 40.0;
                if (needsFit) {
                    slicer_fit_window_to_screen(window);
                }
            }
            window.screenChangedDuringDrag = NO;
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
            1, 0, point.x, point.y, event.deltaX, event.deltaY
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
            1, 1, point.x, point.y, event.deltaX, event.deltaY
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
            1, 2, point.x, point.y, event.deltaX, event.deltaY
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
        NSPoint point = slicer_event_point(self, event);
        g_application->mouse(4, -1, point.x, point.y, 0, 0);
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
    NSString *unmodified = event.charactersIgnoringModifiers ?: @"";
    if (event.modifierFlags & NSEventModifierFlagCommand) {
        if ([unmodified caseInsensitiveCompare:@"w"] == NSOrderedSame) {
            [self.window close];
            return;
        }
        if ([unmodified caseInsensitiveCompare:@"q"] == NSOrderedSame) {
            [NSApp terminate:nil];
            return;
        }
    }
    NSString *text = (event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl))
        ? unmodified
        : (event.characters ?: unmodified);
    const char *characters = text.UTF8String ?: "";
    g_application->key(event.keyCode, characters, event.modifierFlags);
}
@end

static void slicer_request_redraw(void) {
    [(__bridge NSView *)g_host.view setNeedsDisplay:YES];
}

static void slicer_window_close(void) {
    [(__bridge NSWindow *)g_host.window close];
}

static void slicer_window_minimize(void) {
    NSWindow *window = (__bridge NSWindow *)g_host.window;
    NSWindowStyleMask style = window.styleMask;
    window.styleMask = style | NSWindowStyleMaskTitled;
    [window miniaturize:nil];
    window.styleMask = style;
}

static BOOL slicer_rect_is_valid(NSRect r) {
    return isfinite(r.origin.x) && isfinite(r.origin.y) &&
           isfinite(r.size.width) && isfinite(r.size.height) &&
           r.size.width >= 320.0 && r.size.height >= 240.0 &&
           r.size.width <= 20000.0 && r.size.height <= 20000.0;
}

static NSRect slicer_clamp_rect_to_rect(NSRect frame, NSRect visible) {
    if (frame.size.width > visible.size.width) {
        frame.size.width = visible.size.width;
    }
    if (frame.size.height > visible.size.height) {
        frame.size.height = visible.size.height;
    }
    if (frame.origin.x < visible.origin.x) {
        frame.origin.x = visible.origin.x;
    }
    if (NSMaxX(frame) > NSMaxX(visible)) {
        frame.origin.x = NSMaxX(visible) - frame.size.width;
    }
    if (frame.origin.y < visible.origin.y) {
        frame.origin.y = visible.origin.y;
    }
    if (NSMaxY(frame) > NSMaxY(visible)) {
        frame.origin.y = NSMaxY(visible) - frame.size.height;
    }
    return frame;
}

static void slicer_update_min_size(HWSlicerWindow *window, NSRect visible) {
    if (!window || visible.size.width < 320.0 || visible.size.height < 240.0) { return; }
    window.minSize = NSMakeSize(
        fmin(900.0, visible.size.width),
        fmin(600.0, visible.size.height)
    );
}

static void slicer_sync_layer_for_window(HWSlicerWindow *window) {
    if (!window) { return; }
    NSView *view = window.contentView;
    if (!view) { return; }
    CAMetalLayer *layer = (CAMetalLayer *)view.layer;
    double scale = window.backingScaleFactor;
    if (scale > 0.0 && layer) {
        layer.contentsScale = scale;
        layer.drawableSize = CGSizeMake(
            view.bounds.size.width * scale,
            view.bounds.size.height * scale
        );
    }
    [view setNeedsDisplay:YES];
}

static NSScreen *slicer_screen_for_rect(NSRect r) {
    NSScreen *best = nil;
    CGFloat bestArea = 0.0;
    for (NSScreen *screen in [NSScreen screens]) {
        NSRect overlap = NSIntersectionRect(r, screen.visibleFrame);
        CGFloat area = overlap.size.width * overlap.size.height;
        if (area > bestArea) {
            bestArea = area;
            best = screen;
        }
    }
    return best ?: ([NSScreen mainScreen] ?: NSScreen.screens.firstObject);
}

static void slicer_save_window_state(HWSlicerWindow *window) {
    if (!g_window_ready || !window) { return; }
    NSRect frame = window.frame;
    if (!slicer_rect_is_valid(frame)) { return; }
    NSScreen *screen = window.screen ?: slicer_screen_for_rect(frame);
    BOOL zoomed = (window.hasRestoreFrame && NSEqualRects(frame, window.zoomFrame)) ||
                  (screen && NSEqualRects(frame, screen.visibleFrame));
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:NSStringFromRect(frame) forKey:kWindowFrameKey];
    [defaults setBool:zoomed forKey:kWindowZoomedKey];
    if (window.hasRestoreFrame && slicer_rect_is_valid(window.restoreFrame)) {
        [defaults setObject:NSStringFromRect(window.restoreFrame) forKey:kWindowRestoreFrameKey];
    } else if (!zoomed) {
        [defaults setObject:NSStringFromRect(frame) forKey:kWindowRestoreFrameKey];
    }
}

static void slicer_fit_window_to_screen(HWSlicerWindow *window) {
    if (!window || !g_window_ready || window.adjustingFrame) { return; }
    if ((window.styleMask & NSWindowStyleMaskFullScreen) != 0 || window.isMiniaturized) {
        return;
    }
    NSScreen *screen = window.screen ?: slicer_screen_for_rect(window.frame);
    if (!screen) { return; }
    NSRect visible = screen.visibleFrame;
    if (visible.size.width < 320.0 || visible.size.height < 240.0) { return; }
    slicer_update_min_size(window, visible);

    BOOL wasZoomed = window.hasRestoreFrame &&
        (NSEqualRects(window.frame, window.zoomFrame) ||
         NSEqualSizes(window.frame.size, window.zoomFrame.size));
    NSRect target;
    if (wasZoomed) {
        target = visible;
        window.zoomFrame = visible;
    } else {
        target = slicer_clamp_rect_to_rect(window.frame, visible);
    }

    if (!NSEqualRects(window.frame, target)) {
        window.adjustingFrame = YES;
        [window setFrame:target display:YES];
        window.adjustingFrame = NO;
    }
    slicer_sync_layer_for_window(window);
    slicer_save_window_state(window);
}

static BOOL slicer_restore_window_state(HWSlicerWindow *window) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *frameStr = [defaults stringForKey:kWindowFrameKey];
    NSString *restoreStr = [defaults stringForKey:kWindowRestoreFrameKey];
    BOOL zoomed = [defaults boolForKey:kWindowZoomedKey];
    NSRect savedFrame = frameStr ? NSRectFromString(frameStr) : NSZeroRect;
    NSRect restoreFrame = restoreStr ? NSRectFromString(restoreStr) : NSZeroRect;

    if (zoomed) {
        NSScreen *screen = slicer_rect_is_valid(savedFrame)
            ? slicer_screen_for_rect(savedFrame)
            : ([NSScreen mainScreen] ?: NSScreen.screens.firstObject);
        if (!screen) { return NO; }
        NSRect visible = screen.visibleFrame;
        slicer_update_min_size(window, visible);
        if (!slicer_rect_is_valid(restoreFrame)) {
            restoreFrame = NSMakeRect(
                NSMidX(visible) - 640.0,
                NSMidY(visible) - 400.0,
                1280.0,
                800.0
            );
        }
        window.restoreFrame = restoreFrame;
        window.zoomFrame = visible;
        window.hasRestoreFrame = YES;
        [window setFrame:visible display:NO];
        return YES;
    }

    if (!slicer_rect_is_valid(savedFrame)) { return NO; }
    NSScreen *screen = slicer_screen_for_rect(savedFrame);
    if (!screen) { return NO; }
    NSRect visible = screen.visibleFrame;
    slicer_update_min_size(window, visible);
    savedFrame = slicer_clamp_rect_to_rect(savedFrame, visible);
    [window setFrame:savedFrame display:NO];
    return YES;
}

static void slicer_window_zoom(void) {
    HWSlicerWindow *window = (__bridge HWSlicerWindow *)g_host.window;
    NSScreen *screen = window.screen ?: slicer_screen_for_rect(window.frame);
    if (!screen) { return; }
    NSRect visible = screen.visibleFrame;
    slicer_update_min_size(window, visible);
    window.adjustingFrame = YES;
    if (window.hasRestoreFrame && NSEqualRects(window.frame, window.zoomFrame)) {
        NSRect target = slicer_clamp_rect_to_rect(window.restoreFrame, visible);
        [window setFrame:target display:YES];
        window.hasRestoreFrame = NO;
    } else {
        window.restoreFrame = window.frame;
        window.zoomFrame = visible;
        window.hasRestoreFrame = YES;
        [window setFrame:window.zoomFrame display:YES];
    }
    window.adjustingFrame = NO;
    slicer_sync_layer_for_window(window);
    slicer_save_window_state(window);
}

static bool slicer_open_document(char *path, size_t capacity) {
    NSWindow *window = (__bridge NSWindow *)g_host.window;
    [NSApp activateIgnoringOtherApps:YES];
    [window makeKeyAndOrderFront:nil];
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    panel.allowedContentTypes = @[
        [UTType typeWithFilenameExtension:@"stl"],
        [UTType typeWithFilenameExtension:@"hwsdebug"],
        [UTType typeWithFilenameExtension:@"hwsdesign"]
    ];
    NSModalResponse response = [panel runModal];
    [window makeKeyAndOrderFront:nil];
    [(__bridge NSView *)g_host.view setNeedsDisplay:YES];
    if (response != NSModalResponseOK) { return false; }
    const char *selected = panel.URL.path.fileSystemRepresentation;
    if (!selected || strlen(selected) + 1 > capacity) { return false; }
    strlcpy(path, selected, capacity);
    return true;
}

static bool slicer_save_document(const char *suggested_name, char *path, size_t capacity) {
    NSWindow *window = (__bridge NSWindow *)g_host.window;
    [NSApp activateIgnoringOtherApps:YES];
    [window makeKeyAndOrderFront:nil];
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.canCreateDirectories = YES;
    if (suggested_name && suggested_name[0] != '\0') {
        panel.nameFieldStringValue = [NSString stringWithUTF8String:suggested_name];
    }
    NSModalResponse response = [panel runModal];
    [window makeKeyAndOrderFront:nil];
    [(__bridge NSView *)g_host.view setNeedsDisplay:YES];
    if (response != NSModalResponseOK) { return false; }
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
        styleMask:NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered
        defer:NO];
    window.title = @"hw_slicer";
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
    if (!slicer_restore_window_state(window)) {
        [window center];
        NSScreen *screen = window.screen ?: slicer_screen_for_rect(window.frame);
        if (screen) {
            NSRect visible = screen.visibleFrame;
            slicer_update_min_size(window, visible);
            NSRect clamped = slicer_clamp_rect_to_rect(window.frame, visible);
            if (!NSEqualRects(window.frame, clamped)) {
                [window setFrame:clamped display:NO];
            }
        }
    }
    view.frame = window.contentView.bounds;
    g_window_ready = true;
    const char *activate = getenv("HW_SLICER_ACTIVATE_ON_LAUNCH");
    if (activate && strcmp(activate, "0") == 0) {
        [window orderBack:nil];
    } else {
        [NSApp activateIgnoringOtherApps:YES];
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
    g_host.save_document = slicer_save_document;
    g_host.preference_get_int = slicer_preference_get_int;
    g_host.preference_set_int = slicer_preference_set_int;

    if (!g_application->initialize(&g_host)) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"hw_slicer could not initialize its viewer.";
        [alert runModal];
        [NSApp terminate:nil];
        return;
    }
    g_application_initialized = true;

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{
            if (g_application && g_application_initialized &&
                g_application->window_state) {
                g_application->window_state(window.visible, NSApp.isActive);
            }
        }
    );

    __block unsigned snapshotTick = 0;
    self.timer = [NSTimer
        scheduledTimerWithTimeInterval:1.0 / 120.0
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
            if ([NSApp modalWindow] != nil) { return; }
            g_application->frame(bounds.size.width, bounds.size.height, scale);
            if (g_snapshot_path && ++snapshotTick % 30 == 0) {
                g_application->write_ui_snapshot(
                    g_snapshot_path.fileSystemRepresentation
                );
            }
        }];
}

- (void)windowDidMove:(NSNotification *)notification {
    HWSlicerWindow *window = notification.object;
    if (window.adjustingFrame) { return; }
    if (window.hasRestoreFrame &&
        (window.inWindowDrag || !NSEqualSizes(window.frame.size, window.zoomFrame.size))) {
        window.hasRestoreFrame = NO;
    }
    slicer_save_window_state(window);
}

- (void)windowDidResize:(NSNotification *)notification {
    HWSlicerWindow *window = notification.object;
    if (window.adjustingFrame) { return; }
    if (window.hasRestoreFrame && !NSEqualRects(window.frame, window.zoomFrame)) {
        window.hasRestoreFrame = NO;
    }
    slicer_save_window_state(window);
}

- (void)windowDidChangeScreen:(NSNotification *)notification {
    HWSlicerWindow *window = notification.object;
    if (!window) { return; }
    if (window.inWindowDrag) {
        window.screenChangedDuringDrag = YES;
        slicer_sync_layer_for_window(window);
        return;
    }
    slicer_fit_window_to_screen(window);
}

- (void)windowDidChangeBackingProperties:(NSNotification *)notification {
    HWSlicerWindow *window = notification.object;
    if (!window) { return; }
    slicer_sync_layer_for_window(window);
}

- (void)windowDidDeminiaturize:(NSNotification *)notification {
    HWSlicerWindow *window = notification.object;
    if (!window) { return; }
    slicer_fit_window_to_screen(window);
}

- (void)applicationDidChangeScreenParameters:(NSNotification *)notification {
    (void)notification;
    HWSlicerWindow *window = (__bridge HWSlicerWindow *)g_host.window;
    if (!window || !g_window_ready) { return; }
    slicer_fit_window_to_screen(window);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_window_ready || !g_host.window) { return; }
        HWSlicerWindow *current = (__bridge HWSlicerWindow *)g_host.window;
        slicer_fit_window_to_screen(current);
    });
}

- (void)windowWillClose:(NSNotification *)notification {
    HWSlicerWindow *window = notification.object;
    slicer_save_window_state(window);
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return YES;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    if (g_host.window) {
        slicer_save_window_state((__bridge HWSlicerWindow *)g_host.window);
    }
    g_window_ready = false;
    if (g_application_initialized) {
        g_application->shutdown();
        g_application_initialized = false;
    }
    free(g_resource_root_bytes);
    g_resource_root_bytes = NULL;
}
@end

int32_t hw_slicer_replace_design(const char *path, const uint8_t *expected, intptr_t expectedSize,
                                 const uint8_t *source, intptr_t sourceSize,
                                 const char *stagedGcode, const char *destination) {
    @autoreleasepool {
        NSURL *url = [NSURL fileURLWithFileSystemRepresentation:path isDirectory:NO relativeToURL:nil];
        NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        __block HW_Design_Write_Result result = HW_DESIGN_WRITE_FAILED;
        NSError *coordinationError = nil;
        [coordinator coordinateWritingItemAtURL:url options:NSFileCoordinatorWritingForReplacing
                                         error:&coordinationError byAccessor:^(NSURL *target) {
            NSNumber *size = nil;
            if (![target getResourceValue:&size forKey:NSURLFileSizeKey error:nil] ||
                size.unsignedLongLongValue != (NSUInteger)expectedSize) {
                result = HW_DESIGN_WRITE_CONFLICT;
                return;
            }
            NSData *disk = [NSData dataWithContentsOfURL:target options:NSDataReadingMappedIfSafe error:nil];
            if (!disk || disk.length != (NSUInteger)expectedSize ||
                memcmp(disk.bytes, expected, (size_t)expectedSize) != 0) {
                result = HW_DESIGN_WRITE_CONFLICT;
                return;
            }
            NSData *replacement = [NSData dataWithBytes:source length:(NSUInteger)sourceSize];
            if ([replacement isEqualToData:disk] || [replacement writeToURL:target atomically:YES]) {
                result = rename(stagedGcode, destination) == 0
                    ? HW_DESIGN_WRITE_SAVED : HW_DESIGN_WRITE_GCODE_FAILED;
            }
        }];
        return coordinationError ? HW_DESIGN_WRITE_FAILED : result;
    }
}

int32_t hw_slicer_host_run(const HW_Slicer_Application_API *applicationAPI) {
    if (!applicationAPI || !applicationAPI->initialize ||
        !applicationAPI->shutdown || !applicationAPI->frame ||
        !applicationAPI->mouse || !applicationAPI->scroll ||
        !applicationAPI->key || !applicationAPI->control_count ||
        !applicationAPI->control_at || !applicationAPI->hit_test ||
        !applicationAPI->activate_control || !applicationAPI->adjust_control ||
        !applicationAPI->write_ui_snapshot ||
        !applicationAPI->window_state) {
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
        NSString *iconPath = [[NSBundle mainBundle] pathForResource:@"AppIcon" ofType:@"icns"];
        NSImage *icon = iconPath != nil ? [[NSImage alloc] initWithContentsOfFile:iconPath] : nil;
        if (icon != nil) { application.applicationIconImage = icon; }
        HWSlicerDelegate *delegate = [HWSlicerDelegate new];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
