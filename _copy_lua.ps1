$srcLib = 'c:\脚本\TrollAutoTouch\_tmp_extracted\Payload\TrollAutoScript.app\svip\lib'
$dst = 'c:\脚本\TrollAutoTouch\TrollAutoTouch\Resources\lua'

New-Item -ItemType Directory -Force -Path $dst | Out-Null

# Copy all .lua files
Get-ChildItem -Path $srcLib -Filter '*.lua' | Copy-Item -Destination $dst -Force

# Copy croissant subdirectory
$srcCroissant = Join-Path $srcLib 'croissant'
$dstCroissant = Join-Path $dst 'croissant'
if (Test-Path $srcCroissant) {
    New-Item -ItemType Directory -Force -Path $dstCroissant | Out-Null
    Get-ChildItem -Path $srcCroissant -Filter '*.lua' | Copy-Item -Destination $dstCroissant -Force
}

# Copy OCR models
$srcRes = 'c:\脚本\TrollAutoTouch\_tmp_extracted\Payload\TrollAutoScript.app\svip\res'
$dstRes = 'c:\脚本\TrollAutoTouch\TrollAutoTouch\Resources\lua\res'
if (Test-Path $srcRes) {
    New-Item -ItemType Directory -Force -Path $dstRes | Out-Null
    Get-ChildItem -Path $srcRes -Recurse -File | Copy-Item -Destination $dstRes -Force
}

Write-Host "Lua scripts and resources copied successfully."
Write-Host "Files copied: $((Get-ChildItem -Path $dst -Recurse -Filter '*.lua' | Measure-Object).Count) Lua files"
