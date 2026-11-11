# Moves the game window to the top-left corner and makes it the active window (controller UI testing).
Add-Type @"
using System; using System.Runtime.InteropServices;
public class W { [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c); }
"@
$p = Get-Process bg3_dx11, bg3 -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $p) { "game window not found"; exit 1 }
[W]::ShowWindow($p.MainWindowHandle, 9) | Out-Null
[W]::SetWindowPos($p.MainWindowHandle, [IntPtr]::Zero, 0, 0, 0, 0, 0x0001 -bor 0x0004) | Out-Null  # no resize, keep z-order
[W]::SetForegroundWindow($p.MainWindowHandle) | Out-Null
"focused: " + $p.MainWindowTitle
