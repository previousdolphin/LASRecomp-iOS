// VA Probe: does an iPhone give LAS Recomp the memory layout the runtime assumes? (docs/ios.md)
// Runs what runtime/main.c, runtime/kernel.c and runtime/platform/macos.c do at startup, on the device, and shows the
// results (also in Documents/vaprobe.txt, visible in the Files app). Nothing here uses game files.
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

// ---- the runtime's layout (runtime/rt.h, runtime/kernel.h)
#define GUEST_LO   0x7000000000ull
#define GUEST_HI   0x7320000000ull
#define MAIN_BASE  0x7000000000ull
#define HLE_HEAP   0x7092000000ull
#define ALIAS_BASE 0x7100000000ull
#define STACK_BASE 0x7200000000ull
#define HEAP_BASE  0x7240000000ull
#define HEAP_MAX   0x00D0000000ull  // 3.25 GB
#define HOST_STACK (256ull << 20)   // per guest thread (kernel.c thread_start)

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
        case KERN_NO_SPACE: return "KERN_NO_SPACE (in use or past the top)";
        case KERN_INVALID_ADDRESS: return "KERN_INVALID_ADDRESS (past the top)";
        case KERN_INVALID_ARGUMENT: return "KERN_INVALID_ARGUMENT";
        case KERN_RESOURCE_SHORTAGE: return "KERN_RESOURCE_SHORTAGE";
        default: return mach_error_string(kr);
    }
}

static double gb(uint64_t v) { return v / (double)(1ull << 30); }

// ---- device
static void device_info(void) {
    char machine[64] = "?";
    size_t n = sizeof machine;
    sysctlbyname("hw.machine", machine, &n, NULL, 0);
    uint64_t mem = 0;
    n = sizeof mem;
    sysctlbyname("hw.memsize", &mem, &n, NULL, 0);
    say("== device");
    say("  %s, iOS %s, %.1f GB RAM, %lu-byte pages", machine, UIDevice.currentDevice.systemVersion.UTF8String, gb(mem),
        (unsigned long)vm_page_size);
    say("  available to this app now: %.2f GB (os_proc_available_memory)", gb(os_proc_available_memory()));
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

// ---- address space
static void address_space(void) {
    say("== address space");
    // where a 16K fixed allocation is possible: past the top of the map the kernel says so
    static const uint64_t at[] = {0x200000000ull, 0x800000000ull, 0xF00000000ull, 0x1000000000ull, 0x4000000000ull,
                                  0x7000000000ull, 0x7F00000000ull, 0x40000000000ull, 0x7FFF00000000ull};
    for (size_t i = 0; i < sizeof at / sizeof *at; i++) {
        vm_address_t a = at[i];
        kern_return_t kr = vm_allocate(mach_task_self(), &a, vm_page_size, VM_FLAGS_FIXED);
        say("  fixed 16K at 0x%llx: %s", at[i], kr_name(kr));
        if (kr == KERN_SUCCESS) vm_deallocate(mach_task_self(), a, vm_page_size);
    }
    // the top of what's mapped now (dyld shared cache etc.)
    vm_address_t addr = 0, top = 0;
    vm_size_t size;
    natural_t depth = 0;
    struct vm_region_submap_info_64 info;
    mach_msg_type_number_t cnt;
    for (;;) {
        cnt = VM_REGION_SUBMAP_INFO_COUNT_64;
        if (vm_region_recurse_64(mach_task_self(), &addr, &size, &depth, (vm_region_recurse_info_t)&info, &cnt)) break;
        top = addr + size;
        addr += size;
    }
    say("  highest mapped address now: 0x%llx", (uint64_t)top);
    // the top of the map: past it a fixed allocation is an invalid address, below it it's free or in use
    uint64_t lo = 0, hi = 0x800000000000ull;
    for (size_t i = 0; i < sizeof at / sizeof *at; i++) {
        vm_address_t a = at[i];
        kern_return_t kr = vm_allocate(mach_task_self(), &a, vm_page_size, VM_FLAGS_FIXED);
        if (kr == KERN_SUCCESS) vm_deallocate(mach_task_self(), a, vm_page_size);
        if (kr == KERN_INVALID_ADDRESS) { hi = at[i]; break; }
        lo = at[i];
    }
    while (hi - lo > vm_page_size) {
        uint64_t mid = (lo + (hi - lo) / 2) & ~(uint64_t)(vm_page_size - 1);
        vm_address_t a = mid;
        kern_return_t kr = vm_allocate(mach_task_self(), &a, vm_page_size, VM_FLAGS_FIXED);
        if (kr == KERN_SUCCESS) vm_deallocate(mach_task_self(), a, vm_page_size);
        if (kr == KERN_INVALID_ADDRESS) hi = mid; else lo = mid;
    }
    say("  top of the address space: 0x%llx (guest window needs 0x%llx)", hi, GUEST_HI);
    if (hi > GUEST_LO) say("  room above 0x%llx: %.2f GB (window: %.1f GB)", GUEST_LO, gb(hi - GUEST_LO), gb(GUEST_HI - GUEST_LO));
    // the largest block the kernel will place on its own (what a smaller window would have to fit in)
    uint64_t small = 0, big = 1ull << 40;
    while (big - small > (64ull << 20)) {
        uint64_t sz = (small + (big - small) / 2) & ~((64ull << 20) - 1);
        vm_address_t any = 0;
        if (vm_allocate(mach_task_self(), &any, sz, VM_FLAGS_ANYWHERE) == KERN_SUCCESS) {
            vm_deallocate(mach_task_self(), any, sz);
            small = sz;
        } else big = sz;
    }
    vm_address_t any = 0;
    if (small && !vm_allocate(mach_task_self(), &any, small, VM_FLAGS_ANYWHERE)) {
        say("  largest free block: %.2f GB at 0x%llx", gb(small), (uint64_t)any);
        vm_deallocate(mach_task_self(), any, small);
    }
}

// ---- the runtime's reservation (main.c -> plat_reserve_guest, plat_reset_guest)
static bool guest_window(void) {
    say("== guest window 0x%llx-0x%llx (%.1f GB, guest addresses == host addresses)", GUEST_LO, GUEST_HI,
        gb(GUEST_HI - GUEST_LO));
    vm_address_t a = GUEST_LO;
    kern_return_t kr = vm_allocate(mach_task_self(), &a, GUEST_HI - GUEST_LO, VM_FLAGS_FIXED);
    say("  vm_allocate fixed: %s", kr_name(kr));
    if (kr) {
        void *m = mmap((void *)GUEST_LO, GUEST_HI - GUEST_LO, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE | MAP_FIXED, -1, 0);
        say("  mmap MAP_FIXED: %s", m == MAP_FAILED ? strerror(errno) : "ok");
        if (m == MAP_FAILED) { verdict(false, "reserve the guest window at the runtime's address"); return false; }
    }
    verdict(true, "reserve the guest window at the runtime's address");
    static const uint64_t touch[] = {MAIN_BASE, HLE_HEAP, ALIAS_BASE, STACK_BASE, HEAP_BASE, GUEST_HI - 0x4000};
    for (size_t i = 0; i < sizeof touch / sizeof *touch; i++) *(volatile uint64_t *)touch[i] = 0x1A51A5;
    verdict(true, "write to every region (main, HLE heap, alias, stacks, heap, top)");
    a = GUEST_LO;
    kr = vm_allocate(mach_task_self(), &a, GUEST_HI - GUEST_LO, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE);
    verdict(kr == KERN_SUCCESS && *(volatile uint64_t *)HEAP_BASE == 0, "reset to zero pages (reboot, VM_FLAGS_OVERWRITE)");
    return true;
}

// How much of the guest heap can be made resident before iOS's limit (the game itself uses less than all of it).
static void heap_commit(uint64_t heap) {
    say("== heap commit at 0x%llx (stops while 400 MB are still free, so iOS doesn't kill the probe)", heap);
    uint64_t done = 0, step = 64ull << 20;
    while (done + step <= HEAP_MAX && os_proc_available_memory() > (400ull << 20)) {
        for (uint64_t p = 0; p < step; p += vm_page_size) *(volatile uint8_t *)(heap + done + p) = 1;
        done += step;
        if (done % (512ull << 20) == 0) say("  %.1f GB resident, %.2f GB left", gb(done), gb(os_proc_available_memory()));
    }
    say("  resident in the guest heap: %.2f GB of %.2f GB, %.2f GB left", gb(done), gb(HEAP_MAX), gb(os_proc_available_memory()));
    verdict(done >= (2ull << 30), "at least 2 GB of guest heap resident");
    vm_address_t a = heap;  // (give it back: fresh zero pages)
    vm_allocate(mach_task_self(), &a, HEAP_MAX, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE);
}

// ---- guest threads: each gets a 256 MB host stack (guest recursion runs on it)
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

static void threads(void) {
    enum { N = 64 };
    say("== up to %d threads with %llu MB stacks, all alive at once", N, HOST_STACK >> 20);
    g_hold = dispatch_semaphore_create(0);
    pthread_t t[N];
    int made = 0, err = 0;
    for (int i = 0; i < N; i++) {
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        pthread_attr_setstacksize(&attr, HOST_STACK);
        err = pthread_create(&t[made], &attr, thread_body, NULL);
        pthread_attr_destroy(&attr);
        if (err) break;
        made++;
    }
    for (int i = 0; i < 200 && g_touched < made; i++) usleep(10000);
    say("  created %d (%s), %d touched their stacks", made, err ? strerror(err) : "no errors", g_touched);
    for (int i = 0; i < made; i++) dispatch_semaphore_signal(g_hold);
    for (int i = 0; i < made; i++) pthread_join(t[i], NULL);
    say("  that's %.1f GB of stacks", gb(made * HOST_STACK));
    verdict(made >= 32 && g_touched == made, "at least 32 threads created and running");
}

// ---- write faults on protected guest pages, handled and resumed (the runtime's rt_fault_watch)
static volatile uint64_t g_fault_page;
static volatile int g_faults;

static void on_fault(int sig, siginfo_t *si, void *ctx) {
    (void)sig, (void)ctx;
    uint64_t fa = (uint64_t)si->si_addr;
    if (g_fault_page && fa - g_fault_page < vm_page_size) {
        g_faults++;
        mprotect((void *)g_fault_page, vm_page_size, PROT_READ | PROT_WRITE);
        return;
    }
    signal(sig, SIG_DFL);
}

static void faults(uint64_t page) {
    say("== write fault on a read-only guest page, handled");
    stack_t ss = {.ss_sp = malloc(1 << 20), .ss_size = 1 << 20};
    sigaltstack(&ss, NULL);
    struct sigaction sa = {0};
    sa.sa_sigaction = on_fault;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    g_fault_page = page;
    int rc = mprotect((void *)page, vm_page_size, PROT_READ);
    say("  mprotect read-only: %s", rc ? strerror(errno) : "ok");
    *(volatile uint32_t *)page = 7;
    g_fault_page = 0;
    verdict(rc == 0 && g_faults == 1 && *(volatile uint32_t *)page == 7, "fault caught, page unprotected, write landed");
}

// ---- Metal: what the renderer (runtime/nvn/metal.m, renderer.m) relies on
static void metal(void) {
    say("== Metal");
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) { verdict(false, "Metal device"); return; }
    say("  %s, Apple9 family: %s, working set: %.2f GB", dev.name.UTF8String, [dev supportsFamily:MTLGPUFamilyApple9] ? "yes" : "no",
        gb(dev.recommendedMaxWorkingSetSize));
    bool bc = false;
    if (@available(iOS 16.4, *)) bc = dev.supportsBCTextureCompression;
    say("  BC textures (BC1-7, used directly by metal.m): %s", bc ? "supported" : "NOT supported -> needs a CPU decode fallback");
    say("  ASTC textures: %s", [dev supportsFamily:MTLGPUFamilyApple2] ? "supported" : "no");
    say("  MetalFX spatial scaler: %s", [MTLFXSpatialScalerDescriptor supportsDevice:dev] ? "supported" : "no");
    NSError *err = nil;
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    id<MTLLibrary> lib = [dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
                                                    "kernel void k(device float *o [[buffer(0)]], uint i [[thread_position_in_grid]]) { o[i] = i; }"
                                           options:nil error:&err];
    say("  runtime MSL compile: %s (%.0f ms)", lib ? "ok" : err.localizedDescription.UTF8String,
        (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6);
    verdict(lib != nil, "compile shaders from source at runtime (how the renderer builds every shader)");
}

static void *run(void *arg) {
    (void)arg;
    device_info();
    entitlements();
    address_space();
    vm_address_t heap = HEAP_BASE;
    if (!guest_window()) {  // (still measure the memory limit: a block the guest heap's size, wherever it fits)
        heap = 0;
        if (vm_allocate(mach_task_self(), &heap, HEAP_MAX, VM_FLAGS_ANYWHERE)) heap = 0;
        say("  (heap test on a %.2f GB block %s instead)", gb(HEAP_MAX), heap ? "placed anywhere" : "- none free");
    }
    if (heap) heap_commit(heap);
    threads();
    if (heap) faults(heap);
    metal();
    say("== done: %s", g_fails ? "some checks failed (above)" : "everything the runtime assumes holds");
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
        [g_out appendFormat:@"-- the previous run ended early (iOS probably killed it). It got this far:\n%@\n-- new run\n", prev];
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
