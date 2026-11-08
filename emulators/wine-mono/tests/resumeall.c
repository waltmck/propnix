/* resumeall.exe <pid-hex> — ResumeThread once on every thread of the process whose suspend count is >= 1. */
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
    int resumed = 0;
    for (BOOL ok = Thread32First(snap, &te); ok; ok = Thread32Next(snap, &te)) {
        if (te.th32OwnerProcessID != pid) continue;
        HANDLE h = OpenThread(THREAD_QUERY_INFORMATION | THREAD_SUSPEND_RESUME, FALSE, te.th32ThreadID);
        if (!h) continue;
        ULONG count = 0;
        if (qit(h, (THREADINFOCLASS)35, &count, sizeof(count), NULL) == 0 && count >= 1) {
            DWORD prev = ResumeThread(h);
            printf("tid %04lx: suspend_count=%lu -> ResumeThread returned %ld\n", (unsigned long)te.th32ThreadID, (unsigned long)count, (long)prev);
            resumed++;
        }
        CloseHandle(h);
    }
    printf("resumed %d threads\n", resumed);
    return 0;
}
