/* suspcount.exe <pid-hex> — print every thread of a process with its suspend count (NtQueryInformationThread
 * ThreadSuspendCount) and state, without attaching or touching the process. */
#include <windows.h>
#include <winternl.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <stdlib.h>
typedef NTSTATUS (NTAPI *pNtQIT)(HANDLE, THREADINFOCLASS, PVOID, ULONG, PULONG);
int main(int argc, char **argv) {
    DWORD pid = (DWORD)strtoul(argv[1], NULL, 16);
    pNtQIT qit = (pNtQIT)GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "NtQueryInformationThread");
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
    THREADENTRY32 te = { sizeof(te) };
    int n = 0, suspended = 0;
    for (BOOL ok = Thread32First(snap, &te); ok; ok = Thread32Next(snap, &te)) {
        if (te.th32OwnerProcessID != pid) continue;
        HANDLE h = OpenThread(THREAD_QUERY_INFORMATION, FALSE, te.th32ThreadID);
        ULONG count = 0xffff; NTSTATUS st = -1;
        if (h) { st = qit(h, (THREADINFOCLASS)35 /* ThreadSuspendCount */, &count, sizeof(count), NULL); CloseHandle(h); }
        n++; if (st == 0 && count) suspended++;
        printf("tid %04lx suspend_count=%lu status=%08lx\n", (unsigned long)te.th32ThreadID, (unsigned long)count, (unsigned long)st);
    }
    printf("threads=%d suspended=%d\n", n, suspended);
    return 0;
}
