// Hands a console session to a running Ghostty through its terminal
// handoff class (ITerminalHandoff3), as Windows' console host does when
// Ghostty is the default terminal application, without changing that
// setting. It creates a pseudoconsole running a command, hands Ghostty its
// handles (from the pseudoconsole's struct, as microsoft/terminal's
// winconpty lays it out), and relays the pipes Ghostty returns to the
// pseudoconsole's. It uses Windows Terminal's proxy for the interface.
//
//     zig cc handoff_client.c -o handoff_client.exe -lole32 -loleaut32
//     handoff_client.exe "cmd.exe /k echo handoff-ok" 15 [title] [show]
//
// It exits after the given number of seconds, or when the command exits.
// The title and show command (SW_*) are the startup info it passes, as
// the console host passes the console program's.

#define COBJMACROS
#include <windows.h>
#include <objbase.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct {
    BSTR pszTitle;
    BSTR pszIconPath;
    LONG iconIndex;
    DWORD dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars;
    DWORD dwFillAttribute, dwFlags;
    WORD wShowWindow;
} TERMINAL_STARTUP_INFO;

typedef struct ITerminalHandoff3 ITerminalHandoff3;
typedef struct {
    HRESULT(STDMETHODCALLTYPE *QueryInterface)(ITerminalHandoff3 *, REFIID, void **);
    ULONG(STDMETHODCALLTYPE *AddRef)(ITerminalHandoff3 *);
    ULONG(STDMETHODCALLTYPE *Release)(ITerminalHandoff3 *);
    HRESULT(STDMETHODCALLTYPE *EstablishPtyHandoff)(ITerminalHandoff3 *, HANDLE *in, HANDLE *out,
        HANDLE signal, HANDLE reference, HANDLE server, HANDLE client, const TERMINAL_STARTUP_INFO *info);
} ITerminalHandoff3Vtbl;
struct ITerminalHandoff3 { const ITerminalHandoff3Vtbl *lpVtbl; };

static const CLSID CLSID_Ghostty = {0x7ec9f94f, 0x09dd, 0x4c7f, {0xa7, 0x9b, 0x57, 0x53, 0x2e, 0xba, 0xfc, 0xdd}};
static const IID IID_ITerminalHandoff3 = {0x6f23da90, 0x15c5, 0x4203, {0x9d, 0xb0, 0x64, 0xe7, 0x3f, 0x1b, 0x1b, 0x00}};

// microsoft/terminal src/winconpty/winconpty.h
typedef struct {
    HANDLE hSignal;
    HANDLE hPtyReference;
    HANDLE hConPtyProcess;
} PseudoConsole;

typedef struct { HANDLE from, to; } Relay;

static DWORD WINAPI relay(void *arg) {
    Relay *r = arg;
    char buf[4096];
    DWORD n, written;
    while (ReadFile(r->from, buf, sizeof buf, &n, NULL) && n > 0) {
        if (!WriteFile(r->to, buf, n, &written, NULL)) break;
    }
    return 0;
}

static int fail(const char *what, HRESULT hr) {
    fprintf(stderr, "handoff_client: %s failed (0x%08lx)\n", what, (unsigned long)hr);
    return 1;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: handoff_client <command> <seconds> [title] [show]\n");
        return 2;
    }
    DWORD seconds = (DWORD)atoi(argv[2]);

    HRESULT hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    if (FAILED(hr)) return fail("CoInitializeEx", hr);

    // The pseudoconsole and its pipes, which we relay to Ghostty's.
    HANDLE con_in_read, con_in_write, con_out_read, con_out_write;
    if (!CreatePipe(&con_in_read, &con_in_write, NULL, 0)) return fail("CreatePipe", GetLastError());
    if (!CreatePipe(&con_out_read, &con_out_write, NULL, 0)) return fail("CreatePipe", GetLastError());
    HPCON hpc;
    COORD size = {80, 25};
    hr = CreatePseudoConsole(size, con_in_read, con_out_write, 0, &hpc);
    if (FAILED(hr)) return fail("CreatePseudoConsole", hr);
    CloseHandle(con_in_read);
    CloseHandle(con_out_write);

    STARTUPINFOEXW si = {0};
    si.StartupInfo.cb = sizeof si;
    // Without this, the command would inherit our standard handles (which
    // a script redirects) instead of using the pseudoconsole.
    si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    SIZE_T attr_size = 0;
    InitializeProcThreadAttributeList(NULL, 1, 0, &attr_size);
    si.lpAttributeList = HeapAlloc(GetProcessHeap(), 0, attr_size);
    if (!InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0, &attr_size)) return fail("InitializeProcThreadAttributeList", GetLastError());
    if (!UpdateProcThreadAttribute(si.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, hpc, sizeof hpc, NULL, NULL))
        return fail("UpdateProcThreadAttribute", GetLastError());

    wchar_t command[1024];
    MultiByteToWideChar(CP_UTF8, 0, argv[1], -1, command, 1024);
    PROCESS_INFORMATION pi;
    if (!CreateProcessW(NULL, command, NULL, NULL, FALSE, EXTENDED_STARTUPINFO_PRESENT, NULL, NULL, &si.StartupInfo, &pi))
        return fail("CreateProcessW", GetLastError());

    ITerminalHandoff3 *handoff = NULL;
    hr = CoCreateInstance(&CLSID_Ghostty, NULL, CLSCTX_LOCAL_SERVER, &IID_ITerminalHandoff3, (void **)&handoff);
    if (FAILED(hr)) return fail("CoCreateInstance", hr);

    const PseudoConsole *pty = (const PseudoConsole *)hpc;
    TERMINAL_STARTUP_INFO info = {0};
    wchar_t title[256] = L"handoff_client";
    if (argc > 3) MultiByteToWideChar(CP_UTF8, 0, argv[3], -1, title, 256);
    info.pszTitle = SysAllocString(title);
    if (argc > 4) {
        info.dwFlags = STARTF_USESHOWWINDOW;
        info.wShowWindow = (WORD)atoi(argv[4]);
    }
    HANDLE ghostty_in = NULL, ghostty_out = NULL;
    hr = handoff->lpVtbl->EstablishPtyHandoff(handoff, &ghostty_in, &ghostty_out, pty->hSignal,
        pty->hPtyReference, pty->hConPtyProcess, pi.hProcess, &info);
    if (FAILED(hr)) return fail("EstablishPtyHandoff", hr);
    printf("handed off pid=%lu\n", (unsigned long)pi.dwProcessId);
    fflush(stdout);

    // Ghostty's input goes to the pseudoconsole, and its output to Ghostty.
    Relay to_console = {ghostty_in, con_in_write};
    Relay to_ghostty = {con_out_read, ghostty_out};
    CreateThread(NULL, 0, relay, &to_console, 0, NULL);
    CreateThread(NULL, 0, relay, &to_ghostty, 0, NULL);

    DWORD wait = WaitForSingleObject(pi.hProcess, seconds * 1000);
    printf(wait == WAIT_OBJECT_0 ? "the command exited\n" : "time is up\n");
    fflush(stdout);
    if (wait != WAIT_OBJECT_0) TerminateProcess(pi.hProcess, 0);
    ClosePseudoConsole(hpc);
    return 0;
}
