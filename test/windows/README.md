# Windows Tests

Manual test programs for Windows-specific functionality.

## test_dll_init.c

Regression test for the DLL CRT initialization fix. Loads
ghostty-internal.dll at runtime and calls ghostty_info + ghostty_init to
verify the MSVC C runtime is properly initialized.

### Build

First build ghostty-internal.dll, then compile the test:

```
zig build -Dapp-runtime=none -Demit-exe=false
zig cc test_dll_init.c -o test_dll_init.exe -target native-native-msvc
```

### Run

From this directory:

```
copy ..\..\zig-out\lib\ghostty-internal.dll . && test_dll_init.exe
```

Expected output (after the CRT fix):

```
ghostty_info: <version string>
```

The ghostty_info call verifies the DLL loads and the CRT is initialized.
Before the fix, loading the DLL would crash with "access violation writing
0x0000000000000024".

## powershell-integration.ps1

Loads the PowerShell shell integration without a terminal and checks the
escape sequences its prompt writes (OSC 7, 2, and 133, and the cursor
shape), including a failed command's exit code. CI runs it with both
Windows PowerShell 5.1 and PowerShell 7.

```
powershell -NoProfile -ExecutionPolicy Bypass -File powershell-integration.ps1
pwsh -NoProfile -File powershell-integration.ps1
```
