/* Graceful GOG Galaxy SDK stub (Galaxy64.dll / Galaxy.dll).
 *
 * Every exported symbol — both the GalaxyFactory statics and the galaxy::api:: free functions — is aliased
 * (by galaxy64.def / galaxy32.def, generated in default.nix) to one of these four C bodies:
 *
 *   ret_galaxy -> a non-null IGalaxy whose every vtable slot returns the shared dummy (so the header-inline
 *                 accessor path, GalaxyFactory::GetInstance()->GetUser()->…, is null-safe; lifecycle methods
 *                 called on it are ignored void returns);
 *   ret_dummy  -> the shared dummy interface (non-null) for every accessor -> no null-deref when a game
 *                 chains User()->SignedIn();
 *   ret_zero   -> 0 (a null "no error" pointer / false / an empty leaf value);
 *   noop_void  -> a lifecycle no-op (Init / Shutdown / ProcessData / ResetInstance).
 *
 * The dummy interface's every slot also returns 0, so every leaf query reports the benign offline/false/0/
 * empty value. No RPC or socket work is ever attempted, so the SDK's offline init can't fault rpcrt4. This
 * never touches the exact SDK version's vtable order (both vtables are over-provisioned and uniform).
 */
typedef void *(*fn_t)(void);

void *ret_dummy(void);
void *ret_zero(void);

#define R8(x)  x, x, x, x, x, x, x, x
#define R64(x) R8(x), R8(x), R8(x), R8(x), R8(x), R8(x), R8(x), R8(x)

/* 64 slots is far more than any real IGalaxy / interface vtable; over-provisioned deliberately. */
static fn_t galaxy_vtbl[64] = { R64(ret_dummy) }; /* IGalaxy: every method -> the non-null dummy */
static fn_t dummy_vtbl[64] = { R64(ret_zero) };   /* leaf interface: every method -> 0 */

/* A C++ object is a pointer to its vtable; &<obj> is the `this` the game receives. */
static void *galaxy_obj = galaxy_vtbl;
static void *dummy_obj = dummy_vtbl;

void *ret_dummy(void) { return &dummy_obj; }
void *ret_zero(void) { return 0; }
void *ret_galaxy(void) { return &galaxy_obj; }
void noop_void(void) {}
