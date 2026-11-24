#import <Foundation/Foundation.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

enum { MR_OPEN = 1, MR_MESSAGE, MR_CLOSED, MR_HTTP, MR_SEND_ERROR };
enum { MR_MESSAGE_MAX = 4 * 1024 * 1024, MR_TRANSFER_MAX = 32 * 1024 * 1024,
       MR_EVENTS_MAX = 32, MR_QUEUE_BYTES_MAX = 40 * 1024 * 1024 };

typedef void (*MRWake)(void *);
typedef struct { int32_t kind, status; int64_t id; void *bytes; int64_t length; } MREvent;

@interface MRTransport : NSObject <NSURLSessionWebSocketDelegate, NSURLSessionDataDelegate>
@property NSURLSession *session;
@property NSURLSessionWebSocketTask *socket;
@property NSURL *baseURL;
@property NSString *apiKey;
@property NSMutableArray<NSValue *> *events;
@property NSMutableData *httpData;
@property NSURLSessionDataTask *httpTask;
@property int64_t httpID;
@property NSInteger httpStatus;
@property NSUInteger httpLimit;
@property NSUInteger queuedBytes;
@property BOOL stopped, failed, socketClosed, wakePending;
@property int32_t accessMode;
@property MRWake wake;
@property void *wakeData;
- (void)enqueue:(int32_t)kind status:(int32_t)status id:(int64_t)identifier data:(NSData *)data;
- (void)receive;
@end

@implementation MRTransport
- (void)scheduleWake {
    if (self.wakePending || !self.wake || self.stopped) return;
    self.wakePending = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        @synchronized (self) {
            self.wakePending = NO;
            if (!self.stopped && self.wake) self.wake(self.wakeData);
        }
    });
}
- (void)enqueue:(int32_t)kind status:(int32_t)status id:(int64_t)identifier data:(NSData *)data {
    @synchronized (self) {
        if (self.stopped || self.failed) return;
        if (self.events.count == MR_EVENTS_MAX || data.length > MR_TRANSFER_MAX ||
            self.queuedBytes + data.length > MR_QUEUE_BYTES_MAX) {
            self.failed = YES;
            [self.socket cancelWithCloseCode:NSURLSessionWebSocketCloseCodeMessageTooBig reason:nil];
            [self.httpTask cancel];
            [self scheduleWake];
            return;
        }
        MREvent event = {kind, status, identifier, NULL, (int64_t)data.length};
        if (data.length) {
            event.bytes = malloc(data.length);
            if (!event.bytes) { self.failed = YES; [self scheduleWake]; return; }
            memcpy(event.bytes, data.bytes, data.length);
        }
        self.queuedBytes += data.length;
        [self.events addObject:[NSValue valueWithBytes:&event objCType:@encode(MREvent)]];
        [self scheduleWake];
    }
}
- (void)closed:(NSError *)error {
    @synchronized (self) {
        if (self.stopped || self.socketClosed) return;
        self.socketClosed = YES;
        NSInteger status = [(NSHTTPURLResponse *)self.socket.response statusCode];
        NSData *data = [(error.localizedDescription ?: @"Connection closed") dataUsingEncoding:NSUTF8StringEncoding];
        [self enqueue:MR_CLOSED status:(int32_t)status id:0 data:data];
    }
}
- (void)receive {
    [self.socket receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
        @synchronized (self) {
            if (self.stopped || self.socketClosed || self.failed) return;
            if (error) { [self closed:error]; return; }
            if (message.type != NSURLSessionWebSocketMessageTypeString) {
                [self closed:[NSError errorWithDomain:@"hw_ratos" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Expected WebSocket text frame"}]];
                [self.socket cancelWithCloseCode:NSURLSessionWebSocketCloseCodeUnsupportedData reason:nil];
                return;
            }
            NSData *data = [message.string dataUsingEncoding:NSUTF8StringEncoding];
            if (data.length > MR_MESSAGE_MAX) { self.failed = YES; [self scheduleWake]; return; }
            [self enqueue:MR_MESSAGE status:0 id:0 data:data];
            if (!self.failed) [self receive];
        }
    }];
}
- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)task didOpenWithProtocol:(NSString *)protocol {
    [self enqueue:MR_OPEN status:0 id:0 data:nil];
    [self receive];
}
- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)task didCloseWithCode:(NSURLSessionWebSocketCloseCode)code reason:(NSData *)reason {
    [self closed:nil];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (task == self.socket) { [self closed:error]; return; }
    @synchronized (self) {
        if (task != self.httpTask) return;
        NSData *data = error ? [error.localizedDescription dataUsingEncoding:NSUTF8StringEncoding] : self.httpData;
        [self enqueue:MR_HTTP status:error ? -1 : (int32_t)self.httpStatus id:self.httpID data:data];
        self.httpTask = nil;
        self.httpData = nil;
        self.httpID = 0;
    }
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completion {
    @synchronized (self) {
        if (task != self.httpTask || self.stopped || response.expectedContentLength > (int64_t)self.httpLimit) {
            completion(NSURLSessionResponseCancel); return;
        }
        self.httpStatus = [(NSHTTPURLResponse *)response statusCode];
        completion(NSURLSessionResponseAllow);
    }
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    @synchronized (self) {
        if (task != self.httpTask || self.stopped) return;
        if (data.length > self.httpLimit - self.httpData.length) { [task cancel]; return; }
        [self.httpData appendData:data];
    }
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completion {
    completion(nil);
}
- (void)URLSession:(NSURLSession *)session didBecomeInvalidWithError:(NSError *)error {
    self.session = nil;
}
@end

static NSString *MRString(const void *bytes, int64_t length) {
    if (length < 0 || length > MR_TRANSFER_MAX || (!bytes && length)) return nil;
    return [[NSString alloc] initWithBytes:bytes length:(NSUInteger)length encoding:NSUTF8StringEncoding];
}

void *mr_native_connect(const void *endpoint, int64_t endpointLength, const void *key, int64_t keyLength, int32_t accessMode, MRWake wake, void *wakeData) {
    @autoreleasepool {
        if (endpointLength <= 0 || endpointLength > 2048 || keyLength < 0 || keyLength > 512 ||
            accessMode < 0 || accessMode > 2) return NULL;
        NSString *text = MRString(endpoint, endpointLength);
        NSString *apiKey = MRString(key, keyLength);
        if (!text || !apiKey) return NULL;
        NSURLComponents *parts = [NSURLComponents componentsWithString:text];
        if (!parts.host.length ||
            (! [parts.scheme isEqualToString:@"http"] && ![parts.scheme isEqualToString:@"https"]) ||
            parts.user || parts.password || parts.query || parts.fragment) return NULL;
        NSString *base = text;
        while ([base hasSuffix:@"/"]) base = [base substringToIndex:base.length - 1];
        NSURL *baseURL = [NSURL URLWithString:base];
        parts = [NSURLComponents componentsWithString:[base stringByAppendingString:@"/websocket"]];
        parts.scheme = [parts.scheme isEqualToString:@"https"] ? @"wss" : @"ws";
        if (!parts.URL || !baseURL) return NULL;
        MRTransport *transport = [MRTransport new];
        transport.baseURL = baseURL;
        transport.apiKey = apiKey;
        transport.accessMode = accessMode;
        transport.events = [NSMutableArray new];
        transport.wake = wake;
        transport.wakeData = wakeData;
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.timeoutIntervalForRequest = 15;
        configuration.timeoutIntervalForResource = 7 * 24 * 3600;
        configuration.HTTPShouldSetCookies = NO;
        configuration.URLCache = nil;
        NSOperationQueue *queue = [NSOperationQueue new];
        queue.maxConcurrentOperationCount = 1;
        transport.session = [NSURLSession sessionWithConfiguration:configuration delegate:transport delegateQueue:queue];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:parts.URL];
        if (apiKey.length) [request setValue:apiKey forHTTPHeaderField:@"X-Api-Key"];
        transport.socket = [transport.session webSocketTaskWithRequest:request];
        transport.socket.maximumMessageSize = MR_MESSAGE_MAX;
        [transport.socket resume];
        return (__bridge_retained void *)transport;
    }
}

void mr_native_wake(void *handle, MRWake wake, void *userdata) {
    MRTransport *transport = (__bridge MRTransport *)handle;
    @synchronized (transport) { transport.wake = wake; transport.wakeData = userdata; }
}

void mr_native_destroy(void *handle) {
    if (!handle) return;
    MRTransport *transport = (__bridge_transfer MRTransport *)handle;
    @synchronized (transport) {
        transport.stopped = YES;
        transport.wake = NULL;
        transport.wakeData = NULL;
        for (NSValue *value in transport.events) { MREvent event; [value getValue:&event]; free(event.bytes); }
        [transport.events removeAllObjects];
        transport.queuedBytes = 0;
        transport.apiKey = nil;
        transport.httpData = nil;
        [transport.socket cancelWithCloseCode:NSURLSessionWebSocketCloseCodeGoingAway reason:nil];
        [transport.session invalidateAndCancel];
    }
}

int32_t mr_native_poll(void *handle, MREvent *event) {
    MRTransport *transport = (__bridge MRTransport *)handle;
    @synchronized (transport) {
        if (transport.failed) {
            transport.failed = NO;
            *event = (MREvent){MR_CLOSED, -1, 0, NULL, 0};
            return 1;
        }
        if (!transport.events.count || transport.stopped) return 0;
        [transport.events.firstObject getValue:event];
        [transport.events removeObjectAtIndex:0];
        transport.queuedBytes -= (NSUInteger)event->length;
        return 1;
    }
}

void mr_native_event_release(MREvent *event) { free(event->bytes); *event = (MREvent){0}; }

static BOOL MRReadOnlyMethod(NSString *method) {
    return [method isEqualToString:@"server.info"] || [method isEqualToString:@"printer.info"] ||
        [method isEqualToString:@"printer.objects.list"] || [method isEqualToString:@"printer.objects.subscribe"] ||
        [method isEqualToString:@"printer.gcode.help"] || [method isEqualToString:@"server.files.list"] ||
        [method isEqualToString:@"server.files.roots"] || [method isEqualToString:@"server.files.metadata"] ||
        [method isEqualToString:@"server.temperature_store"];
}

static BOOL MRHeaterScript(id value) {
    if (![value isKindOfClass:[NSString class]] || [value length] > 512) return NO;
    NSString *pattern = @"\\ASET_(?:HEATER_TEMPERATURE HEATER|TEMPERATURE_FAN_TARGET TEMPERATURE_FAN)=[A-Za-z0-9_]{1,128} TARGET=(?:0|[1-9][0-9]{0,308})\\.[0-9]{3}\\z";
    if ([value rangeOfString:pattern options:NSRegularExpressionSearch].location == NSNotFound) return NO;
    NSRange target = [value rangeOfString:@" TARGET="];
    return isfinite([[value substringFromIndex:NSMaxRange(target)] doubleValue]);
}

static BOOL MRHomingScript(id value) {
    return [value isKindOfClass:[NSString class]] &&
        [value rangeOfString:@"\\AG28(?: [XYZ])?\\z" options:NSRegularExpressionSearch].location != NSNotFound;
}

static BOOL MRMotionScript(id value) {
    if (![value isKindOfClass:[NSString class]] || [value length] > 160) return NO;
    NSString *pattern = @"\\ASAVE_GCODE_STATE NAME=HW_RATOS_(?:JOG\nG91|MOVE\nG90)\nG1 [XYZ]-?[0-9]{1,7}\\.[0-9]{3} F[0-9]{1,7}\\.[0-9]{3}\nRESTORE_GCODE_STATE NAME=HW_RATOS_(?:JOG|MOVE)\\z";
    if ([value rangeOfString:pattern options:NSRegularExpressionSearch].location == NSNotFound) return NO;
    BOOL jog = [value hasPrefix:@"SAVE_GCODE_STATE NAME=HW_RATOS_JOG\n"];
    return jog == [value hasSuffix:@"RESTORE_GCODE_STATE NAME=HW_RATOS_JOG"];
}

static BOOL MRIsLoopbackHost(NSString *host) {
    return [host isEqualToString:@"127.0.0.1"] || [host isEqualToString:@"localhost"] || [host isEqualToString:@"::1"];
}

static BOOL MRFanScript(id value) {
    if (![value isKindOfClass:[NSString class]]) return NO;
    if ([value isEqualToString:@"M107"]) return YES;
    return [value rangeOfString:@"^M106 S[0-9]+(\\.[0-9]+)?$" options:NSRegularExpressionSearch].location != NSNotFound;
}

int32_t mr_native_send(void *handle, const void *bytes, int64_t length, int64_t identifier) {
    MRTransport *transport = (__bridge MRTransport *)handle;
    @synchronized (transport) {
        if (transport.stopped || transport.failed || transport.socketClosed || length > MR_MESSAGE_MAX) return 0;
        NSString *text = MRString(bytes, length);
        if (!text) return 0;
        if (transport.accessMode != 0) {
            id payload = [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
            if (![payload isKindOfClass:[NSDictionary class]]) return 0;
            id method = payload[@"method"];
            if (![method isKindOfClass:[NSString class]]) return 0;
            BOOL emergency = transport.accessMode == 2 && ([method isEqualToString:@"printer.emergency_stop"] ||
                [method isEqualToString:@"printer.restart"] || [method isEqualToString:@"printer.firmware_restart"]) &&
                payload[@"params"] == nil;
            BOOL localHostControl = transport.accessMode == 2 && MRIsLoopbackHost(transport.baseURL.host) &&
                ([method isEqualToString:@"printer.print.start"] ||
                 [method isEqualToString:@"printer.print.pause"] ||
                 [method isEqualToString:@"printer.print.resume"] ||
                 [method isEqualToString:@"printer.print.cancel"] ||
                 [method isEqualToString:@"hw_printer.feature.set"] ||
                 [method isEqualToString:@"hw_printer.features.list"] ||
                 [method isEqualToString:@"hw_printer.design.set_param"] ||
                 [method isEqualToString:@"hw_printer.design.params"]);
            if (!MRReadOnlyMethod(method) && !emergency && !localHostControl) {
                id params = payload[@"params"];
                BOOL fanAllowed = MRIsLoopbackHost(transport.baseURL.host) && MRFanScript(params[@"script"]);
                if (transport.accessMode != 2 || ![method isEqualToString:@"printer.gcode.script"] ||
                    ![params isKindOfClass:[NSDictionary class]] || [params count] != 1 ||
                    !(MRHeaterScript(params[@"script"]) || MRMotionScript(params[@"script"]) || MRHomingScript(params[@"script"]) || [params[@"script"] isEqual:@"M84"] || fanAllowed)) return 0;
            }
        }
        NSURLSessionWebSocketMessage *message = [[NSURLSessionWebSocketMessage alloc] initWithString:text];
        [transport.socket sendMessage:message completionHandler:^(NSError *error) {
            if (error) [transport enqueue:MR_SEND_ERROR status:0 id:identifier data:[error.localizedDescription dataUsingEncoding:NSUTF8StringEncoding]];
        }];
        return 1;
    }
}

static int32_t MRHTTP(void *handle, int64_t identifier, const void *method, int64_t methodLength, const void *path, int64_t pathLength, const void *body, int64_t bodyLength, const void *contentType, int64_t contentTypeLength, int64_t rangeFirst, int64_t rangeLast) {
    MRTransport *transport = (__bridge MRTransport *)handle;
    @synchronized (transport) {
        if (transport.stopped || transport.httpTask || bodyLength < 0 || bodyLength > MR_TRANSFER_MAX ||
            (!body && bodyLength)) return 0;
        BOOL ranged = rangeFirst >= 0;
        if (ranged && (rangeLast < rangeFirst || rangeLast - rangeFirst >= MR_TRANSFER_MAX || bodyLength != 0)) return 0;
        NSString *methodText = MRString(method, methodLength);
        NSString *pathText = MRString(path, pathLength);
        NSString *typeText = MRString(contentType, contentTypeLength);
        if (!methodText || !pathText || !typeText || ![pathText hasPrefix:@"/server/files/"]) return 0;
        if (ranged && (![methodText isEqualToString:@"GET"] || ![pathText hasPrefix:@"/server/files/gcodes/"])) return 0;
        BOOL previewRead = [pathText hasPrefix:@"/server/files/gcodes/"] && [pathText hasSuffix:@".png"];
        BOOL configRead = [pathText hasPrefix:@"/server/files/config/"];
        BOOL configUpload = transport.accessMode == 2 &&
            [methodText isEqualToString:@"POST"] &&
            [pathText isEqualToString:@"/server/files/upload"] &&
            [typeText hasPrefix:@"multipart/form-data; boundary="] &&
            body && bodyLength > 0 && bodyLength <= MR_MESSAGE_MAX + 4096;
        if (configUpload) {
            NSString *bodyText = MRString(body, bodyLength);
            configUpload = bodyText != nil &&
                [bodyText containsString:@"Content-Disposition: form-data; name=\"root\"\r\n\r\nconfig\r\n"] &&
                [bodyText containsString:@"Content-Disposition: form-data; name=\"file\"; filename=\"printer.cfg\"\r\n"] &&
                ![bodyText containsString:@"Content-Disposition: form-data; name=\"root\"\r\n\r\ngcodes"];
            if (!configUpload) return 0;
        } else if (previewRead || configRead || transport.accessMode != 0) {
            NSString *root = configRead ? @"/server/files/config/" : @"/server/files/gcodes/";
            if (![methodText isEqualToString:@"GET"] || bodyLength != 0 || typeText.length != 0 ||
                ![pathText hasPrefix:root]) return 0;
            NSURLComponents *parts = [NSURLComponents componentsWithString:pathText];
            if (!parts || parts.query || parts.fragment || ![parts.path hasPrefix:root]) return 0;
            NSString *filename = [parts.path substringFromIndex:root.length];
            if ([filename rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"\\%\"?#"]].location != NSNotFound ||
                [filename rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return 0;
            NSArray<NSString *> *components = [filename componentsSeparatedByString:@"/"];
            if (previewRead) {
                if (components.count < 2) return 0;
                NSString *folder = components[components.count - 2];
                if (![folder isEqualToString:@".thumbs"] && ![folder isEqualToString:@"thumbs"]) return 0;
            }
            for (NSString *component in components) {
                if (!component.length || [component isEqualToString:@"."] || [component isEqualToString:@".."]) return 0;
            }
        }
        NSURL *url = [NSURL URLWithString:[transport.baseURL.absoluteString stringByAppendingString:pathText]];
        if (!url || ![url.host isEqualToString:transport.baseURL.host]) return 0;
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        request.HTTPMethod = methodText;
        if (transport.apiKey.length) [request setValue:transport.apiKey forHTTPHeaderField:@"X-Api-Key"];
        if (typeText.length) [request setValue:typeText forHTTPHeaderField:@"Content-Type"];
        if (bodyLength) request.HTTPBody = [NSData dataWithBytes:body length:(NSUInteger)bodyLength];
        if (ranged) [request setValue:[NSString stringWithFormat:@"bytes=%lld-%lld", rangeFirst, rangeLast] forHTTPHeaderField:@"Range"];
        transport.httpID = identifier;
        transport.httpStatus = 0;
        transport.httpLimit = previewRead ? 1024 * 1024 : ranged ? (NSUInteger)(rangeLast - rangeFirst + 1) : MR_TRANSFER_MAX;
        transport.httpData = [NSMutableData new];
        transport.httpTask = [transport.session dataTaskWithRequest:request];
        [transport.httpTask resume];
        return 1;
    }
}

int32_t mr_native_http(void *handle, int64_t identifier, const void *method, int64_t methodLength, const void *path, int64_t pathLength, const void *body, int64_t bodyLength, const void *contentType, int64_t contentTypeLength) {
    return MRHTTP(handle, identifier, method, methodLength, path, pathLength, body, bodyLength, contentType, contentTypeLength, -1, -1);
}

// Reads one byte range of a G-code file; a server that ignores the range sends at most the range length.
int32_t mr_native_http_range(void *handle, int64_t identifier, const void *path, int64_t pathLength, int64_t first, int64_t last) {
    if (first < 0) return 0;
    return MRHTTP(handle, identifier, "GET", 3, path, pathLength, NULL, 0, "", 0, first, last);
}

void mr_native_http_cancel(void *handle) {
    MRTransport *transport = (__bridge MRTransport *)handle;
    @synchronized (transport) {
        [transport.httpTask cancel];
        transport.httpTask = nil;
        transport.httpData = nil;
        transport.httpID = 0;
    }
}

int32_t mr_native_fixture_event(const void *endpoint, int64_t endpointLength, const void *body, int64_t bodyLength) {
    @autoreleasepool {
        if (endpointLength <= 0 || endpointLength > 2048 || !body || bodyLength <= 0 || bodyLength > 65536) return 0;
        NSString *text = MRString(endpoint, endpointLength);
        if (!text) return 0;
        NSURLComponents *parts = [NSURLComponents componentsWithString:text];
        if (!parts || ![parts.scheme isEqualToString:@"http"] || ![parts.host isEqualToString:@"127.0.0.1"] ||
            !parts.port || parts.user || parts.password || parts.query || parts.fragment ||
            bodyLength <= 0 || bodyLength > 65536) return 0;
        NSURL *url = [NSURL URLWithString:[text stringByAppendingString:@"/test/event"]];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        request.HTTPMethod = @"POST";
        request.HTTPBody = [NSData dataWithBytes:body length:(NSUInteger)bodyLength];
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        dispatch_semaphore_t finished = dispatch_semaphore_create(0);
        __block BOOL success = NO;
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.timeoutIntervalForRequest = 5;
        configuration.timeoutIntervalForResource = 5;
        MRTransport *redirectGuard = [MRTransport new];
        NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration delegate:redirectGuard delegateQueue:nil];
        NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            (void)data;
            success = !error && [(NSHTTPURLResponse *)response statusCode] == 200;
            dispatch_semaphore_signal(finished);
        }];
        [task resume];
        if (dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC))) {
            [task cancel];
            [session invalidateAndCancel];
            return 0;
        }
        [session invalidateAndCancel];
        return success;
    }
}
