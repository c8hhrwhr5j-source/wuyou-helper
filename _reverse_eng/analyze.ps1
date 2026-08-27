$ErrorActionPreference = 'Stop'
$bin = 'C:\TrollAutoTouch\_reverse_eng\zip236\Payload\TrollAutoScript.app\TrollAutoScript'
$bytes = [System.IO.File]::ReadAllBytes($bin)
$s = [System.Text.Encoding]::UTF8.GetString($bytes)

Write-Output '=== ScreenCapture / IOSurface related strings ==='
$m = [regex]::Matches($s, '[A-Za-z0-9_]{3,100}')
$m | ForEach-Object { $_.Value } | Where-Object {
    $_ -match 'ScreenCapture|IOSurface|CARender|captureScreen|captureImage|Framebuffer|RenderServer|GlobalDisplay|ColorSpace|BGRA|ARGB|displayGamut|_dumpIOSurface|createScreenIOSurface|ScreenSurface'
} | Sort-Object -Unique

Write-Output ''
Write-Output '=== Objective-C method names containing capture/screen/surface ==='
$m2 = [regex]::Matches($s, '[\w:]{4,120}')
$m2 | ForEach-Object { $_.Value } | Where-Object {
    $_ -match '^(capture|screen|display|getColor|findColor|grab|dump|render|surface|iosurface|screenshot|takeScreenshot)'
} | Sort-Object -Unique | Select-Object -First 200
