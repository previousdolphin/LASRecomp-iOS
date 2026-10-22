// VA Probe: does an iPhone give LAS Recomp the memory layout the runtime needs? (docs/ios.md)
// v3: the desktop layout's window, then the compact iOS layout end to end, in the order the runtime sets it up
// (window, Metal wrapper over the heap, game textures, guest threads, heap use), then an experiment on the range iOS
// keeps reserved below 0x70_0000_0000. Results on screen and in Documents/vaprobe.txt (Files app). No game files.
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <UIKit/UIKit.h>

#include <mach/mach.h>
#include <mach/vm_map.h>
#include <os/proc.h>
#include <pthread.h>
#include <signal.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <unistd.h>

// ---- the desktop layout (runtime/rt.h, runtime/kernel.h)
#define GUEST_LO   0x7000000000ull
#define GUEST_HI   0x7320000000ull
#define HEAP_MAX   0x00D0000000ull  // 3.25 GB

// ---- the compact iOS layout (docs/ios.md): main and sdk stay put (their addresses are in the generated code),
// everything the runtime places itself moves down next to them and shrinks to what a game plausibly uses
#define C_HLE_BASE   0x7010000000ull  // 1 MB of fake function addresses
#define C_TLS_BASE   0x7010100000ull  // 1 MB
#define C_HLE_HEAP   0x7011000000ull  // 224 MB, as on desktop
#define C_ALIAS_BASE 0x7020000000ull  // 512 MB (desktop: 4 GB)
#define C_STACK_BASE 0x7040000000ull  // 256 MB of guest stacks (desktop: 1 GB)
#define C_HEAP_BASE  0x7050000000ull  // 3.25 GB cap, as on desktop
#define C_GUEST_HI   (C_HEAP_BASE + HEAP_MAX)  // 0x71_2000_0000: 4.5 GB window
#define C_HOST_STACK (32ull << 20)    // per guest thread (desktop: 256 MB)

static NSMutableString *g_out;
static FILE *g_file;
static UITextView *g_view;
static int g_fails;

static void say(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void say(const char *fmt, ...) {
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    if (g_file) { fprintf(g_file, "%s\n", buf); fflush(g_file); fsync(fileno(g_file)); }  // (iOS may kill us mid-test)
    NSString *line = [NSString stringWithFormat:@"%s\n", buf];
    dispatch_async(dispatch_get_main_queue(), ^{
        [g_out appendString:line];
        g_view.text = g_out;
        [g_view scrollRangeToVisible:NSMakeRange(g_out.length, 0)];
    });
}

static void verdict(bool ok, const char *what) {
    if (!ok) g_fails++;
    say("  [%s] %s", ok ? "PASS" : "FAIL", what);
}

static const char *kr_name(kern_return_t kr) {
    switch (kr) {
        case KERN_SUCCESS: return "ok";
        case KERN_NO_SPACE: return "KERN_NO_SPACE (in use)";
        case KERN_INVALID_ADDRESS: return "KERN_INVALID_ADDRESS (past the top)";
        case KERN_INVALID_ARGUMENT: return "KERN_INVALID_ARGUMENT";
        case KERN_RESOURCE_SHORTAGE: return "KERN_RESOURCE_SHORTAGE";
        case KERN_PROTECTION_FAILURE: return "KERN_PROTECTION_FAILURE";
        default: return mach_error_string(kr);
    }
}

static double gb(uint64_t v) { return v / (double)(1ull << 30); }

// what jetsam counts against the app's limit
static uint64_t footprint(void) {
    task_vm_info_data_t vi;
    mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
    return task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vi, &n) == KERN_SUCCESS ? vi.phys_footprint : 0;
}

static void mem_line(const char *what) {
    say("  %s: footprint %.2f GB, %.2f GB left before iOS's limit", what, gb(footprint()), gb(os_proc_available_memory()));
}

static kern_return_t reserve(uint64_t lo, uint64_t hi, int flags) {
    vm_address_t a = lo;
    return vm_allocate(mach_task_self(), &a, hi - lo, VM_FLAGS_FIXED | flags);
}

// ---- device
static void device_info(void) {
    char machine[64] = "?";
    size_t n = sizeof machine;
    sysctlbyname("hw.machine", machine, &n, NULL, 0);
    uint64_t mem = 0;
    n = sizeof mem;
    sysctlbyname("hw.memsize", &mem, &n, NULL, 0);
    say("== device (probe v3)");
    say("  %s, iOS %s, %.1f GB RAM, %lu-byte pages", machine, UIDevice.currentDevice.systemVersion.UTF8String, gb(mem),
        (unsigned long)vm_page_size);
    mem_line("at start");
}

// The entitlements the signing tool actually gave us (from the embedded provisioning profile).
static void entitlements(void) {
    say("== entitlements");
    NSString *path = [NSBundle.mainBundle pathForResource:@"embedded" ofType:@"mobileprovision"];
    NSData *d = path ? [NSData dataWithContentsOfFile:path] : nil;
    if (!d) { say("  no embedded.mobileprovision (TrollStore, or not signed with a profile)"); return; }
    NSRange a = [d rangeOfData:[@"<?xml" dataUsingEncoding:NSASCIIStringEncoding] options:0 range:NSMakeRange(0, d.length)];
    NSRange b = [d rangeOfData:[@"</plist>" dataUsingEncoding:NSASCIIStringEncoding] options:0 range:NSMakeRange(0, d.length)];
    if (a.location == NSNotFound || b.location == NSNotFound) { say("  can't read the profile"); return; }
    NSData *xml = [d subdataWithRange:NSMakeRange(a.location, NSMaxRange(b) - a.location)];
    NSDictionary *p = [NSPropertyListSerialization propertyListWithData:xml options:0 format:NULL error:NULL];
    NSDictionary *e = p[@"Entitlements"];
    say("  team: %s", [p[@"TeamName"] description].UTF8String ?: "?");
    for (NSString *k in @[@"com.apple.developer.kernel.increased-memory-limit",
                          @"com.apple.developer.kernel.extended-virtual-addressing", @"get-task-allow"])
        say("  %s: %s", k.UTF8String, e[k] ? [e[k] description].UTF8String : "(not granted)");
}

// ---- address space: the top, every big mapping and every big hole
static const char *prot_name(vm_prot_t p) {
    static char s[4][4];
    static int i;
    char *o = s[i++ & 3];
    o[0] = p & VM_PROT_READ ? 'r' : '-', o[1] = p & VM_PROT_WRITE ? 'w' : '-', o[2] = p & VM_PROT_EXECUTE ? 'x' : '-', o[3] = 0;
    return o;
}

static uint64_t map_top(void) {
    uint64_t lo = GUEST_LO, hi = 0x800000000000ull;  // (0x70_0000_0000 is known to be below the top)
    while (hi - lo > vm_page_size) {
        uint64_t mid = (lo + (hi - lo) / 2) & ~(uint64_t)(vm_page_size - 1);
        vm_address_t a = mid;
        kern_return_t kr = vm_allocate(mach_task_self(), &a, vm_page_size, VM_FLAGS_FIXED);
        if (kr == KERN_SUCCESS) vm_deallocate(mach_task_self(), a, vm_page_size);
        if (kr == KERN_INVALID_ADDRESS) hi = mid; else lo = mid;
    }
    return hi;
}

static void address_space(void) {
    say("== address space");
    uint64_t top = map_top();
    say("  top: 0x%llx; desktop window needs 0x%llx, compact window 0x%llx", top, GUEST_HI, C_GUEST_HI);
    say("  mappings of 256 MB or more, and holes of 64 MB or more:");
    vm_address_t addr = 0, end = 0;
    vm_size_t size;
    uint64_t holes = 0;
    for (;;) {
        natural_t depth = 0;
        struct vm_region_submap_info_64 info;
        mach_msg_type_number_t cnt = VM_REGION_SUBMAP_INFO_COUNT_64;
        if (vm_region_recurse_64(mach_task_self(), &addr, &size, &depth, (vm_region_recurse_info_t)&info, &cnt)) break;
        if (end && addr - end >= (64ull << 20)) {
            say("    hole    0x%010llx-0x%010llx %8.2f GB", (uint64_t)end, (uint64_t)addr, gb(addr - end));
            holes += addr - end;
        }
        if (size >= (256ull << 20))
            say("    mapping 0x%010llx-0x%010llx %8.2f GB %s/%s tag %u%s", (uint64_t)addr, (uint64_t)(addr + size), gb(size),
                prot_name(info.protection), prot_name(info.max_protection), info.user_tag, info.is_submap ? " submap" : "");
        end = addr + size;
        addr += size;
    }
    if (top > end) {
        say("    hole    0x%010llx-0x%010llx %8.2f GB (to the top)", (uint64_t)end, top, gb(top - end));
        holes += top - end;
    }
    say("  free in holes of 64 MB+: %.2f GB", gb(holes));
}

// ---- the desktop window, as it is
static void desktop_window(void) {
    say("== desktop window 0x%llx-0x%llx (%.1f GB)", GUEST_LO, GUEST_HI, gb(GUEST_HI - GUEST_LO));
    kern_return_t kr = reserve(GUEST_LO, GUEST_HI, 0);
    say("  reserve: %s", kr_name(kr));
    if (!kr) vm_deallocate(mach_task_self(), GUEST_LO, GUEST_HI - GUEST_LO);
    say("  (informational: the compact layout below is what an iOS build would use without the entitlement)");
}

// ---- the compact layout, end to end
static dispatch_semaphore_t g_hold;
static volatile int g_touched;

static void *thread_body(void *arg) {
    (void)arg;
    volatile char frame[4 << 20];  // a deep-ish frame, well inside the stack
    frame[0] = frame[sizeof frame - 1] = 1;
    __sync_fetch_and_add(&g_touched, 1);
    dispatch_semaphore_wait(g_hold, DISPATCH_TIME_FOREVER);
    return NULL;
}

static volatile uint64_t g_fault_page;
static volatile int g_faults;

static void on_fault(int sig, siginfo_t *si, void *ctx) {
    (void)ctx;
    uint64_t fa = (uint64_t)si->si_addr;
    if (g_fault_page && fa - g_fault_page < vm_page_size) {
        g_faults++;
        mprotect((void *)g_fault_page, vm_page_size, PROT_READ | PROT_WRITE);
        return;
    }
    signal(sig, SIG_DFL);
}

static void compact_layout(void) {
    say("== compact layout 0x%llx-0x%llx (%.2f GB window)", GUEST_LO, C_GUEST_HI, gb(C_GUEST_HI - GUEST_LO));
    say("  main/sdk at 0x7000000000/0x7004000000 (unchanged), HLE 0x%llx, TLS 0x%llx, HLE heap 0x%llx,", C_HLE_BASE,
        C_TLS_BASE, C_HLE_HEAP);
    say("  alias 0x%llx (512 MB), guest stacks 0x%llx (256 MB), heap 0x%llx-0x%llx (3.25 GB)", C_ALIAS_BASE, C_STACK_BASE,
        C_HEAP_BASE, C_GUEST_HI);
    // 1. the window (main.c, first thing at startup)
    kern_return_t kr = reserve(GUEST_LO, C_GUEST_HI, 0);
    say("  1. reserve the window: %s", kr_name(kr));
    verdict(kr == KERN_SUCCESS, "reserve the compact window");
    if (kr) return;
    static const uint64_t touch[] = {GUEST_LO, C_HLE_HEAP, C_ALIAS_BASE, C_STACK_BASE, C_HEAP_BASE, C_GUEST_HI - 0x4000};
    for (size_t i = 0; i < sizeof touch / sizeof *touch; i++) *(volatile uint64_t *)touch[i] = 0x1A51A5;
    kr = reserve(GUEST_LO, C_GUEST_HI, VM_FLAGS_OVERWRITE);
    verdict(kr == KERN_SUCCESS && *(volatile uint64_t *)C_HEAP_BASE == 0, "write every region, reset to zero pages (reboot)");

    // 2. the Metal wrapper over the guest heap (metal.m: one no-copy buffer, GPU addresses are guest addresses)
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    say("  2. Metal: %s, maxBufferLength %.2f GB, working set %.2f GB", dev.name.UTF8String, gb(dev.maxBufferLength),
        gb(dev.recommendedMaxWorkingSetSize));
    id<MTLBuffer> wrap = [dev newBufferWithBytesNoCopy:(void *)C_HEAP_BASE length:HEAP_MAX
                                               options:MTLResourceStorageModeShared deallocator:nil];
    say("     no-copy buffer over the whole 3.25 GB heap: %s", wrap ? "ok" : "refused");
    uint64_t wrapped = wrap ? HEAP_MAX : 0;
    if (!wrap) {  // the biggest heap a single wrapper can cover (what HEAP_MAX would have to shrink to)
        for (uint64_t len = HEAP_MAX - (256ull << 20); len >= (256ull << 20) && !wrap; len -= 256ull << 20) {
            wrap = [dev newBufferWithBytesNoCopy:(void *)C_HEAP_BASE length:len options:MTLResourceStorageModeShared
                                     deallocator:nil];
            if (wrap) wrapped = len;
        }
        say("     largest that works: %.2f GB", gb(wrapped));
    }
    verdict(wrapped == HEAP_MAX, "one Metal buffer over the whole guest heap");

    // 3. game textures: private Metal textures (the renderer's copies of what the game uploads)
    NSMutableArray *texs = [NSMutableArray new];
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                  width:2048 height:2048 mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    id<MTLCommandQueue> q = [dev newCommandQueue];
    for (int i = 0; i < 32; i++) {  // 512 MB, actually touched (cleared on the GPU) so it's resident
        id<MTLTexture> t = [dev newTextureWithDescriptor:td];
        if (!t) break;
        [texs addObject:t];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor new];
        rp.colorAttachments[0].texture = t;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLCommandBuffer> cb = [q commandBuffer];
        [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
    }
    say("  3. %lu private 16 MB textures (%.2f GB of game textures, cleared on the GPU)", (unsigned long)texs.count,
        gb(texs.count * (16ull << 20)));
    mem_line("after textures");
    verdict(texs.count == 32, "512 MB of private textures next to the window");

    // 4. guest threads: 32 MB host stacks, all alive at once, with everything above still held
    enum { N = 48 };
    g_hold = dispatch_semaphore_create(0);
    g_touched = 0;
    pthread_t t[N];
    int made = 0, err = 0;
    for (int i = 0; i < N; i++) {
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        pthread_attr_setstacksize(&attr, C_HOST_STACK);
        err = pthread_create(&t[made], &attr, thread_body, NULL);
        pthread_attr_destroy(&attr);
        if (err) break;
        made++;
    }
    for (int i = 0; i < 200 && g_touched < made; i++) usleep(10000);
    say("  4. threads with %llu MB stacks: %d of %d (%s), %d touched their stacks", C_HOST_STACK >> 20, made, N,
        err ? strerror(err) : "no errors", g_touched);
    verdict(made == N && g_touched == N, "48 guest threads alive at once");

    // 5. heap use: as much of the guest heap resident as iOS allows, with textures and threads still there
    uint64_t done = 0, step = 64ull << 20;
    while (done + step <= HEAP_MAX && os_proc_available_memory() > (400ull << 20)) {
        for (uint64_t p = 0; p < step; p += vm_page_size) *(volatile uint8_t *)(C_HEAP_BASE + done + p) = 1;
        done += step;
    }
    say("  5. guest heap resident: %.2f GB (stopped with 400 MB to spare)", gb(done));
    mem_line("at the peak");
    verdict(done >= (2ull << 30), "at least 2 GB of guest heap on top of 512 MB of textures");

    // 6. a write fault on a read-only heap page, caught and resumed (the runtime's fault watch)
    stack_t ss = {.ss_sp = malloc(1 << 20), .ss_size = 1 << 20};
    sigaltstack(&ss, NULL);
    struct sigaction sa = {0};
    sa.sa_sigaction = on_fault;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    g_fault_page = C_HEAP_BASE;
    int rc = mprotect((void *)C_HEAP_BASE, vm_page_size, PROT_READ);
    *(volatile uint32_t *)C_HEAP_BASE = 7;
    g_fault_page = 0;
    verdict(rc == 0 && g_faults == 1 && *(volatile uint32_t *)C_HEAP_BASE == 7, "6. write fault caught and resumed");

    // let it all go
    for (int i = 0; i < made; i++) dispatch_semaphore_signal(g_hold);
    for (int i = 0; i < made; i++) pthread_join(t[i], NULL);
    [texs removeAllObjects];
    wrap = nil;
    vm_deallocate(mach_task_self(), GUEST_LO, C_GUEST_HI - GUEST_LO);
}

// ---- Metal features the renderer relies on
static void metal(void) {
    say("== Metal features");
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    bool bc = false;
    if (@available(iOS 16.4, *)) bc = dev.supportsBCTextureCompression;
    say("  BC: %s, ASTC: %s, MetalFX spatial: %s", bc ? "yes" : "NO", [dev supportsFamily:MTLGPUFamilyApple2] ? "yes" : "no",
        [MTLFXSpatialScalerDescriptor supportsDevice:dev] ? "yes" : "no");
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
                                                    "kernel void k(device float *o [[buffer(0)]], uint i [[thread_position_in_grid]]) { o[i] = i; }"
                                           options:nil error:&err];
    verdict(lib != nil && bc, "runtime shader compile, BC textures");
}

// ---- experiment: can the range iOS keeps reserved below 0x70_0000_0000 be given back? (last: it may crash)
static void reserved_range(void) {
    say("== experiment: release 1 GB of the reserved range at 0x6000000000");
    vm_address_t a = 0x6000000000ull;
    vm_size_t size;
    natural_t depth = 0;
    struct vm_region_submap_info_64 info;
    mach_msg_type_number_t cnt = VM_REGION_SUBMAP_INFO_COUNT_64;
    if (vm_region_recurse_64(mach_task_self(), &a, &size, &depth, (vm_region_recurse_info_t)&info, &cnt) == KERN_SUCCESS &&
        a <= 0x6000000000ull)
        say("  it's part of 0x%llx-0x%llx, %s/%s, tag %u%s", (uint64_t)a, (uint64_t)(a + size), prot_name(info.protection),
            prot_name(info.max_protection), info.user_tag, info.is_submap ? ", a submap" : "");
    else { say("  nothing mapped there: skipped"); return; }
    say("  trying vm_deallocate (if the probe dies here, that's the answer: no)");
    kern_return_t kr = vm_deallocate(mach_task_self(), 0x6000000000ull, 1ull << 30);
    say("  vm_deallocate: %s", kr_name(kr));
    vm_address_t b = 0x6000000000ull;
    kern_return_t kr2 = vm_allocate(mach_task_self(), &b, 1ull << 30, VM_FLAGS_FIXED);
    say("  then a fixed 1 GB there: %s", kr_name(kr2));
    if (!kr2) {
        *(volatile uint64_t *)b = 1;
        say("  and it's writable: the reserved range CAN be used (a lower MAIN_BASE would fit the full desktop layout)");
    }
}

static void *run(void *arg) {
    (void)arg;
    device_info();
    entitlements();
    address_space();
    desktop_window();
    compact_layout();
    metal();
    say("== %s", g_fails ? "compact layout: some checks failed (above)" : "compact layout: everything holds");
    reserved_range();
    say("== done");
    return NULL;
}

// ---- app
@interface ProbeController : UIViewController
@end

@implementation ProbeController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UIButton *copy = [UIButton buttonWithType:UIButtonTypeSystem];
    [copy setTitle:@"Copy results" forState:UIControlStateNormal];
    copy.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    [copy addTarget:self action:@selector(copyResults) forControlEvents:UIControlEventTouchUpInside];
    g_view = [UITextView new];
    g_view.editable = NO;
    g_view.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    for (UIView *v in @[copy, g_view]) { v.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:v]; }
    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [g_view.topAnchor constraintEqualToAnchor:g.topAnchor], [g_view.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:8],
        [g_view.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-8],
        [g_view.bottomAnchor constraintEqualToAnchor:copy.topAnchor], [copy.bottomAnchor constraintEqualToAnchor:g.bottomAnchor],
        [copy.centerXAnchor constraintEqualToAnchor:g.centerXAnchor], [copy.heightAnchor constraintEqualToConstant:48],
    ]];

    g_out = [NSMutableString new];
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *path = [docs stringByAppendingPathComponent:@"vaprobe.txt"];
    NSString *prev = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    if (prev.length && ![prev containsString:@"== done"])  // (killed last time: show how far it got)
        [g_out appendFormat:@"-- the previous run ended early (iOS killed it, or the last experiment crashed). It got this far:\n%@\n-- new run\n", prev];
    g_file = fopen(path.fileSystemRepresentation, "w");
    pthread_t t;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 8 << 20);
    pthread_create(&t, &attr, run, NULL);
    pthread_attr_destroy(&attr);
}

- (void)copyResults {
    UIPasteboard.generalPasteboard.string = g_out;
}
@end

@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(strong, nonatomic) UIWindow *window;
@end

@implementation SceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [ProbeController new];
    [self.window makeKeyAndVisible];
}
@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation AppDelegate
@end

int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class)); }
}
