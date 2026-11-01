# Checks, for CI, that dropping a file on a terminal pastes its path. It
# starts a real OLE drag (as Explorer would) from a small window of its
# own, moves the real mouse onto Ghostty and releases the button there.
# That moves the mouse and holds its button, so it only runs in CI.
#
#     ./drag-drop.ps1 -Exe zig-out/bin/ghostty.exe
#
# Run it with Windows PowerShell, whose thread is STA, as OLE drag and
# drop needs.

param(
    [Parameter(Mandatory)] [string]$Exe,
    [int]$TimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'
if ($env:CI -ne 'true') { throw "this moves the mouse and holds its button, so it only runs in CI" }
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') { throw "drag and drop needs an STA thread" }

Add-Type -AssemblyName System.Windows.Forms, UIAutomationClient, UIAutomationTypes
Add-Type -Namespace GhosttyDrop -Name Win32 -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int l, t, r, b; }
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, System.IntPtr extra);
// Press the left button at (x, y), then, on another thread, move to
// (tx, ty) and release it, while the caller's thread runs DoDragDrop.
public static void DragTo(int x, int y, int tx, int ty) {
  SetCursorPos(x, y);
  mouse_event(0x0002, 0, 0, 0, System.IntPtr.Zero);
  new System.Threading.Thread(() => {
    System.Threading.Thread.Sleep(300);
    for (int i = 1; i <= 20; i++) {
      SetCursorPos(x + (tx - x) * i / 20, y + (ty - y) * i / 20);
      System.Threading.Thread.Sleep(50);
    }
    System.Threading.Thread.Sleep(300);
    mouse_event(0x0004, 0, 0, 0, System.IntPtr.Zero);
  }).Start();
}
'@
[void][GhosttyDrop.Win32]::SetProcessDPIAware()

$file = Join-Path ([IO.Path]::GetTempPath()) 'drop test.txt'
Set-Content $file 'dropped'

$process = Start-Process -FilePath $Exe -PassThru -ArgumentList '--command=cmd.exe', '--window-save-state=never'

function SurfaceText {
    $condition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id)
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    foreach ($window in $root.FindAll([System.Windows.Automation.TreeScope]::Children, $condition)) {
        foreach ($surface in $window.FindAll([System.Windows.Automation.TreeScope]::Descendants,
                (New-Object System.Windows.Automation.PropertyCondition(
                    [System.Windows.Automation.AutomationElement]::ClassNameProperty, 'GhosttySurface')))) {
            return @{
                Handle = [IntPtr]$surface.Current.NativeWindowHandle
                Text = $surface.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
            }
        }
    }
}

function WaitFor([scriptblock]$condition, [string]$what) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ($process.HasExited) { throw "Ghostty exited while waiting for $what" }
        $result = & $condition
        if ($result) { return $result }
        Start-Sleep -Milliseconds 250
    }
    throw "timed out waiting for $what"
}

try {
    $surface = WaitFor { $s = SurfaceText; if ($s -and $s.Text.Contains('>')) { $s } } 'the prompt'
    $rect = New-Object GhosttyDrop.Win32+RECT
    [void][GhosttyDrop.Win32]::GetWindowRect($surface.Handle, [ref]$rect)
    $target = @{ X = [int](($rect.l + $rect.r) / 2); Y = [int](($rect.t + $rect.b) / 2) }

    # The drag source: a small window away from Ghostty's center.
    $form = New-Object System.Windows.Forms.Form
    $form.StartPosition = 'Manual'
    $form.Location = New-Object System.Drawing.Point(0, 0)
    $form.Size = New-Object System.Drawing.Size(200, 200)
    $form.TopMost = $true
    $form.Add_Shown({
        $form.Activate()
        [GhosttyDrop.Win32]::DragTo($form.Left + 100, $form.Top + 100, $target.X, $target.Y)

        $data = New-Object System.Windows.Forms.DataObject
        $files = New-Object System.Collections.Specialized.StringCollection
        [void]$files.Add($file)
        $data.SetFileDropList($files)
        $result = $form.DoDragDrop($data, [System.Windows.Forms.DragDropEffects]::Copy)
        Write-Host "DoDragDrop returned $result"
        $form.Close()
    })
    [void]$form.ShowDialog()

    [void](WaitFor { (SurfaceText).Text.Contains('drop test.txt') } 'the dropped path in the terminal')
    Write-Host 'Dropping a file pasted its path:'
    Write-Host (((SurfaceText).Text -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1))
} finally {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    Remove-Item $file -ErrorAction SilentlyContinue
}
