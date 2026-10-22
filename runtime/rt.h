// Runtime-internal declarations.
#pragma once
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>

#include "cpu.h"
#include "platform.h"

#define LOG(...) fprintf(stderr, __VA_ARGS__)
#define FATAL(...) (fprintf(stderr, "FATAL: " __VA_ARGS__), rt_fatal_trace())

// ---- address space layout (guest addresses == host addresses)
// macOS reserves 0x2_0000_0000-0x70_0000_0000, and guest addresses must fit in 39 bits, so the
// guest lives in a 12.5 GB window at 0x70_0000_0000 claimed at startup (see main.c).
// iOS guards 0x10_0000_0000-0x70_0000_0000 too, and without the Extended Virtual Addressing entitlement its address
// space ends at 0x71_8000_0000, so iOS builds use the compact layout: a 4.5 GB window, with everything the runtime
// places itself moved down next to main and sdk (whose addresses are in the generated code) and the alias region and
// guest stacks shrunk (docs/ios.md). -DLARECOMP_COMPACT_LAYOUT=1 tries it on desktop.
#if !defined(LARECOMP_COMPACT_LAYOUT) && defined(__APPLE__)
#include <TargetConditionals.h>
#define LARECOMP_COMPACT_LAYOUT TARGET_OS_IOS
#endif
#define GUEST_LO     0x7000000000ull
#define MAIN_BASE    0x7000000000ull
#define SDK_BASE     0x7004000000ull
#define HLE_SIZE     0x0000100000ull
#define TLS_SIZE     0x0000100000ull
#define HLE_HEAP_SIZE 0x000E000000ull
#define HEAP_MAX     0x00D0000000ull   // 3.25 GB
#if LARECOMP_COMPACT_LAYOUT
#define HLE_BASE     0x7010000000ull   // fake addresses for host-implemented functions
#define TLS_BASE     0x7010100000ull
#define HLE_HEAP     0x7011000000ull   // guest-visible memory owned by host code
#define ALIAS_BASE   0x7020000000ull   // alias region (svcMapMemory targets)
#define ALIAS_SIZE   0x0020000000ull
#define GSTACK_BASE  0x7040000000ull   // guest stacks (kernel.h STACK_BASE)
#define GSTACK_SIZE  0x0010000000ull
#define HEAP_BASE    0x7050000000ull
#define GUEST_HI     0x7120000000ull
#define HOST_STACK_SIZE (32ull << 20)  // per guest thread: guest recursion runs on the host stack
#else
#define HLE_BASE     0x7080000000ull   // fake addresses for host-implemented functions
#define TLS_BASE     0x7090000000ull
#define HLE_HEAP     0x7092000000ull   // guest-visible memory owned by host code
#define ALIAS_BASE   0x7100000000ull   // alias region (svcMapMemory targets)
#define ALIAS_SIZE   0x0100000000ull
#define GSTACK_BASE  0x7200000000ull   // guest stacks (kernel.h STACK_BASE)
#define GSTACK_SIZE  0x0040000000ull
#define HEAP_BASE    0x7240000000ull
#define GUEST_HI     0x7320000000ull
#define HOST_STACK_SIZE (256ull << 20)  // per guest thread: guest recursion runs on the host stack
#endif
_Static_assert(SDK_BASE < HLE_BASE && HLE_BASE + HLE_SIZE <= TLS_BASE && TLS_BASE + TLS_SIZE <= HLE_HEAP &&
                   HLE_HEAP + HLE_HEAP_SIZE <= ALIAS_BASE && ALIAS_BASE + ALIAS_SIZE <= GSTACK_BASE &&
                   GSTACK_BASE + GSTACK_SIZE <= HEAP_BASE && HEAP_BASE + HEAP_MAX <= GUEST_HI,
               "guest regions overlap or leave the window");

// ---- loader.c
typedef struct Module {
    const char *name;
    uint64_t base, size;
    uint64_t text_off, text_size, ro_off, ro_size, data_off, data_size;
    uint64_t dynamic, init, fini, init_array, init_array_sz, fini_array, fini_array_sz;
    uint64_t symtab, strtab, nsyms;
} Module;

extern Module g_modules[4];
extern int g_nmodules;
void loader_load(const char *exefs_dir);  // (again after a reboot: modules are reloaded into wiped memory)
uint64_t loader_find_symbol(const char *name);
const char *loader_symbol_at(uint64_t addr, uint64_t *offset);

// ---- dispatch.c
typedef void (*HostFn)(Cpu *c);
void dispatch_init(void);
GuestFn dispatch_lookup(uint64_t addr);
uint64_t hle_register(const char *name, HostFn fn);  // returns fake guest address
HostFn hle_lookup_impl(const char *name);
void hle_override(uint64_t guest_addr, HostFn fn, const char *name);
void rt_fatal_trace(void) __attribute__((noreturn));
void crash_handler_install(void);  // per thread (alternate signal stack)

// ---- kernel.c
typedef struct KThread KThread;
void kernel_init(void);
void kernel_stop_threads(void (*idle)(void));  // reboot: unwind every guest thread and join it (idle: called while waiting)
void kernel_reset(void);                       // reboot: empty handle table, memory map, thread list
KThread *kernel_create_main_thread(uint64_t entry, uint64_t stack_size, int prio);
void kernel_run_main(KThread *t, uint64_t x0, uint64_t x1, uint64_t x2, uint64_t x3);
uint32_t kernel_current_thread_handle(void);
Cpu *kernel_current_cpu(void);

// ---- ipc.c
typedef struct Service Service;
int ipc_handle_request(Cpu *c, uint32_t handle);
uint32_t ipc_connect_named_port(const char *name);

// ---- in-place reboot (main.c): switch seeds or go back to the start screen without leaving the process
enum { RT_REBOOT_NONE, RT_REBOOT_GAME, RT_REBOOT_TITLE };  // GAME: boot again at once (new seed); TITLE: start screen
void rt_request_reboot(int kind);  // any thread; the window loop (ui_run) returns it and main() carries it out
int rt_reboot_requested(void);
extern volatile int g_rt_unwind;   // set while guest threads are being stopped (kernel.c)
void rt_unwind_point(void);        // guest threads: unwind to thread_main if a reboot is stopping them

// ---- ui (runtime/nvn/metal.m)
int ui_run(void);  // window loop; returns the reboot kind requested (the window stays open)

// ---- helpers
void guest_call(Cpu *c, uint64_t addr);   // call guest function at addr (saves/restores x30)
uint64_t guest_sym(const char *name);     // cached loader_find_symbol, fatal if missing
void *hle_alloc(uint64_t size);           // zeroed guest-visible memory (never freed)
extern const char *g_romfs_dir;
