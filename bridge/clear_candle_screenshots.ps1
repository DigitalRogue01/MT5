$ErrorActionPreference = 'Stop'

$root = 'C:\Users\digit\AppData\Roaming\MetaQuotes\Terminal\D3E6E9F9DA42E1A2ED575A94AE88F6CD\MQL5\Files\DigitalRogue\CandleScreenshots'

if (-not (Test-Path -LiteralPath $root)) {
    Write-Host "Screenshot folder not found: $root"
    exit 0
}

$patterns = @('*.png', '*.jpg', '*.jpeg')
$files = foreach ($pattern in $patterns) {
    Get-ChildItem -LiteralPath $root -Recurse -File -Filter $pattern -ErrorAction SilentlyContinue
}

$files = $files | Sort-Object FullName -Unique

if (-not $files -or $files.Count -eq 0) {
    Write-Host "No screenshot image files found under:"
    Write-Host $root
    exit 0
}

$count = $files.Count
$files | Remove-Item -Force

Write-Host "Removed $count screenshot image file(s) from:"
Write-Host $root
