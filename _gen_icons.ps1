$src = "c:/TrollAutoTouch/TrollAutoTouch_icon.png"
$dst = "c:/TrollAutoTouch/TrollAutoTouch/Assets.xcassets/AppIcon.appiconset"

$names = @(
    "AppIcon60x60@2x.png",
    "AppIcon60x60@3x.png",
    "AppIcon76x76~ipad.png",
    "AppIcon76x76@2x~ipad.png",
    "icon-1024.png"
)

foreach ($n in $names) {
    $target = Join-Path $dst $n
    Copy-Item -Force $src $target
    Write-Host "Copied: $n"
}

Write-Host "Done!"
