/* Graceful GOG Galaxy SDK stub (Galaxy64.dll / Galaxy.dll).
 *
 * Every exported symbol — both the GalaxyFactory statics and the galaxy::api:: free functions — is aliased
 * (by galaxy64.def / galaxy32.def, generated in default.nix) to one of these C bodies:
 *
 *   ret_galaxy    -> a non-null IGalaxy whose accessor slots return the shared dummy;
 *   ret_dummy     -> a scalar-safe leaf interface whose methods return 0 / false;
 *   ret_apps      -> IApps, with real empty-string returns for its two string-valued methods;
 *   ret_registrar -> IListenerRegistrar, with REAL Register() and Unregister() methods (see SIGN-IN below);
 *   ret_zero      -> 0 (a null "no error" pointer);
 *   pump_void     -> ProcessData: delivers the pending sign-in result (see SIGN-IN below);
 *   noop_void     -> a lifecycle no-op (Init / Shutdown / ResetInstance).
 *
 * No RPC or socket work is ever attempted, so the SDK's offline init can't fault rpcrt4.
 *
 * ── THE VTABLES BELOW ARE FOR 64-BIT CALLERS ONLY. One uniform vtable of zero-argument slots standing in
 * for interfaces of unknown arity is an ABI trick that works exactly once: under Microsoft x64, where
 * arguments arrive in registers and the CALLER cleans the stack, so a callee that ignores them leaves
 * nothing behind. i386 SDK interfaces are __thiscall — the CALLEE pops — so a zero-argument slot standing
 * in for an N-argument method leaves N bytes of arguments on the caller's stack and the caller's next
 * `ret` pops an ARGUMENT as its return address. MEASURED on homeworld-rm (the first i386 title to load
 * this DLL, 2026-09-03): its `IGalaxy::Init(clientID, clientSecret, 0)` call site is
 * `push 0 / push secret / push clientID / mov ecx,eax / call [edx+4] / ret`, and with `ret_dummy` in that
 * slot the game jumped to 0x8e6060 — the clientID string literal itself — and its handler reported
 * "Access Violation … at 0023:008e6060". A generic fix does not exist: the correct pop count is per-slot
 * per-interface and unknowable from here. So lib/backends/wine/defaults.nix REFUSES `galaxyStubDlls` on
 * i386 titles, whose offline guarantee is `online = false` (a kernel netns unshare) instead. Galaxy.dll
 * is still built for the 64-bit titles that bind a 32-bit copy they never load (prison-architect), and
 * the __thiscall annotations below stay correct for the paths that DO run on i386 — but do not read the
 * existence of the 32-bit build as a claim that a 32-bit game can use it.
 *
 * ── WHY THIS IS MORE THAN "RETURN BENIGN VALUES". This stub was a SILENT NO-OP on x86_64 until 2026-09-03
 * (backends/wine/defaults.nix dropped every derived row while `galaxyStub` was null there), so it had never
 * actually been exercised against the titles that declare it. Wiring it up showed it HANGING games. The two
 * defects below were found by instrumenting a copy of this stub — one logging thunk per export, one per
 * vtable slot, per-interface identity — and running Cyberpunk 2077 under `PROPNIX_WINEDEBUG=-all,+debugstr`,
 * whose bin/x64/GameServicesGOG.dll is the strictest consumer in the repo.
 *
 * ── DEFECT 1, THE BIG ONE: THE ASYNC SIGN-IN MUST BE COMPLETED, NOT IGNORED. Measured call sequence:
 *      Init -> GetError -> ListenerRegistrar()->Register x5 -> User()->slot7 (SignInGalaxy)
 *           -> Apps()->slot3 -> ProcessData x4729 … forever, plus a retry of User()->slot7.
 *    The game pumps ProcessData tens of thousands of times waiting for a result that a do-nothing stub never
 *    produces, so the engine's `GameServicesAsync` init phase never ends. Returning "not signed in" is NOT
 *    enough — nobody asked a question, they started an OPERATION. So: capture the AUTH listener at
 *    Register() and, from ProcessData(), deliver OnAuthFailure once. That is exactly what the real SDK does
 *    offline (Silksong logs `GOG authorization failed: FAILURE_REASON_GALAXY_SERVICE_NOT_AVAILABLE`).
 *    VERIFIED: with the callback delivered, the retry of User()->slot7 stops, `dxgi_vk_swap_chain_init`
 *    is reached, GameThread leaves its parked `read()` and the game renders.
 *
 *    The two magic numbers are read off the SDK's own enums and were confirmed at runtime:
 *      * ListenerType AUTH == 7 — the FIRST type this plugin registers, matching IListenerRegistrar.h.
 *      * IAuthListener vtable = [0]=deleting dtor, [1]=OnAuthSuccess, [2]=OnAuthFailure, [3]=OnAuthLost.
 *        Confirmed structurally: the registered object's vtable has EXACTLY THREE consecutive slots (1,2,3)
 *        pointing at VCRUNTIME140's `_purecall`, i.e. the three pure virtuals IAuthListener declares.
 *
 *    RE-READ THE VPTR AT CALL TIME — do not cache it at Register(). The listener is registered from inside
 *    its BASE constructor, so at Register() the object still carries the ABSTRACT base vtable (that is why
 *    slots 1-3 read as `_purecall` there). By the time ProcessData runs, the derived constructor has
 *    published the real vtable. Caching would call `_purecall` and abort.
 *
 * ── DEFECT 2: LEAF SLOTS NEED RETURN-TYPE-AWARE DEFAULTS. Returning 0 is correct for booleans,
 *    counts, IDs and failure-valued enums, but not for accessors returning `const char*`: Cyberpunk crashed
 *    0xC0000005 at
 *    GameServicesGOG.dll+0x24b0, which disassembles to
 *        call *0x18(%r8)        ; Apps() vtable slot 3
 *        mov  %rax,%r11
 *        movzbl (%rcx),%edx     ; <-- +0x24b0, rcx = the returned pointer
 *    an INLINED string compare against two literals — slot 3 returns a C string (shaped like
 *    IApps::GetCurrentGameLanguage) and the plugin dereferences it with no null check.
 *
 *    A single pointer-valued thunk cannot safely stand in for both categories: its address may happen to
 *    have a zero low byte (and therefore look like false as a `bool`), but the same address is a large
 *    non-zero uint32/uint64 result. Keep the ordinary leaf vtable zero-valued and give IApps its own typed
 *    slots: GetCurrentGameLanguage and GetCurrentGameLanguageCode return a real empty C string, while the
 *    scalar methods still return zero. The Copy variants explicitly write an empty string too. Any future
 *    non-null pointer return must likewise be added to the interface-specific vtable, not the generic one.
 *
 * ── A NOTE ON MEASURING THIS. Do not judge a run by whether one late log line appeared: binding this stub
 * ADDS STARTUP LATENCY, and `Presenter: Actual swapchain properties` is emitted at the very end of DXVK's
 * init. A 70 s window showed that line for iron-lung with no galaxy row and not with one, which reads like
 * a regression and is not — a 120 s run shows it either way (verified 2026-09-03, plus the owner reaching
 * its title screen). Compare like-for-like: same timeout, and prefer the window/screenshot or
 * `/proc/<pid>/task/<tid>/syscall` for GameThread over a single grep count.
 */
typedef void *(*fn_t)(void);

/* MSVC member functions are __thiscall on i386 (`this` in ECX, callee pops) and plain fastcall on x86_64. */
#if defined(__i386__)
#define GALAXY_THISCALL __attribute__((thiscall))
#else
#define GALAXY_THISCALL
#endif

void *ret_dummy(void);
void *ret_zero(void);
void *ret_empty_string(void);

#define R8(x)  x, x, x, x, x, x, x, x
#define R64(x) R8(x), R8(x), R8(x), R8(x), R8(x), R8(x), R8(x), R8(x)

/* 64 slots is far more than any real vtable; over-provisioned deliberately. IGalaxy accessor methods
 * return a non-null leaf object. Ordinary leaf slots are scalar-safe zeroes; pointer-valued exceptions
 * belong in a dedicated interface vtable. */
static fn_t galaxy_vtbl[64] = { R64(ret_dummy) };   /* IGalaxy */
static fn_t dummy_vtbl[64] = { R64(ret_zero) };     /* scalar/void leaf fallback */
static fn_t apps_vtbl[64] = { R64(ret_zero) };      /* IApps; string slots replaced below */
static fn_t registrar_vtbl[64] = { R64(ret_zero) }; /* IListenerRegistrar; slots 1-2 replaced below */

/* A C++ object is a pointer to its vtable; &<obj> is the `this` the game receives. */
static void *galaxy_obj = galaxy_vtbl;
static void *dummy_obj = dummy_vtbl;
static void *apps_obj = apps_vtbl;
static void *registrar_obj = registrar_vtbl;
static const char empty_string[] = "";

/* ── The pending sign-in (defect 1) ───────────────────────────────────────────────────────────────── */
#define LISTENER_TYPE_AUTH 7                            /* galaxy::api::AUTH */
#define AUTH_SLOT_ON_FAILURE 2                          /* IAuthListener::OnAuthFailure */
#define FAILURE_REASON_GALAXY_SERVICE_NOT_AVAILABLE 1   /* IAuthListener::FailureReason */

static void *auth_listener;
static int pump_count;

/* IListenerRegistrar::Register(ListenerType, IGalaxyListener*) — vtable slot 1, past the single MSVC
 * deleting-destructor slot. Only the AUTH listener is kept; every other type is accepted and ignored. */
static void GALAXY_THISCALL registrar_register(void *self, unsigned type, void *listener)
{
  (void)self;
  if (type == LISTENER_TYPE_AUTH && listener)
  {
    auth_listener = listener;
    pump_count = 0;
  }
}

/* IListenerRegistrar::Unregister(ListenerType, IGalaxyListener*) — vtable slot 2. Self-registering
 * listener base classes call this from their destructor. Forget a matching pending listener immediately,
 * so a later ProcessData() can never dereference the destroyed object. */
static void GALAXY_THISCALL registrar_unregister(void *self, unsigned type, void *listener)
{
  (void)self;
  if (type == LISTENER_TYPE_AUTH && auth_listener == listener)
  {
    auth_listener = 0;
    pump_count = 0;
  }
}

/* ProcessData() — the SDK's callback pump. Deliver the one pending result, once. */
void pump_void(void)
{
  void *listener;
  void **vtbl;
  if (!auth_listener)
    return;
  /* Let the derived constructor publish its vtable before dispatching. Registration happens from the BASE
   * constructor, so the very first pump could in principle still see the abstract vtable. */
  if (++pump_count < 2)
    return;
  /* Remove the pending reference before entering game code. If the callback destroys its listener (and
   * therefore calls Unregister), neither that teardown nor a nested ProcessData() can observe stale state. */
  listener = auth_listener;
  auth_listener = 0;
  pump_count = 0;
  vtbl = *(void ***)listener; /* re-read after construction — never cache this at Register() */
  ((void(GALAXY_THISCALL *)(void *, unsigned))vtbl[AUTH_SLOT_ON_FAILURE])(
      listener, FAILURE_REASON_GALAXY_SERVICE_NOT_AVAILABLE);
}

/* IApps slots in the documented MSVC vtable order (one deleting destructor slot first):
 *   1 IsDlcInstalled(bool), 2 IsDlcOwned(void), 3 language(char*), 4 language copy(void),
 *   5 language code(char*), 6 language-code copy(void). */
static void GALAXY_THISCALL apps_copy_empty(
    void *self, char *buffer, unsigned buffer_length, unsigned long long product_id)
{
  (void)self;
  (void)product_id;
  if (buffer && buffer_length)
    buffer[0] = '\0';
}

__attribute__((constructor)) static void install_vtables(void)
{
  registrar_vtbl[1] = (fn_t)(void *)registrar_register;
  registrar_vtbl[2] = (fn_t)(void *)registrar_unregister;
  apps_vtbl[3] = ret_empty_string;
  apps_vtbl[4] = (fn_t)(void *)apps_copy_empty;
  apps_vtbl[5] = ret_empty_string;
  apps_vtbl[6] = (fn_t)(void *)apps_copy_empty;
}

void *ret_dummy(void) { return &dummy_obj; }
void *ret_zero(void) { return 0; }
void *ret_empty_string(void) { return (void *)empty_string; }
void *ret_galaxy(void) { return &galaxy_obj; }
void *ret_apps(void) { return &apps_obj; }
void *ret_registrar(void) { return &registrar_obj; }
void noop_void(void) {}
