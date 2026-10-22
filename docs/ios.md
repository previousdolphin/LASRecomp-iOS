# LAS Recomp on iOS

This fork ports [LAS Recomp](https://github.com/peiikai/LASRecomp) to the iPhone, starting with the iPhone 15 Pro
(A17 Pro, 8 GB). It stays a static recompilation: the game's Switch code becomes native arm64 code compiled ahead of
time, exactly as on macOS. Nothing is emulated and nothing needs JIT, which is the main thing iOS restricts for
emulators.

The recompiled code already targets arm64 and the macOS build already renders with Metal, so most of the runtime
carries over. The work is in the host layer around it.

## Status

| Step | State |
| --- | --- |
| 1. Memory layout probe on a real device (`tools/ios/vaprobe`) | free-account runs 1-2 done (below); v3 tests the compact layout |
| 1b. Compact iOS layout in the runtime (`rt.h`, `kernel.h`, host stack size) | designed (below), not written |
| 2. Game code built on a Mac and linked into the app | not started |
| 3. `runtime/platform/ios.c`, no child processes | not started |
| 4. Metal: CPU fallback for BC textures | not needed: the A17 Pro supports BC1-7 |
| 5. Touch controls, file picking, Files-app data folder | not started |

## What has to change

**1. The guest window.** Guest addresses are host addresses (`runtime/rt.h`): the runtime claims a fixed 12.5 GB
block at `0x70_0000_0000` at startup, and every guest thread gets a 256 MB host stack (`runtime/kernel.c`). By
default the top of an iOS app's address space is just past `0x70_0000_0000`, short of the block's end at
`0x73_2000_0000`. XNU raises the cap for apps with the Extended Virtual Addressing entitlement, which needs a paid
developer account (or TrollStore). Moving the guest lower is not an option: iOS reserves `0x2_0000_0000` to
`0x70_0000_0000`, the same range macOS does (see the comment in `runtime/rt.h`). Without the entitlement the answer
is the compact layout below: a 4.5 GB window that fits the 6 GB a free account gets.

**2. No building on the phone.** On desktop the start screen runs the generator (Python) and a bundled compiler on
the player's game files, then `dlopen`s the result. iOS allows none of that. On iOS the game code is generated on a
Mac with `make gen`, compiled for `arm64-apple-ios` and linked into the app; the setup step is hidden. That means the
app contains code recompiled from the game, so **an iOS build is for the person who made it, from their own game
files, on their own device. Never share the IPA.**

**3. No child processes.** Three `plat_spawn` callers: the update check (curl, `runtime/ui/launcher.mm`), the seed
generator (Python, `runtime/ui/rando_tab.mm`) and the game build. On iOS the update check goes or uses
`NSURLSession`, and seeds are generated on a Mac and copied over in the Files app (embedding Python with its `oead`
native module is possible later but is its own project).

**4. Metal.** Shaders are compiled from MSL source at runtime, which iOS allows; buffers already use shared storage;
ASTC, BC1-7 and MetalFX are all supported on the A17 Pro (probe run 1). The open question is `maxBufferLength`:
`runtime/nvn/metal.m` wraps the whole guest heap in one no-copy `MTLBuffer` (GPU addresses are guest addresses), and
stops with `FATAL` if the device won't make a buffer that big. Probe v3 measures it.

**5. Everything else.** SDL3 and FFmpeg built for iOS (or AVFoundation for the movies), the Increased Memory Limit
entitlement (iOS gives an 8 GB iPhone roughly 6 GB with it; the guest heap is capped at 3.25 GB), an on-screen
controller drawn with the existing ImGui UI (Bluetooth controllers work through SDL as they are), and saves and
settings in the app's Documents folder.

## The compact layout (no Extended Virtual Addressing)

A free account gets one 6 GB block of address space, `0x70_0000_0000`-`0x71_8000_0000` (probe run 2), and about
3.3 GB of memory. The desktop window is 12.5 GB of addresses, but most of that is empty space between regions: what
the game actually touches is far less (untouched pages cost nothing, see `runtime/platform/macos.c`). Only `MAIN_BASE`
and `SDK_BASE` are baked into the generated code (`runtime/gamebuild.c` passes them to the generator). Every other
region is placed by the runtime and reported to the game through `svcGetInfo` (`runtime/kernel.c`), so it can move
without regenerating anything:

| Region | Desktop | Compact (iOS) |
| --- | --- | --- |
| main, sdk | `0x70_0000_0000`, `0x70_0400_0000` | unchanged |
| HLE functions (1 MB), TLS (1 MB) | `0x70_8000_0000`, `0x70_9000_0000` | `0x70_1000_0000`, `0x70_1010_0000` |
| HLE heap (224 MB) | `0x70_9200_0000` | `0x70_1100_0000` |
| alias (svcMapMemory targets) | `0x71_0000_0000`, 4 GB | `0x70_2000_0000`, 512 MB |
| guest stacks | `0x72_0000_0000`, 1 GB | `0x70_4000_0000`, 256 MB |
| heap (SetHeapSize cap) | `0x72_4000_0000`, 3.25 GB | `0x70_5000_0000`, 3.25 GB |
| window end | `0x73_2000_0000` (12.5 GB) | `0x71_2000_0000` (4.5 GB) |
| host stack per guest thread | 256 MB | 32 MB |

That leaves 1.5 GB of the block for the host: thread stacks, malloc, Metal. The guest heap keeps its full 3.25 GB cap,
because that's also what the game is told it can have (`svcGetInfo` 6/21 report 3.2 GB of application memory). If
the game's SDK sizes its heap from that, a smaller cap could make it fail at boot.

Things to watch:

- **Host stacks.** 256 MB is there because guest recursion runs on the host stack. 32 MB is a guess. A stack
  overflow hits the guard page and the crash handler reports it, so it fails loudly. A desktop run that records each
  thread's deepest stack use would turn the guess into a number.
- **Alias region.** The game finds free space for `svcMapMemory` through `QueryMemory` in the regions `svcGetInfo`
  reports, so a smaller alias region should just get used more tightly. Watch for `MapMemory` failures in the log.
- **Memory, not addresses, is then the limit.** About 3.3 GB without Increased Memory Limit, shared by the guest heap
  and the renderer's texture copies (`metal.m` copies guest textures into Metal textures). Levers, in order: the
  Increased Memory Limit entitlement (free accounts may be able to get it through SideStore-style tools; not
  verified), a lower internal resolution, and freeing the guest copy of a texture once Metal has it (needs the write
  tracking that macOS doesn't have yet, `plat_written_pages`).
- **Gating.** On iOS the layout is picked at startup: the desktop window when Extended Virtual Addressing gave enough
  room, the compact one otherwise, so a paid-account build keeps the desktop layout. That means the region constants
  become variables, reported to the game the same way.

## Probe results

**Run 1:** iPhone 15 Pro Max (iPhone16,2), iOS 27.2, free Apple ID (no entitlements granted), probe v1.

- Fixed allocations from `0x2_0000_0000` to `0x40_0000_0000` all report in use; the highest mapped region ends at
  exactly `0x70_0000_0000`. A 16K block at `0x70_0000_0000` works; at `0x7f_0000_0000` it's past the top.
- The runtime's 12.5 GB window: past the top (`vm_allocate` and `mmap` both fail). No 12.5 GB block fits anywhere.
- 30 of 32 threads with 256 MB stacks, then `EAGAIN`: the same address-space ceiling (7.5 GB of stacks).
- 3.29 GB available to the app.
- Metal: A17 Pro, Apple9 family, 5.33 GB working set, BC1-7 and ASTC supported, MetalFX supported, runtime MSL
  compile works (119 ms for a trivial kernel).

**Run 2:** same phone and account, probe v2.

- The top of the address space is `0x71_8000_0000`: 6.00 GB above `0x70_0000_0000`, and that is the largest free
  block anywhere.
- 2.94 GB of a heap-sized block made resident before 400 MB were left: the memory limit is about 3.3 GB.
- 16 threads with 256 MB stacks (4 GB) with the 3.25 GB heap block held: the address space ran out again.
- The fault test passed: a write to a read-only page was caught, the page unprotected, the write landed.

Probe v3 tests the compact layout end to end in the runtime's order. It reserves the 4.5 GB window, wraps the heap
in a Metal buffer (and finds the largest one that works if 3.25 GB doesn't), creates 512 MB of private textures,
starts 48 threads with 32 MB stacks, then fills the heap to the memory limit. It also lists every large mapping and
hole. Last, it tries an experiment: releasing 1 GB of the reserved range below `0x70_0000_0000`. If that works, a
lower `MAIN_BASE` would fit the whole desktop layout without the entitlement.

## The probe

`tools/ios/vaprobe` is a small standalone app (no game files involved) that does on the device what the runtime does
at startup, and reports:

- which entitlements the signing actually granted
- the top of the address space, and every mapping of 256 MB+ and hole of 64 MB+
- whether the desktop window fits
- the compact layout end to end: window, reboot reset, Metal wrapper over the heap, 512 MB of textures, 48 guest
  threads, the heap filled to the memory limit, a write fault caught and resumed
- Metal: BC and ASTC support, MetalFX, runtime shader compilation
- the reserved-range experiment (last, since it may crash the probe)

Results show on screen (Copy results button) and in `vaprobe.txt` in the app's folder in the Files app. If iOS kills
the probe partway, the next launch shows how far it got.

### Getting it on the phone

1. Get the IPA: the **iOS VA probe** workflow builds it on every change to `tools/ios/vaprobe/` (Actions tab, latest
   run, artifact `VAProbe-ipa-<runner>`; either one is fine), or run `tools/ios/vaprobe/build.sh` on a Mac with Xcode.
2. Sideload it with your Apple ID: AltStore / SideStore, Sideloadly, or Xcode. With a free account the entitlements
   are dropped, which is itself a useful run: it shows what iOS gives without them.
3. For the full test, sign with a paid developer account that has Extended Virtual Addressing and Increased Memory
   Limit enabled for the app ID (developer.apple.com > Identifiers > the app ID > Capabilities).
4. Open it and let it finish. Paste the results into an issue or back to whoever is working on the port.

Run it both ways if you can, without and with the entitlements: the difference is the answer to step 1.
