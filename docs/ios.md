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
| 1. Memory layout probe on a real device (`tools/ios/vaprobe`) | written, waiting on device results |
| 2. Game code built on a Mac and linked into the app | not started |
| 3. `runtime/platform/ios.c`, no child processes | not started |
| 4. Metal: CPU fallback for BC textures if the device lacks them | not started |
| 5. Touch controls, file picking, Files-app data folder | not started |

## What has to change

**1. The guest window.** Guest addresses are host addresses (`runtime/rt.h`): the runtime claims a fixed 12.5 GB
block at `0x70_0000_0000` at startup, and every guest thread gets a 256 MB host stack (`runtime/kernel.c`). By
default iOS caps an app's address space near 63 GB, well below that block. XNU raises the cap for apps with the
Extended Virtual Addressing entitlement, which needs a paid developer account (or TrollStore). If that isn't enough,
plan B is to move the guest lower: regenerate the game code with new base addresses (`runtime/gamebuild.c` passes
them to the generator) and make the handful of absolute addresses in `runtime/ui/` relative to `MAIN_BASE`. The probe
decides which.

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
ASTC is native on iPhone and MetalFX exists on iOS 16+. The open question is BC1-7, which `runtime/nvn/metal.m` uses
directly. If the device reports no BC support, those textures get decoded on the CPU at upload time.

**5. Everything else.** SDL3 and FFmpeg built for iOS (or AVFoundation for the movies), the Increased Memory Limit
entitlement (iOS gives an 8 GB iPhone roughly 6 GB with it; the guest heap is capped at 3.25 GB), an on-screen
controller drawn with the existing ImGui UI (Bluetooth controllers work through SDL as they are), and saves and
settings in the app's Documents folder.

## The probe

`tools/ios/vaprobe` is a small standalone app (no game files involved) that does on the device what the runtime does
at startup, and reports:

- which entitlements the signing actually granted
- where fixed allocations are possible, the top of the map, and where a 12.5 GB block lands on its own (for plan B)
- the runtime's own reservation at `0x70_0000_0000`, a write to each region, and the reboot reset
- how much of the guest heap can be made resident before iOS's memory limit
- 32 threads with 256 MB stacks alive at once
- a write fault on a read-only guest page, caught and resumed (what the runtime's fault watch relies on)
- Metal: BC and ASTC support, MetalFX, runtime shader compilation

Results show on screen (Copy results button) and in `vaprobe.txt` in the app's folder in the Files app. If iOS kills
the probe partway, the next launch shows how far it got.

### Getting it on the phone

1. Get the IPA: the **iOS VA probe** workflow builds it on every change to `tools/ios/vaprobe/` (Actions tab, latest
   run, artifact `VAProbe-ipa`), or run `tools/ios/vaprobe/build.sh` on a Mac with Xcode.
2. Sideload it with your Apple ID: AltStore / SideStore, Sideloadly, or Xcode. With a free account the entitlements
   are dropped, which is itself a useful run: it shows what iOS gives without them.
3. For the full test, sign with a paid developer account that has Extended Virtual Addressing and Increased Memory
   Limit enabled for the app ID (developer.apple.com > Identifiers > the app ID > Capabilities).
4. Open it and let it finish. Paste the results into an issue or back to whoever is working on the port.

Run it both ways if you can, without and with the entitlements: the difference is the answer to step 1.
