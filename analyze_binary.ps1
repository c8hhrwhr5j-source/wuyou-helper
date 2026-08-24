# Binary analysis script
$files = @{
    'Main' = 'C:\TrollAutoTouch\_reverse_eng\Payload\TrollAutoScript.app\TrollAutoScript'
    'HUDServices' = 'C:\TrollAutoTouch\_reverse_eng\Payload\TrollAutoScript.app\HUD\HUDServices'
    'Keyboard' = 'C:\TrollAutoTouch\_reverse_eng\Payload\TrollAutoScript.app\PlugIns\TASKeyBoard.appex\wudiKeyBoard'
}

$keywords = @(
    'volume', 'Volume', 'button', 'Button', 'keyboard', 'Keyboard',
    'CPDistributedMessagingCenter', 'IOHID', 'SpringBoard',
    'mach_port', 'dlsym', 'dlopen', 'SBApplication',
    'launchd', 'daemon', 'HUDServices', 'TAS', 'wudi',
    'hardware', 'outputVolume', 'AVSystemController',
    'setVolume', 'addObserver', 'keyPath',
    'register', 'subscribe', 'listen', 'monitor',
    'physical', 'press', 'touch', 'input', 'event',
    'frontboard', 'BSService', 'entitlement',
    'TrollStore', 'TrollAuto', 'volumeChanged',
    'audioSession', 'AVAudioSession'
)

foreach ($name in $files.Keys) {
    $path = $files[$name]
    if (Test-Path $path) {
        $size = (Get-Item $path).Length
        Write-Host "`n$name ($size bytes) [$path]"
        Write-Host "-" * 80
        
        # Read file as bytes and search for strings
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $text = [System.Text.Encoding]::ASCII.GetString($bytes)
        
        $found = @()
        foreach ($kw in $keywords) {
            if ($text.Contains($kw)) {
                $found += $kw
            }
        }
        
        if ($found.Count -gt 0) {
            Write-Host "Found keywords: $($found -join ', ')"
        } else {
            Write-Host "No keywords found"
        }
        
        # Extract some strings from the binary
        $matches = [regex]::Matches($text, '[\x20-\x7E]{6,}')
        $strings = $matches | ForEach-Object { $_.Value }
        $relevant = $strings | Where-Object { 
            $_.ToLower() -match 'volume|button|key|hid|messag|spring|daemon|hud|tas|wudi|hardware|launch|audio|system|observer|keyboard|frontboard|entitlement'
        } | Select-Object -Unique
        
        if ($relevant) {
            Write-Host "`nRelevant strings:"
            $relevant | Select-Object -First 60 | ForEach-Object { Write-Host "  `"$_`"" }
        }
    } else {
        Write-Host "`n$name: NOT FOUND at $path"
    }
}
