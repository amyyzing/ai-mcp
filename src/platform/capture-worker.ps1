$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public class MCPCapture {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder text, int size);
    public static List<object> Windows() {
        var found = new List<object>();
        EnumWindows((h,p) => {
            uint pid; GetWindowThreadProcessId(h, out pid);
            try {
                using(var process = System.Diagnostics.Process.GetProcessById((int)pid)) {
                    if ((process.ProcessName != "RobloxPlayerBeta" && process.ProcessName != "RobloxStudioBeta") || !IsWindowVisible(h)) return true;
                    var text = new StringBuilder(512); GetWindowText(h, text, 512);
                    found.Add(new { pid = (int)pid, hwnd = h.ToString(), title = text.ToString(), processStartedAt = process.StartTime.ToUniversalTime().Ticks.ToString() });
                }
            } catch { }
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
'@
[MCPCapture]::SetThreadDpiAwarenessContext([IntPtr]::new(-4)) | Out-Null
while ($null -ne ($line = [Console]::ReadLine())) {
    $request = $null
    try {
        $request = $line | ConvertFrom-Json
        if ($request.operation -eq 'windows') {
            $result = @([MCPCapture]::Windows())
        } elseif ($request.operation -eq 'capture') {
            $matching = @([MCPCapture]::Windows() | Where-Object { $_.pid -eq $request.pid -and $_.hwnd -eq $request.hwnd -and $_.processStartedAt -eq $request.processStartedAt })
            if ($matching.Count -ne 1) { throw 'Capture window was closed or its identity changed.' }
            $windowHandle = [IntPtr]::new([long]$request.hwnd)
            if ([MCPCapture]::IsIconic($windowHandle)) { throw 'Window is minimized. Restore it before capture.' }
            $rect = New-Object MCPCapture+RECT
            if (-not [MCPCapture]::GetClientRect($windowHandle, [ref]$rect)) { throw 'Client geometry unavailable.' }
            $width = $rect.Right - $rect.Left
            $height = $rect.Bottom - $rect.Top
            if ($width -le 0 -or $height -le 0 -or [long]$width * $height -gt 33000000) { throw 'Unsupported capture dimensions.' }
            $point = New-Object MCPCapture+POINT
            if (-not [MCPCapture]::ClientToScreen($windowHandle, [ref]$point)) { throw 'Client origin unavailable.' }
            $bitmap = New-Object System.Drawing.Bitmap($width, $height)
            try {
                $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
                try {
                    $dc = $graphics.GetHdc()
                    try { $captured = [MCPCapture]::PrintWindow($windowHandle, $dc, 3) }
                    finally { $graphics.ReleaseHdc($dc) }
                } finally { $graphics.Dispose() }
                if (-not $captured) { throw 'PrintWindow rejected capture.' }
                $after = New-Object MCPCapture+RECT
                [MCPCapture]::GetClientRect($windowHandle, [ref]$after) | Out-Null
                if ($after.Right -ne $rect.Right -or $after.Bottom -ne $rect.Bottom) { throw 'Window resized during capture.' }
                $ratio = [Math]::Min([double]1, ([double]$request.maxWidth / [double]$width))
                $returnedWidth = [Math]::Max(1, [int]($width * $ratio))
                $returnedHeight = [Math]::Max(1, [int]($height * $ratio))
                $resized = New-Object System.Drawing.Bitmap($bitmap, $returnedWidth, $returnedHeight)
                try {
                    $stream = New-Object System.IO.MemoryStream
                    $encoder = New-Object System.Drawing.Imaging.EncoderParameters(1)
                    try {
                        $encoder.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [long]$request.quality)
                        $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1
                        $resized.Save($stream, $codec, $encoder)
                        $result = @{ width=$width; height=$height; returnedWidth=$returnedWidth; returnedHeight=$returnedHeight; x=$point.X; y=$point.Y;
                            dpi=[MCPCapture]::GetDpiForWindow($windowHandle); capturedAtMs=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); imageBase64=[Convert]::ToBase64String($stream.ToArray()) }
                    } finally { $encoder.Dispose(); $stream.Dispose() }
                } finally { $resized.Dispose() }
            } finally { $bitmap.Dispose() }
        } else { throw 'Unknown capture operation.' }
        [Console]::WriteLine((@{ id=$request.id; result=$result } | ConvertTo-Json -Depth 8 -Compress))
    } catch {
        [Console]::WriteLine((@{ id=$request.id; error=$_.Exception.Message } | ConvertTo-Json -Compress))
    }
}
