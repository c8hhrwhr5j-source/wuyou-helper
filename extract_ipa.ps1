# Rename and extract
Copy-Item "C:\TrollAutoTouch\TrollAutoScript2.3.6.tipa" "C:\TrollAutoTouch\TrollAutoScript2.3.6.zip" -Force
Expand-Archive -Path "C:\TrollAutoTouch\TrollAutoScript2.3.6.zip" -DestinationPath "C:\TrollAutoTouch\_reverse_eng" -Force
Write-Host "Extraction complete"
Get-ChildItem -Path "C:\TrollAutoTouch\_reverse_eng" -Recurse | Select-Object -First 50
