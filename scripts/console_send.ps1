# Types a line into the Script Extender console of the running game (testing only).
param([string]$Path)  # a text file, one console line per line
$Lines = @(Get-Content -LiteralPath $Path -Encoding UTF8)
Add-Type @"
using System; using System.Runtime.InteropServices;
public class CW { [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string c, string t);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h); }
"@
Add-Type -AssemblyName System.Windows.Forms
$h = [CW]::FindWindow('ConsoleWindowClass', 'BG3 Script Extender Debug Console')
if ($h -eq [IntPtr]::Zero) { "console window not found"; exit 1 }
[CW]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 400
foreach ($line in $Lines) {
    $escaped = [regex]::Replace($line, '[+^%~(){}\[\]]', { param($m) '{' + $m.Value + '}' })
    [System.Windows.Forms.SendKeys]::SendWait($escaped + '{ENTER}')
    Start-Sleep -Milliseconds 500
}
"sent " + $Lines.Count + " lines"
