# Binary string extractor for TrollAutoScript analysis
param([string]$FilePath, [string]$OutputFile)

$bytes = [System.IO.File]::ReadAllBytes($FilePath)
$text = [System.Text.Encoding]::ASCII.GetString($bytes)
$matches = [regex]::Matches($text, '[\x20-\x7E]{4,}')
$allStrings = @()
foreach ($m in $matches) {
    $val = $m.Value.Trim()
    if ($val.Length -ge 4 -and $val.Length -le 300) {
        $allStrings += $val
    }
}

# Filter for interesting strings
$keywords = @('bks', 'BKS', 'BackBoard', 'backboard', 'HID', 'hid', 'volume', 'Volume',
              'delivery', 'Delivery', 'router', 'Router', 'register', 'Register',
              'observe', 'Observe', 'monitor', 'Monitor', 'event', 'Event',
              'Hardware', 'hardware', 'Physical', 'physical', 'key', 'Key',
              'button', 'Button', 'press', 'Press', 'BKSHID', 'frontboard')

$filtered = @()
foreach ($s in $allStrings) {
    $lower = $s.ToLower()
    foreach ($kw in $keywords) {
        if ($lower.Contains($kw.ToLower())) {
            $filtered += $s
            break
        }
    }
}

$filtered = $filtered | Sort-Object -Unique

if ($OutputFile) {
    $filtered | Out-File -FilePath $OutputFile -Encoding UTF8
} else {
    $filtered
}
