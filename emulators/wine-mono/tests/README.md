# ARM64EC runtime harness

Sources for the checks that validated `patches/0002-arm64ec-runtime.patch`. They are not run by CI: they need
a wine prefix with the runtime installed and the FEX DLLs, i.e. a desktop aarch64 host. Build the C# with the
runtime's own compiler and the x64 DLL with the repo's llvm-mingw, then run under the built wine:

```
W=$(nix build --print-out-paths .#wine)        # Hangover wine
M='C:\windows\mono\mono-2.0\lib\mono\4.5\mcs.exe'
WINEPREFIX=$P wine "$M" -out:x64test.exe x64test.cs
$(nix build --print-out-paths .#llvmMingw)/bin/x86_64-w64-mingw32-clang -O2 -shared -o x64test.dll x64test.c
WINEPREFIX=$P wine x64test.exe
```

| file | what it checks |
| --- | --- |
| `hello.cs` | a managed hello world + fib(35) timing (numbers in docs/research/mono-arm64ec.md) |
| `nullref.cs` | a hardware fault becomes a NullReferenceException (needs emulators/fex patches/0002) |
| `suite.cs` | p/invoke into system DLLs, exceptions, generics, GC pressure, threads, delegates, divide by zero |
| `probe.cs` | what GetProcAddress hands out in an EC process (fast-forward stubs), 6/7-argument and mixed-float calls |
| `x64test.c` + `x64test.cs` | an x86_64 DLL under FEX: exit thunks (stack args, mixed int/float, every struct class, returns), entry thunks (callbacks with the same shapes, 12 args, exceptions through x64 frames, nested transitions), the Havok `(ptr,ptr,u32,Vector3S,Vector3S)` shape |
| `hfa.cs` | dumps a wrapper's entry thunk bytes (`MONO_ARM64EC_DEBUG=1` prints exit-thunk addresses and words too) for disassembly |
| `sigdump.cs` | prints every p/invoke signature of an assembly (run from the game's Bin64 so dependencies resolve) |
| `suspcount.c` | suspend count of every thread of a process (`ThreadSuspendCount`), without attaching; run inside the launcher namespace with `nsenter -U --preserve-credentials -m -t <pid>` |
| `resumeall.c` | resumes every suspended thread of a process; a diagnostic, not a fix |
| `spin.c` | an x86_64 exe under FEX: does SuspendThread + GetThreadContext complete while the target spins in x64 code? Four loop shapes — conditional back-edge with and without `pause`, `jmp`-closed, with a call — and each must suspend at once (emulators/fex patches/0003); build with `x86_64-w64-mingw32-clang -O1`, run in any x64 prefix |
| `bench.cs` | the managed micro-benchmark set (fib, nbody, spectral-norm, binary-trees, fannkuch, mandelbrot, dictionary/strings/sort, allocation churn, interface dispatch, p/invoke, exceptions); `mcs -optimize+`, then run the same exe on both runtimes — numbers in docs/research/mono-arm64ec.md |
