# Wine Mono: an instance delegate collected mid-callback (Space Engineers on aarch64)

The investigation behind `emulators/wine-mono/patches/0001-marshal-hold-instance-delegate-strongly.patch`
and behind the absence of any per-game GC or `MONO_DEBUG` setting in `pkgs/games/space-engineers`. The
patch header carries the mechanism and the probe measurements; this records how the defect was found and
what was ruled out on the way.

## The failure

On the unpatched runtime the process dies ~2.5 s in, before any window, with the CLR up and managed
`Main` already running:

    TypeInitializationException: type initializer for 'VRageRender.MyRender11' threw
      ---> NullReferenceException
      at VRageRender.MySharedData..ctor [0x0002c] → MySwapQueue.Create<MyBillboardBatch<MyBillboard>>
      at VRageRender.MyDX11Render..ctor → SpaceEngineers.MyProgram.InitializeRender → Main

IL offset 0x2c in MySharedData..ctor is exactly the `Create<MyBillboardBatch<MyBillboard>>` call (the
preceding `Create<HashSet<uint>>` at IL_000c succeeds, so generics and Activator are fine), and that
batch's ctor calls `new MyObjectsPool<T>(3000, null, null)`, whose null-activator branch goes through
VRage's `ExpressionExtension.CreateActivator<T>()` — a static field holding an IActivatorFactory, then
`Expression.Lambda<Func<T>>(...).Compile()`, then 3000 `activator()` calls. `PROPNIX_WINEDEBUG=+seh`
shows the native truth: EXCEPTION_ACCESS_VIOLATION, info[0]=0 (a READ) of address 0x10, rip inside
JIT-generated x86_64 code (cs=0033). 0x10 is the first instance field of a 64-bit Mono object (vtable +
sync block = 16 bytes), and it is also where an interface callvirt on a null receiver lands — consistent
with either the static Factory or the compiled activator being null.

## Intermittent

One launch out of roughly ten got all the way past render init — zero exceptions, DXVK adapter at
feature_level 11.1, through MyGuiManager.LoadContent and into loading its 874 definition files, alive
for 3+ minutes — while every other attempt died at the same 2.5 s point. A race or an ordering effect,
not a missing capability. (The x86_64 package notes record the same title being load-sensitive at cold
start, possibly the same flakiness with a far smaller window there.)

## Ruled out, each by an isolated run on this host

* Wine Mono itself — a managed exe runs fine (Environment.Version = 4.0.30319.42000).
* WRONGLY ruled out at first, and kept as the lesson: the frame the managed trace blamed
  (System.Windows.Forms.Screen's monitor-enumeration callback) passed a probe exercising plain P/Invoke, a
  managed callback invoked from native EnumDisplayMonitors, Screen.AllScreens and PrimaryScreen — but only
  because that probe did not ALLOCATE while the callback was pending. With allocation churn added, the same
  callback fails 138/150 on the upstream runtime, which is exactly the defect patches/0001 fixes. The trace
  had pointed at the right place all along; a probe rules a frame out only if it reproduces the workload
  around it.
* Runtime expression compilation: `Expression.Lambda(...).Compile()` and the whole
  ExpressionExtension.Factory → ExpressionBaseActivatorFactory shape reproduce fine in isolation.
* The display backend: identical failure under PROPNIX_WINE_GRAPHICS=x11.
* `MONO_DEBUG=explicit-null-checks` (make the JIT compare instead of faulting on the null page): it looked
  like a fix on the one lucky run, and an A/B of three launches each way then measured 0/3 surviving WITH
  it and 0/3 WITHOUT. Not a fix; any candidate here needs repeated launches, because a single success
  proves nothing. (`MONO_DEBUG` IS honoured from the environment, unlike `MONO_ENV_OPTIONS`, which only
  the standalone `mono` driver parses and which this embedded host silently ignores.)

## The nursery-size mitigation, and why the package does not carry it

`MONO_GC_PARAMS = "nursery-size=64m"` made startup pass (0/4 → 4/4) by making a nursery collection
unlikely inside the callback window, but it was probabilistic, not a fix: the standalone probe still
failed with it under heavier allocation, and a larger nursery did not monotonically help
(64m/128m/256m → 75/119/123 failures per 200). With the runtime patch the probe is clean at 200/200 and
the game starts 3/3 with no GC tuning at all.

## Resolution

The "race" was the collector clearing Wine Mono's weakly-held delegate while a thread sat inside a native
call that re-enters managed code — intermittent because it needs a nursery collection to land inside
that window. The fix is in the runtime (patches/0001) so that the next managed title does not need a
workaround. On aarch64 the runtime is the ARM64EC build (patches/0002, docs/research/mono-arm64ec.md),
where the callback itself no longer crosses an emulator boundary; the strong reference is right on both
hosts.
