/* hlslc — drive wine's builtin d3dcompiler_47 (vkd3d-shader) over real game shaders, outside the game.
 *
 * Build (ARM64EC, from the wine devshell's llvm-mingw): arm64ec-w64-mingw32-clang -O1 -o hlslc.exe hlslc.c
 * Run in a prefix that has the FEX DLLs in system32 (any propnix prefix does), with
 * WINEDLLOVERRIDES=d3dcompiler_47=b so the builtin answers:
 *   hlslc <file> <profile> <entry> <include-dir> [NAME=VALUE ...]      one shader, messages + optional disassembly
 *   hlslc @<list>                                                      one job per line, TAB-separated:
 *                                                                      file profile entry include-dir [NAME=VALUE ...]
 * Includes: <name> resolves under <include-dir>, "name" under the includer's directory first (as
 * the native compiler does); the pseudo-macro __HLSLC_SOURCE=<path under include-dir> names the
 * top-level file for that purpose. Macro values in a list carry \n \t \\ escapes.
 * HLSLC_PRE=<path> saves the preprocessed text; HLSLC_DISASM=1 prints D3DDisassemble() output.
 * A dev-built wined3d.dll (the compiler lives there) only loads from the prefix if its "Wine builtin DLL"
 * signature is cleared and wined3d=n is set: the loader otherwise prefers the install tree's builtin
 * (docs/research/wine-builtin-gaps.md). */
#define COBJMACROS
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <d3dcompiler.h>

typedef HRESULT (WINAPI *pfn_compile)(const void *, SIZE_T, const char *, const D3D_SHADER_MACRO *, ID3DInclude *,
        const char *, const char *, UINT, UINT, ID3DBlob **, ID3DBlob **);
typedef HRESULT (WINAPI *pfn_preprocess)(const void *, SIZE_T, const char *, const D3D_SHADER_MACRO *, ID3DInclude *,
        ID3DBlob **, ID3DBlob **);
typedef HRESULT (WINAPI *pfn_disassemble)(const void *, SIZE_T, UINT, const char *, ID3DBlob **);
static pfn_compile compile;
static pfn_preprocess preprocess;
static pfn_disassemble disassemble;
static const char *incdir;      /* the shader root: <> includes resolve here first */
static char srcdir[1024];       /* directory of the top-level source: "" includes resolve here first */

/* Each opened buffer remembers its directory, so that nested "" includes resolve relative to the includer. */
static struct { const void *data; char dir[1024]; } opened[128];
static int opened_count;

static void dirname_of(const char *path, char *out, size_t n)
{
    const char *slash = strrchr(path, '/');
    size_t len = slash ? (size_t)(slash - path) : 0;
    if (len >= n) len = n - 1;
    memcpy(out, path, len); out[len] = 0;
}

static FILE *try_open(const char *dir, const char *name, char *path, size_t n)
{
    if (dir && *dir) snprintf(path, n, "%s/%s", dir, name); else snprintf(path, n, "%s", name);
    return fopen(path, "rb");
}

static HRESULT STDMETHODCALLTYPE inc_Open(ID3DInclude *iface, D3D_INCLUDE_TYPE type, const char *name,
        const void *parent, const void **data, UINT *bytes)
{
    char path[1024]; const char *pdir = srcdir; FILE *fp = NULL; long n; void *buf; int i;
    for (i = 0; i < opened_count; ++i) if (opened[i].data == parent) { pdir = opened[i].dir; break; }
    if (type == D3D_INCLUDE_LOCAL) { fp = try_open(pdir, name, path, sizeof(path)); if (!fp) fp = try_open(incdir, name, path, sizeof(path)); }
    else { fp = try_open(incdir, name, path, sizeof(path)); if (!fp) fp = try_open(pdir, name, path, sizeof(path)); }
    if (!fp) { fprintf(stderr, "include not found: %s (from %s)\n", name, pdir); return E_FAIL; }
    fseek(fp, 0, SEEK_END); n = ftell(fp); fseek(fp, 0, SEEK_SET);
    buf = malloc(n + 1); fread(buf, 1, n, fp); fclose(fp);
    *data = buf; *bytes = (UINT)n;
    if (opened_count < 128) { opened[opened_count].data = buf; dirname_of(path, opened[opened_count].dir, sizeof(opened[0].dir)); ++opened_count; }
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE inc_Close(ID3DInclude *iface, const void *data)
{
    int i;
    for (i = 0; i < opened_count; ++i) if (opened[i].data == data) { opened[i] = opened[--opened_count]; break; }
    free((void *)data); return S_OK;
}
static ID3DIncludeVtbl inc_vtbl = { inc_Open, inc_Close };
static ID3DInclude inc = { &inc_vtbl };

static void print_msgs(const char *indent, ID3DBlob *msgs)
{
    const char *p = ID3D10Blob_GetBufferPointer(msgs); size_t n = ID3D10Blob_GetBufferSize(msgs);
    while (n && p[n - 1] == 0) --n;
    while (n) {
        const char *e = memchr(p, '\n', n); size_t l = e ? (size_t)(e - p) : n;
        printf("%s%.*s\n", indent, (int)l, p);
        if (!e) break;
        n -= l + 1; p = e + 1;
    }
}

/* returns 0 on success, 1 on failure; quiet = list mode (one summary line + indented messages) */
static int compile_one(const char *file, const char *profile, const char *entry, const char *dir,
        D3D_SHADER_MACRO *macros, int m, int quiet)
{
    ID3DBlob *code = NULL, *msgs = NULL, *pre = NULL;
    FILE *fp; long n; char *src; HRESULT hr, hrp;

    char srcname[1024]; int k;
    incdir = dir; opened_count = 0;
    snprintf(srcname, sizeof(srcname), "%s", file); dirname_of(file, srcdir, sizeof(srcdir));
    for (k = 0; k < m; ++k) {
        if (!strcmp(macros[k].Name, "__HLSLC_SOURCE")) {
            snprintf(srcname, sizeof(srcname), "%s/%s", dir, macros[k].Definition); dirname_of(srcname, srcdir, sizeof(srcdir));
            memmove(macros + k, macros + k + 1, (m - k) * sizeof(*macros)); --m; --k;
        }
    }
    if (!(fp = fopen(file, "rb"))) { printf("%s\tcannot open\n", quiet ? "FAIL" : "ERROR"); if (quiet) printf("\t%s\n", file); return 1; }
    fseek(fp, 0, SEEK_END); n = ftell(fp); fseek(fp, 0, SEEK_SET);
    src = malloc(n + 1); fread(src, 1, n, fp); fclose(fp); src[n] = 0;

    hrp = preprocess(src, n, srcname, m ? macros : NULL, &inc, &pre, &msgs);
    if (!quiet) {
        printf("D3DPreprocess: 0x%08lx%s\n", (unsigned long)hrp, pre ? "" : " (no output)");
        if (msgs) { printf("--- preprocess messages ---\n"); print_msgs("", msgs); }
        if (pre) {
            const char *dump = getenv("HLSLC_PRE");
            if (dump) { FILE *o = fopen(dump, "wb"); if (o) { fwrite(ID3D10Blob_GetBufferPointer(pre), 1, ID3D10Blob_GetBufferSize(pre), o); fclose(o); printf("preprocessed -> %s\n", dump); } }
        }
    }
    if (msgs) { ID3D10Blob_Release(msgs); msgs = NULL; }
    if (pre) ID3D10Blob_Release(pre);

    hr = compile(src, n, srcname, m ? macros : NULL, &inc, entry, profile, 0, 0, &code, &msgs);
    if (quiet) {
        printf("%s\t%s\t%s\t%s\t0x%08lx\t%lu\n", FAILED(hr) ? "FAIL" : "OK", file, profile, entry, (unsigned long)hr,
                code ? (unsigned long)ID3D10Blob_GetBufferSize(code) : 0UL);
        if (FAILED(hr) && msgs) print_msgs("\t", msgs);
        if (FAILED(hrp)) printf("\tD3DPreprocess: 0x%08lx\n", (unsigned long)hrp);
    } else {
        printf("D3DCompile(%s, %s): 0x%08lx, %lu bytes\n", profile, entry, (unsigned long)hr, code ? (unsigned long)ID3D10Blob_GetBufferSize(code) : 0UL);
        if (msgs) { printf("--- compile messages ---\n"); print_msgs("", msgs); }
        if (code && getenv("HLSLC_DISASM") && disassemble) {
            ID3DBlob *asmb = NULL;
            HRESULT hd = disassemble(ID3D10Blob_GetBufferPointer(code), ID3D10Blob_GetBufferSize(code), 0, NULL, &asmb);
            printf("--- disassembly (0x%08lx) ---\n", (unsigned long)hd);
            if (asmb) { print_msgs("", asmb); ID3D10Blob_Release(asmb); }
        }
    }
    if (msgs) ID3D10Blob_Release(msgs);
    if (code) ID3D10Blob_Release(code);
    free(src);
    fflush(stdout);
    return FAILED(hr) ? 1 : 0;
}

static void unescape(char *s)
{
    char *d = s;
    for (; *s; ++s) {
        if (*s == '\\' && s[1]) {
            ++s;
            *d++ = *s == 'n' ? '\n' : *s == 'r' ? '\r' : *s == 't' ? '\t' : *s;
        } else *d++ = *s;
    }
    *d = 0;
}

static int parse_macros(char **argv, int argc, D3D_SHADER_MACRO *macros)
{
    int i, m = 0;
    for (i = 0; i < argc && m < 63; ++i) {
        char *eq = strchr(argv[i], '=');
        if (eq) { *eq = 0; unescape(eq + 1); macros[m].Name = argv[i]; macros[m].Definition = eq + 1; }
        else { macros[m].Name = argv[i]; macros[m].Definition = "1"; }
        ++m;
    }
    macros[m].Name = NULL; macros[m].Definition = NULL;
    return m;
}

int main(int argc, char **argv)
{
    D3D_SHADER_MACRO macros[64];
    HMODULE h;

    if (argc < 2) { fprintf(stderr, "usage: hlslc <file> <profile> <entry> <include-dir> [NAME=VALUE ...] | hlslc @<list>\n"); return 2; }
    if (!(h = LoadLibraryA("d3dcompiler_47.dll"))) { fprintf(stderr, "no d3dcompiler_47\n"); return 2; }
    compile = (pfn_compile)GetProcAddress(h, "D3DCompile");
    preprocess = (pfn_preprocess)GetProcAddress(h, "D3DPreprocess");
    disassemble = (pfn_disassemble)GetProcAddress(h, "D3DDisassemble");

    if (argv[1][0] == '@') {
        FILE *fp = fopen(argv[1] + 1, "r"); char line[8192]; int fails = 0, total = 0;
        if (!fp) { fprintf(stderr, "cannot open list %s\n", argv[1] + 1); return 2; }
        while (fgets(line, sizeof(line), fp)) {
            char *fields[70]; int nf = 0; char *p = line, *t;
            line[strcspn(line, "\r\n")] = 0;
            if (!*p || *p == '#') continue;
            while (nf < 70 && p) { t = p; if ((p = strchr(p, '\t'))) *p++ = 0; fields[nf++] = t; }
            if (nf < 4) { printf("FAIL\t%s\tbad line\n", line); ++fails; ++total; continue; }
            fails += compile_one(fields[0], fields[1], fields[2], fields[3], macros, parse_macros(fields + 4, nf - 4, macros), 1);
            ++total;
        }
        fclose(fp);
        printf("SUMMARY\t%d failed of %d\n", fails, total);
        return fails ? 1 : 0;
    }
    if (argc < 5) { fprintf(stderr, "usage: hlslc <file> <profile> <entry> <include-dir> [NAME=VALUE ...]\n"); return 2; }
    return compile_one(argv[1], argv[2], argv[3], argv[4], macros, parse_macros(argv + 5, argc - 5, macros), 0);
}
