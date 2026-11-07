/* gbe-interface-oracle — ask a gbe_fork libsteam_api.so, BY RUNNING IT, which Steamworks interface
 * revisions it serves.
 *
 *   gbe-interface-oracle [--shim <libsteam_api.so>] <revision>...
 *
 * The shim defaults to the one compiled in (-DSHIM_PATH, the host's own gbe_fork build); --shim asks a
 * different build, say a candidate release, the same questions.
 *
 * One line per revision on stdout, "<revision>\t<verdict>", verdict one of
 *   served   the shim returned an interface for it (the game gets a vtable),
 *   null     the shim returned NULL on every pipe it could be asked on (the game dereferences NULL),
 *   exit73   the shim called report_missing_impl_and_exit — std::exit(0x4155149), low byte 73 — the
 *            silent death this oracle exists to predict,
 *   error:N  the probe child died some other way (N = raw wait status; init failed, crashed, …).
 * Exit status: 0 when every revision is served, 1 otherwise, 2 on usage/setup errors.
 *
 * WHY EXECUTE RATHER THAN READ THE SOURCE. The shim's dispatcher (dll/steam_client_interface_getter.cpp,
 * dll/dll.cpp create_client_interface) routes by prefix at the top, then by exact ladders per family,
 * with report_missing_impl_and_exit in some families, a NULL fallthrough in others, and the current
 * revision spelled as an sdk macro rather than a literal. No grep over that reproduces its answer: a
 * literal can appear in dll/ where nothing dispatches on it (dll/client_known_interfaces.cpp is a dump
 * of the real Steam client's table), and a revision can be served without its literal appearing at all.
 * Asking the built artifact is the only answer that cannot drift from the artifact.
 *
 * HOW. Each revision is probed in a forked child: dlopen the shim, SteamAPI_Init (the emulator's offline
 * "login" — the generic getter refuses a user pipe without a user), then
 * SteamInternal_FindOrCreateUserInterface; on NULL, SteamInternal_FindOrCreateGameServerInterface after
 * a server init (the GameServer* families live on the server pipe); on NULL again,
 * SteamInternal_CreateInterface (the SteamClient family lives there). A fork per probe because the
 * fatal path is a process exit. The child gets a private HOME/XDG_DATA_HOME with gbe_fork's networking
 * switched off in its global settings, so nothing touches the real user's state or the network.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

typedef unsigned char (*init_fn)(void);                    /* steam_bool SteamAPI_Init(void) */
typedef int (*user_fn)(void);                              /* HSteamUser SteamAPI_GetHSteamUser(void) */
typedef void *(*find_fn)(int, const char *);               /* SteamInternal_FindOrCreate{User,GameServer}Interface */
typedef void *(*create_fn)(const char *);                  /* SteamInternal_CreateInterface */
typedef unsigned char (*gs_init_fn)(unsigned int, unsigned short, unsigned short, unsigned short, int, const char *);

static int mkpath(const char *p) {
  char buf[4096];
  snprintf(buf, sizeof buf, "%s", p);
  for (char *c = buf + 1; *c; c++) {
    if (*c == '/') { *c = 0; mkdir(buf, 0700); *c = '/'; }
  }
  return mkdir(buf, 0700) == 0 || errno == EEXIST ? 0 : -1;
}

/* The child's whole life: returns only through _exit. */
static void probe(const char *shim, const char *scratch, const char *rev) {
  setenv("HOME", scratch, 1);
  setenv("XDG_DATA_HOME", scratch, 1);
  setenv("SteamAppId", "480", 1); /* any app id; the dispatcher does not care which */
  /* gbe_fork's GLOBAL settings: <XDG_DATA_HOME>/GSE Saves/settings/configs.main.ini */
  char dir[4352], ini[4352];
  snprintf(dir, sizeof dir, "%s/GSE Saves/settings", scratch);
  if (mkpath(dir) != 0) _exit(3);
  snprintf(ini, sizeof ini, "%s/configs.main.ini", dir);
  FILE *f = fopen(ini, "w");
  if (!f) _exit(3);
  fputs("[main::connectivity]\ndisable_networking=1\ndisable_lan_only=1\noffline=1\n", f);
  fclose(f);

  void *h = dlopen(shim, RTLD_NOW | RTLD_LOCAL);
  if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); _exit(4); }
  init_fn init = (init_fn)dlsym(h, "SteamAPI_Init");
  user_fn user = (user_fn)dlsym(h, "SteamAPI_GetHSteamUser");
  find_fn find_user = (find_fn)dlsym(h, "SteamInternal_FindOrCreateUserInterface");
  find_fn find_server = (find_fn)dlsym(h, "SteamInternal_FindOrCreateGameServerInterface");
  create_fn create = (create_fn)dlsym(h, "SteamInternal_CreateInterface");
  gs_init_fn gs_init = (gs_init_fn)dlsym(h, "SteamInternal_GameServer_Init");
  if (!init || !user || !find_user || !find_server || !create) {
    fprintf(stderr, "the shim lacks a required export: %s\n", dlerror());
    _exit(4);
  }
  if (!init()) { fprintf(stderr, "SteamAPI_Init returned false\n"); _exit(5); }
  int u = user();
  void *p = NULL;
  if (strncmp(rev, "SteamClient", 11) == 0) {
    /* The SteamClient family is requested through CreateInterface (dll.cpp create_client_interface),
     * never through the generic getter — which would exit on it, as it does on any family it lacks. */
    p = create(rev);
  } else {
    p = find_user(u, rev);
    if (!p && gs_init) {
      /* eServerModeNoAuthentication = 1; loopback, port 0 — networking is disabled above anyway. */
      if (gs_init(0x7f000001u, 0, 0, 0, 1, "1.0")) p = find_server(u, rev);
    }
  }
  _exit(p ? 0 : 2);
}

int main(int argc, char **argv) {
#ifdef SHIM_PATH
  const char *shim = SHIM_PATH;
#else
  const char *shim = NULL;
#endif
  int first = 1;
  if (argc > 2 && strcmp(argv[1], "--shim") == 0) { shim = argv[2]; first = 3; }
  if (!shim || argc <= first) {
    fprintf(stderr, "usage: gbe-interface-oracle [--shim <libsteam_api.so>] <revision>...\n");
    return 2;
  }
  if (access(shim, R_OK) != 0) { fprintf(stderr, "%s: %s\n", shim, strerror(errno)); return 2; }
  char tmpl[] = "/tmp/gbe-interface-oracle.XXXXXX";
  const char *base = getenv("TMPDIR");
  char scratch[4096];
  (void)tmpl;
  if (base && *base) snprintf(scratch, sizeof scratch, "%s/gbe-interface-oracle.XXXXXX", base);
  else snprintf(scratch, sizeof scratch, "%s", tmpl);
  if (!mkdtemp(scratch)) { perror("mkdtemp"); return 2; }
  int all_served = 1;
  for (int i = first; i < argc; i++) {
    const char *rev = argv[i];
    fflush(stdout);
    pid_t pid = fork();
    if (pid < 0) { perror("fork"); return 2; }
    if (pid == 0) {
      /* the shim is chatty on stderr only with PRINT_DEBUG builds; silence anything else it says */
      int devnull = open("/dev/null", 1);
      if (devnull >= 0) { dup2(devnull, 1); dup2(devnull, 2); }
      probe(shim, scratch, rev);
    }
    int status = 0;
    if (waitpid(pid, &status, 0) < 0) { perror("waitpid"); return 2; }
    const char *verdict;
    char other[32];
    if (WIFEXITED(status) && WEXITSTATUS(status) == 0) verdict = "served";
    else if (WIFEXITED(status) && WEXITSTATUS(status) == 2) verdict = "null";
    else if (WIFEXITED(status) && WEXITSTATUS(status) == 73) verdict = "exit73";
    else { snprintf(other, sizeof other, "error:%d", status); verdict = other; }
    if (strcmp(verdict, "served") != 0) all_served = 0;
    printf("%s\t%s\n", rev, verdict);
  }
  /* best-effort cleanup of the scratch tree */
  char cmd[4200];
  snprintf(cmd, sizeof cmd, "rm -rf '%s'", scratch);
  if (strchr(scratch, '\'') == NULL) (void)system(cmd);
  return all_served ? 0 : 1;
}
