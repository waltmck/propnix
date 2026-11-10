# i386 Linux guests under FEX (Civilization V)

Sid Meier's Civilization V, as Aspyr's i386 Linux build (`Civ5XP`, a 36 MB i386 ELF), is propnix's
i386-linux title. It runs on aarch64 with 16 KiB pages through the thin `fex` backend and
emulators/fex-linux. This doc records what the title needs beyond the backend, how a silent failure
of this kind is made visible, and what a working run looks like. The emulator fork and the backend
are described where they live (see the last section); this doc only points at them.

## The environment the game needs

Two variables in the title's `env`, both load-bearing, both measured on Asahi aarch64 (16 KiB pages,
Wayland + Xwayland):

    env = {
      SDL_VIDEODRIVER = "x11";
      ALSOFT_DRIVERS = "pulse,alsa";
    };

### `SDL_VIDEODRIVER=x11`

Without it the game exits 0 in silence: nothing on stdout, nothing in the logs, no window. The
game's SDL2 dates from 2014. It tries its Wayland backend first, that fails, and `ASL::SDL::Init()`
then calls `ASL::ErrorDie` → `ASL::Exit`. The pin is required rather than defensive: the thin
launcher sets `SDL_VIDEODRIVER=wayland` whenever a Wayland session is present and the game's config
does not pin the variable (`PROPNIX_SDL_VIDEODRIVER` overrides that default, not a pinned value).

X11 here means Xwayland. FEX thunks GL and EGL, and builds a libwayland-client thunk that propnix
does not stage, but it does not thunk X11. libX11 is therefore a real guest library: the i686 X set
(`libx11`, `libxext`, `libxcursor`, `libxinerama`, `libxi`, `libxrandr`, `libxxf86vm`, `libxrender`,
`libxfixes`) in `box64.guestLibs`, cross-built from `pkgsCross.gnu32` on aarch64. `libX11` and zlib
are in Civ5XP's `DT_NEEDED`, so ld.so refuses to start without them on any desktop; SDL dlopens the
remaining X extensions by soname.

### Finding a silent exit: an i386 `LD_PRELOAD` stub

The SDL exit above is pinned down by an i386 shared object preloaded into the guest: it hooks `exit`
to print a symbolised guest backtrace (which names `ASL::ErrorDie`), and `vsnprintf` to print the
driver name SDL is formatting. This works because FEX runs the real guest ld.so, which honours
`LD_PRELOAD` (the host's ld.so, loading FEXInterpreter itself, reports the ELF-class mismatch for
the x86 object and skips it). The launcher scrubs an inherited `LD_PRELOAD`, so a debugging preload
goes through the build: `.apply { box64.guestPreload = [ "<store path of the i686 .so>" ]; }`, which
the `fex` backend emits as the guest's `LD_PRELOAD`.

### `ALSOFT_DRIVERS=pulse,alsa`

The port's bundled OpenAL Soft otherwise picks OSS and plays nothing.

- Pulse first. With alsa, the `default` PCM routes through PipeWire's aarch64
  `libasound_module_pcm_pipewire.so`, which a 32-bit guest cannot load. The i686 `libpulseaudio`
  client in `guestLibs` talks to pipewire-pulse over a socket and needs nothing loaded into the
  guest.
- `alsa-lib` stays in `guestLibs` to back the `,alsa` fallback.
- FEX's own asound thunk is not available to a 32-bit guest: upstream's ThunkLibs CMake gates asound
  (and vulkan, and drm) behind `if (BITNESS EQUAL 64)`.
- Never point ALSA at `hw:0`. On the Asahi host card 0 is `macaudio`, whose speakers rely on
  PipeWire's DSP chain for excursion limiting.

Audio is verified objectively, not by an absence of errors: `wpctl status` lists a live `Civ5XP`
PipeWire stream within 5 s of launch.

### What the backend supplies

Everything else the run needs is the `fex` backend's job: `FEX_ROOTFS=/`; the guest ld.so stamped as
`PT_INTERP` into a patched copy of Civ5XP at the game path (FEX rewrites `/proc/self/exe` to the
program it was given, and Civ V locates its assets relative to its own binary); FEX's GL guest thunk
staged as `libGL.so.1`; and the scrub of an inherited `LD_PRELOAD` (the host's aarch64 `libmimalloc`
SIGSEGVs the guest ~5 s in). x87 reduced precision, on by default, is the largest single performance
lever for this guest (D12 in docs/DESIGN.md).

## A working run

On Asahi aarch64 (16 KiB pages, Wayland + Xwayland) Civ5XP starts, initialises every engine system
and reaches the main menu's DLC/mods pass. Its own logs show `Unit_System::Startup()`,
`City_System`, `LandmarkSystem`, `TerrainSystem`, `LeaderHead_System`, `Combat_System` and
`AudioSimSystem` completing, then

    Civilization 5: App Version: 403694 FINAL_RELEASE, GameCore: {478F7A6E-…}
    Changing active DLC and Mods

and audio is live (the `Civ5XP` PipeWire stream above). The window's class is `Civ5XP` in its
original case (`hyprctl -j clients`).

Where to look, all under `$PROPNIX_SAVE_DIR/civilization-5/` (bound at `.local/share/Aspyr`):

- `Sid Meier's Civilization 5/Logs/`: the engine logs.
- `Sid Meier's Civilization 5/cache/`: the SQLite gameplay databases the engine builds from the XML
  on first run.
- `com.aspyr.civ5xp.json`: the shim layer's GL-capability probe and the fullscreen flag
  (`DisplayFullScreen`), a per-GPU cache redone on every launch if it is not kept.

The first start is slow (minutes) because the engine builds the SQLite databases from the XML; the
save bind keeps them, so later starts skip it.

## Known rough edges

None is fatal.

- The engine logs a benign upstream XML warning on database build:
  `columns StrategicViewType, TileType are not unique`.
- DLC entitlement answers come from gbe_fork, not a Steam client, so a pack is visible only when it
  is enabled through `dlc.enabled`. The game's own store page inside the menu does nothing offline,
  by design.
- A mounted pack stays inactive unless the engine appid written inside its `.civ5pkg` descriptor is
  also claimed (docs/research/steam-dlc-appids.md).

## The emulator and the backend

Short pointers; the details live with the code.

- emulators/fex-linux: why it is a fork (upstream FEX >= 2508 requires a 4 KiB kernel page, and
  stock FEX's jemalloc refuses with "Unsupported system page size" on a 16 KiB host); the host page
  derived from `sysconf(_SC_PAGESIZE)` while the guest page stays 4 KiB; jemalloc's `LG_PAGE` set to
  64 KiB for page-size portability. Its patches: `0001` large-host-page support, `0002`
  64BitAllocator addresses at host-page granularity (the 32-bit-guest allocator; i386 guests ran
  ~2/5 of the time without it), `0003` sub-host-page mmap emulation on the 32-bit syscall path
  (dynamically linked i386 guests), `0004` the FutexSpin test's clock tolerance. The `installCheck`
  runs all four guest classes (i386 and x86_64, static and dynamic).
- lib/backends/fex/default.nix: `FEX_ROOTFS=/` rather than a real rootfs (FEX re-resolves an
  absolute symlink target inside the rootfs, so store-path symlinks break); the patched-`PT_INTERP`
  overlay; GL and EGL thunks only.
- Why FEX for i386 Linux: box64 emulates x86_64 only, and box86 is dead on 16 KiB pages, so
  `resolveStrategy` sends `i386-linux` to FEX (D12).
- What FEX does not carry on a 16 KiB host: a Mono/JIT engine, because FEX's self-modifying-code
  tracking is 4 KiB-granular against the host page. That is a per-engine wall recorded in the
  affected title (Hollow Knight under `backend = "fex"`); a native C++ engine like Civ V's is
  unaffected.
- x86_64 hosts run this payload natively and are refused: `libGL.so.1` is in Civ5XP's `DT_NEEDED`,
  and propnix's fallback GL stack is host-arch only, with no 32-bit `/run/opengl-driver-32` probe.
