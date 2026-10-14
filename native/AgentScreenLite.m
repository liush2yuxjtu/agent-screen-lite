#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Foundation/Foundation.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <unistd.h>
#import <errno.h>
#import <signal.h>
#import <limits.h>
#import "VDVirtualDisplay.h"
#import "AppWorkspace.h"

static NSString * const ASLErrorDomain = @"dev.openagent.agent-screen-lite";
static NSString * const ASLVersion = @"0.1.0";

@interface ASLProfile : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic, strong) VDVirtualDisplay *display;
@property(nonatomic) NSUInteger width;
@property(nonatomic) NSUInteger height;
@property(nonatomic) BOOL hiDPI;
@end
@implementation ASLProfile
@end

@interface ASLController : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSMutableArray<ASLProfile *> *profiles;
@property(nonatomic, strong) YMAppWorkspace *workspace;
@property(nonatomic) uint32_t nextSerial;
@property(nonatomic) int serverFD;
@property(nonatomic, copy) NSString *socketPath;
@end

static NSString *ASLSocketPath(void) {
    NSString *base = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/agent-screen-lite"];
    [[NSFileManager defaultManager] createDirectoryAtPath:base
                              withIntermediateDirectories:YES
                                               attributes:@{NSFilePosixPermissions: @0700}
                                                    error:NULL];
    return [base stringByAppendingPathComponent:@"control.sock"];
}

static NSDictionary *ASLErrorResponse(NSInteger code, NSString *message) {
    return @{ @"ok": @NO, @"error": @{ @"code": @(code), @"message": message ?: @"unknown error" } };
}

static NSDictionary *ASLSafeWindowRow(NSDictionary *row) {
    NSMutableDictionary *safe = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"appName", @"bundleIdentifier", @"pid", @"pids", @"windowCount", @"managedWindowCount"])
        if (row[key] != nil) safe[key] = row[key];
    return safe;
}

static NSDictionary *ASLSafeDisplay(NSDictionary *display) {
    NSMutableDictionary *safe = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"displayID", @"name", @"isMain", @"isBuiltin", @"isActive", @"isOnline", @"isVirtual", @"bounds", @"logicalWidth", @"logicalHeight", @"pixelWidth", @"pixelHeight", @"modeWidth", @"modeHeight", @"refreshRate"])
        if (display[key] != nil) safe[key] = display[key];
    return safe;
}

static BOOL ASLWriteAll(int fd, NSData *data) {
    const uint8_t *bytes = data.bytes;
    size_t remaining = data.length;
    while (remaining > 0) {
        ssize_t written = write(fd, bytes, remaining);
        if (written <= 0) return NO;
        bytes += written;
        remaining -= (size_t)written;
    }
    return YES;
}

@implementation ASLController

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _profiles = [NSMutableArray array];
    _workspace = [[YMAppWorkspace alloc] init];
    _nextSerial = 0x41530001;
    _serverFD = -1;
    _socketPath = ASLSocketPath();
    return self;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [self startSocketServer];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self stopSocketServer];
}

- (void)dealloc {
    [self stopSocketServer];
}

- (ASLProfile *)profileForParams:(NSDictionary *)params {
    NSNumber *displayID = [params[@"display_id"] isKindOfClass:NSNumber.class] ? params[@"display_id"] : nil;
    NSString *name = [params[@"screen"] isKindOfClass:NSString.class] ? params[@"screen"] : nil;
    for (ASLProfile *profile in self.profiles) {
        if (displayID && profile.display.displayID == displayID.unsignedIntValue) return profile;
        if (name.length && [profile.name isEqualToString:name]) return profile;
    }
    return nil;
}

- (NSUInteger)independentDisplayCount {
    NSUInteger active = 0;
    for (NSDictionary *display in VDVirtualDisplay.onlineDisplays)
        if ([display[@"isActive"] boolValue] && [display[@"isOnline"] boolValue]) active++;
    return active > 1 ? active - 1 : 0;
}

- (void)refreshWorkspace {
    NSMutableArray<NSNumber *> *IDs = [NSMutableArray array];
    for (ASLProfile *profile in self.profiles)
        if (profile.display.isCreated) [IDs addObject:@(profile.display.displayID)];
    [self.workspace refreshWithVirtualDisplayIDs:IDs displaySnapshot:VDVirtualDisplay.onlineDisplays];
}

- (NSDictionary *)profileJSON:(ASLProfile *)profile {
    return @{ @"name": profile.name ?: @"",
              @"display_id": @(profile.display.displayID),
              @"width": @(profile.width),
              @"height": @(profile.height),
              @"hi_dpi": @(profile.hiDPI),
              @"created": @(profile.display.isCreated) };
}

- (NSDictionary *)statusResult {
    [self refreshWorkspace];
    NSMutableArray *profiles = [NSMutableArray array];
    for (ASLProfile *profile in self.profiles) [profiles addObject:[self profileJSON:profile]];
    NSMutableArray *displays = [NSMutableArray array];
    for (NSDictionary *display in VDVirtualDisplay.onlineDisplays) [displays addObject:ASLSafeDisplay(display)];
    NSMutableArray *apps = [NSMutableArray array];
    for (NSDictionary *row in self.workspace.rows) [apps addObject:ASLSafeWindowRow(row)];
    NSMutableArray *appsByScreen = [NSMutableArray array];
    for (ASLProfile *profile in self.profiles) {
        NSMutableArray *screenApps = [NSMutableArray array];
        for (NSDictionary *row in [self.workspace rowsForDisplayID:profile.display.displayID]) [screenApps addObject:ASLSafeWindowRow(row)];
        [appsByScreen addObject:@{ @"screen": profile.name, @"display_id": @(profile.display.displayID), @"apps": screenApps }];
    }
    NSUInteger independentDisplays = [self independentDisplayCount];
    return @{ @"version": ASLVersion,
              @"api_available": @(VDVirtualDisplay.isAPIAvailable),
              @"accessibility_trusted": @(self.workspace.accessibilityTrusted),
              @"independent_display_count": @(independentDisplays),
              @"window_isolation_ready": @(independentDisplays > 0),
              @"virtual_screens": profiles,
              @"displays": displays,
              @"apps_on_owned_screens": apps,
              @"apps_by_screen": appsByScreen };
}

- (NSDictionary *)createScreen:(NSDictionary *)params {
    NSString *name = [params[@"name"] isKindOfClass:NSString.class] ? [params[@"name"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : @"Agent";
    if (name.length == 0 || name.length > 80) return ASLErrorResponse(20, @"name must be 1–80 characters");
    for (ASLProfile *profile in self.profiles)
        if ([profile.name isEqualToString:name]) return @{ @"ok": @YES, @"result": [self profileJSON:profile], @"idempotent": @YES };
    NSUInteger width = [params[@"width"] isKindOfClass:NSNumber.class] ? [params[@"width"] unsignedIntegerValue] : 1920;
    NSUInteger height = [params[@"height"] isKindOfClass:NSNumber.class] ? [params[@"height"] unsignedIntegerValue] : 1080;
    BOOL hiDPI = [params[@"hi_dpi"] boolValue];
    ASLProfile *profile = [[ASLProfile alloc] init];
    profile.name = name; profile.width = width; profile.height = height; profile.hiDPI = hiDPI;
    profile.display = [[VDVirtualDisplay alloc] initWithSerialNumber:self.nextSerial++];
    NSError *error = nil;
    if (![profile.display createWithWidth:width height:height hiDPI:hiDPI name:name error:&error])
        return ASLErrorResponse(error.code, error.localizedDescription);
    [self.profiles addObject:profile];
    [self refreshWorkspace];
    return @{ @"ok": @YES, @"result": [self profileJSON:profile] };
}

- (NSURL *)applicationURLForParams:(NSDictionary *)params error:(NSError **)error {
    NSString *path = [params[@"app_path"] isKindOfClass:NSString.class] ? params[@"app_path"] : nil;
    if (path.length) {
        NSURL *url = [NSURL fileURLWithPath:path].URLByResolvingSymlinksInPath.URLByStandardizingPath;
        if ([[NSFileManager defaultManager] fileExistsAtPath:url.path]) return url;
        if (error) *error = [NSError errorWithDomain:ASLErrorDomain code:31 userInfo:@{NSLocalizedDescriptionKey: @"app_path does not exist"}];
        return nil;
    }
    NSString *bundleID = [params[@"bundle_id"] isKindOfClass:NSString.class] ? params[@"bundle_id"] : nil;
    if (!bundleID.length) {
        if (error) *error = [NSError errorWithDomain:ASLErrorDomain code:32 userInfo:@{NSLocalizedDescriptionKey: @"provide bundle_id or app_path"}];
        return nil;
    }
    NSArray<NSRunningApplication *> *apps = [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleID];
    for (NSRunningApplication *app in apps)
        if (!app.terminated && app.bundleURL) return app.bundleURL;
    if (error) *error = [NSError errorWithDomain:ASLErrorDomain code:33 userInfo:@{NSLocalizedDescriptionKey: @"the app is not running or has no bundle URL"}];
    return nil;
}

- (NSDictionary *)moveApp:(NSDictionary *)params {
    ASLProfile *target = [self profileForParams:params];
    if (!target || !target.display.isCreated) return ASLErrorResponse(40, @"target virtual screen not found");
    if ([self independentDisplayCount] == 0)
        return ASLErrorResponse(41, @"当前登录会话只有一块在线显示面；创建虚拟屏成功，但不能安全移动窗口。增加第二块在线显示面后才能分离窗口表面；这仍不是独立键盘/鼠标输入。");
    NSError *error = nil; NSURL *URL = [self applicationURLForParams:params error:&error];
    if (!URL) return ASLErrorResponse(error.code, error.localizedDescription);
    CGDirectDisplayID sourceID = [params[@"source_display_id"] isKindOfClass:NSNumber.class] ? [params[@"source_display_id"] unsignedIntValue] : 0;
    if (![self.workspace moveApplicationAtURL:URL fromDisplayID:sourceID toDisplayID:target.display.displayID error:&error])
        return ASLErrorResponse(error.code, error.localizedDescription);
    return @{ @"ok": @YES, @"result": @{ @"moved": @YES, @"screen": target.name, @"display_id": @(target.display.displayID), @"bundle_id": [NSBundle bundleWithURL:URL].bundleIdentifier ?: @"" } };
}

- (NSDictionary *)restoreApp:(NSDictionary *)params {
    ASLProfile *source = [self profileForParams:params];
    if (!source || !source.display.isCreated) return ASLErrorResponse(50, @"source virtual screen not found");
    NSError *error = nil;
    NSString *bundleID = [params[@"bundle_id"] isKindOfClass:NSString.class] ? params[@"bundle_id"] : nil;
    BOOL restored = bundleID.length ? [self.workspace restoreApplicationWithBundleIdentifier:bundleID fromDisplayID:source.display.displayID error:&error]
                                    : [self.workspace restoreDisplayID:source.display.displayID error:&error];
    if (!restored) return ASLErrorResponse(error.code, error.localizedDescription);
    return @{ @"ok": @YES, @"result": @{ @"restored": @YES, @"screen": source.name, @"display_id": @(source.display.displayID), @"bundle_id": bundleID ?: @"*" } };
}

- (NSDictionary *)destroyScreen:(NSDictionary *)params {
    ASLProfile *profile = [self profileForParams:params];
    if (!profile || !profile.display.isCreated) return ASLErrorResponse(60, @"virtual screen not found");
    NSError *error = nil;
    if (![self.workspace restoreDisplayID:profile.display.displayID error:&error])
        return ASLErrorResponse(error.code, error.localizedDescription);
    [profile.display destroy];
    [self.profiles removeObject:profile];
    [self refreshWorkspace];
    return @{ @"ok": @YES, @"result": @{ @"destroyed": @YES, @"screen": profile.name } };
}

- (NSDictionary *)captureDisplay:(NSDictionary *)params includeInVerify:(BOOL)includeInVerify {
    ASLProfile *profile = [self profileForParams:params];
    CGDirectDisplayID displayID = profile ? profile.display.displayID : ([params[@"display_id"] isKindOfClass:NSNumber.class] ? [params[@"display_id"] unsignedIntValue] : 0);
    if (!displayID || !CGDisplayIsOnline(displayID)) return ASLErrorResponse(70, @"display is not online");
    CGImageRef image = CGDisplayCreateImage(displayID);
    if (!image) return ASLErrorResponse(71, @"CGDisplayCreateImage returned no image; Screen Recording permission may be missing");
    NSString *path = [params[@"path"] isKindOfClass:NSString.class] ? params[@"path"] : nil;
    if (!path.length) {
        NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/agent-screen-lite/captures"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700} error:NULL];
        path = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"capture-%@.png", NSUUID.UUID.UUIDString]];
    }
    NSURL *URL = [NSURL fileURLWithPath:path];
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)URL, CFSTR("public.png"), 1, NULL);
    BOOL written = NO;
    if (destination) {
        CGImageDestinationAddImage(destination, image, NULL);
        written = CGImageDestinationFinalize(destination);
        CFRelease(destination);
    }
    size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    CGImageRelease(image);
    if (!written) return ASLErrorResponse(72, @"could not write PNG capture");
    NSMutableDictionary *result = [@{ @"captured": @YES, @"path": path, @"display_id": @(displayID), @"width": @(width), @"height": @(height) } mutableCopy];
    if (includeInVerify) result[@"screen"] = profile.name ?: @"";
    return @{ @"ok": @YES, @"result": result };
}

- (NSDictionary *)verify:(NSDictionary *)params {
    ASLProfile *profile = [self profileForParams:params];
    if (!profile || !profile.display.isCreated) return ASLErrorResponse(80, @"virtual screen not found");
    [self refreshWorkspace];
    NSDictionary *capture = [self captureDisplay:@{ @"display_id": @(profile.display.displayID) } includeInVerify:YES];
    NSMutableDictionary *result = [@{ @"api_available": @(VDVirtualDisplay.isAPIAvailable),
                                      @"accessibility_trusted": @(self.workspace.accessibilityTrusted),
                                      @"display_online": @(CGDisplayIsOnline(profile.display.displayID)),
                                      @"display_active": @(CGDisplayIsActive(profile.display.displayID)),
                                      @"independent_display_count": @([self independentDisplayCount]),
                                      @"window_isolation_ready": @([self independentDisplayCount] > 0),
                                      @"screen": profile.name,
                                      @"display_id": @(profile.display.displayID),
                                      @"apps": @([self.workspace rowsForDisplayID:profile.display.displayID].count) } mutableCopy];
    if ([capture[@"ok"] boolValue]) result[@"capture"] = capture[@"result"];
    else result[@"capture_error"] = capture[@"error"] ?: @{};
    return @{ @"ok": @YES, @"result": result };
}

- (NSDictionary *)handleRequest:(NSDictionary *)request {
    NSString *method = [request[@"method"] isKindOfClass:NSString.class] ? request[@"method"] : nil;
    NSDictionary *params = [request[@"params"] isKindOfClass:NSDictionary.class] ? request[@"params"] : @{};
    if ([method isEqualToString:@"status"]) return @{ @"ok": @YES, @"result": [self statusResult] };
    if ([method isEqualToString:@"create"]) return [self createScreen:params];
    if ([method isEqualToString:@"move_app"]) return [self moveApp:params];
    if ([method isEqualToString:@"restore"]) return [self restoreApp:params];
    if ([method isEqualToString:@"destroy"]) return [self destroyScreen:params];
    if ([method isEqualToString:@"capture"]) return [self captureDisplay:params includeInVerify:NO];
    if ([method isEqualToString:@"verify"]) return [self verify:params];
    return ASLErrorResponse(90, [NSString stringWithFormat:@"unknown method: %@", method ?: @"<missing>"]);
}

- (void)handleClientFD:(int)fd {
    @autoreleasepool {
        NSMutableData *buffer = [NSMutableData data]; uint8_t chunk[4096];
        while (YES) {
            ssize_t count = read(fd, chunk, sizeof(chunk));
            if (count <= 0) break;
            [buffer appendBytes:chunk length:(NSUInteger)count];
            const uint8_t *bytes = buffer.bytes;
            for (NSUInteger i = 0; i < buffer.length; i++) {
                if (bytes[i] != '\n') continue;
                NSData *line = [buffer subdataWithRange:NSMakeRange(0, i)];
                [buffer replaceBytesInRange:NSMakeRange(0, i + 1) withBytes:NULL length:0];
                NSDictionary *request = [NSJSONSerialization JSONObjectWithData:line options:0 error:NULL];
                __block NSDictionary *response = nil;
                if (![request isKindOfClass:NSDictionary.class]) response = ASLErrorResponse(91, @"request must be a JSON object");
                else dispatch_sync(dispatch_get_main_queue(), ^{ response = [self handleRequest:request]; });
                NSMutableData *out = [[NSJSONSerialization dataWithJSONObject:response ?: ASLErrorResponse(92, @"empty response") options:0 error:NULL] mutableCopy];
                if (!out) out = [NSMutableData data];
                [out appendBytes:"\n" length:1];
                if (!ASLWriteAll(fd, out)) { close(fd); return; }
                bytes = buffer.bytes; i = (NSUInteger)-1;
            }
        }
        close(fd);
    }
}

- (void)startSocketServer {
    if (self.serverFD >= 0) return;
    [[NSFileManager defaultManager] removeItemAtPath:self.socketPath error:NULL];
    self.serverFD = socket(AF_UNIX, SOCK_STREAM, 0);
    if (self.serverFD < 0) return;
    struct sockaddr_un address; memset(&address, 0, sizeof(address)); address.sun_family = AF_UNIX;
    if (self.socketPath.fileSystemRepresentation == NULL || strlen(self.socketPath.fileSystemRepresentation) >= sizeof(address.sun_path)) { close(self.serverFD); self.serverFD = -1; return; }
    strlcpy(address.sun_path, self.socketPath.fileSystemRepresentation, sizeof(address.sun_path));
    socklen_t length = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + strlen(address.sun_path) + 1);
    if (bind(self.serverFD, (struct sockaddr *)&address, length) != 0 || chmod(self.socketPath.fileSystemRepresentation, 0600) != 0 || listen(self.serverFD, 16) != 0) {
        close(self.serverFD); self.serverFD = -1; [[NSFileManager defaultManager] removeItemAtPath:self.socketPath error:NULL]; return;
    }
    int listener = self.serverFD;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        while (listener == self.serverFD) {
            int client = accept(listener, NULL, NULL);
            if (client < 0) { if (errno == EINTR) continue; break; }
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ [self handleClientFD:client]; });
        }
    });
}

- (void)stopSocketServer {
    int fd = self.serverFD; self.serverFD = -1;
    if (fd >= 0) { shutdown(fd, SHUT_RDWR); close(fd); }
    [[NSFileManager defaultManager] removeItemAtPath:self.socketPath error:NULL];
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2 || strcmp(argv[1], "--daemon") != 0) {
            fprintf(stderr, "Usage: AgentScreenLite --daemon\n");
            return 64;
        }
        NSApplication *application = [NSApplication sharedApplication];
        ASLController *controller = [[ASLController alloc] init];
        application.delegate = controller;
        [application run];
    }
    return 0;
}
