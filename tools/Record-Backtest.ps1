param(
    [Parameter(Mandatory = $true)]
    [string]$IniPath,
    [string]$Label = "manual",
    [string]$Notes = "",
    [string]$TerminalPath = "C:\Program Files\MetaTrader 5 FOREX.com US\terminal64.exe",
    [string]$LedgerPath = "C:\Users\digit\OneDrive\Documents\Codex-Projects\MT5\backtest_ledger.csv",
    [int]$TimeoutSec = 600
)

$ErrorActionPreference = "Stop"

function Get-LatestFile([string]$Path, [string]$Filter) {
    return Get-ChildItem -Path $Path -File -Filter $Filter | Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Parse-LastRunBlock([string[]]$lines) {
    $start = -1
    for($i = $lines.Count - 1; $i -ge 0; $i--) {
        if($lines[$i] -match "testing of Experts\\.+ from \d{4}\.\d{2}\.\d{2} \d{2}:\d{2} to \d{4}\.\d{2}\.\d{2} \d{2}:\d{2}") {
            $start = $i
            break
        }
    }
    if($start -lt 0) { return $null }
    return ,($lines[$start..($lines.Count - 1)])
}

if(-not (Test-Path $IniPath)) {
    throw "INI not found: $IniPath"
}
if(-not (Test-Path $TerminalPath)) {
    throw "Terminal not found: $TerminalPath"
}

# Run tester
$proc = Start-Process -FilePath $TerminalPath -ArgumentList "/config:`"$IniPath`"" -PassThru

$terminalRoot = Join-Path $env:APPDATA "MetaQuotes\Terminal"
$testerLog = $null
$timer = [Diagnostics.Stopwatch]::StartNew()

while($timer.Elapsed.TotalSeconds -lt $TimeoutSec) {
    Start-Sleep -Seconds 2
    $candidate = Get-ChildItem -Path $terminalRoot -Recurse -File -Filter "*.log" |
        Where-Object { $_.FullName -like "*\Tester\logs\*" } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if($candidate) {
        $testerLog = $candidate
        $tail = Get-Content -Path $testerLog.FullName -Tail 40 -ErrorAction SilentlyContinue
        if($tail -match "automatical testing finished|test Experts\\.+ thread finished|final balance") {
            break
        }
    }
}

if(-not $proc.HasExited) {
    try { Stop-Process -Id $proc.Id -Force } catch {}
}

if(-not $testerLog) {
    throw "Could not find tester log."
}

$testerLines = Get-Content -Path $testerLog.FullName
$run = Parse-LastRunBlock -lines $testerLines
if(-not $run) {
    throw "Could not parse run block from tester log: $($testerLog.FullName)"
}

$expert = ""
$symbol = ""
$period = ""
$fromDate = ""
$toDate = ""
$initialDeposit = 0.0
$finalBalance = 0.0
$bars = 0
$ticks = 0

foreach($line in $run) {
    if($line -match "testing of (Experts\\[^ ]+) from ([0-9\.\: ]+) to ([0-9\.\: ]+)") {
        $expert = $Matches[1]
        $fromDate = $Matches[2].Trim()
        $toDate = $Matches[3].Trim()
    }
    if($line -match "([A-Z]{6}),([A-Z0-9]+).*testing of Experts\\") {
        $symbol = $Matches[1]
        $period = $Matches[2]
    }
    if($line -match "initial deposit ([0-9]+\.[0-9]+)") {
        $initialDeposit = [double]$Matches[1]
    }
    if($line -match "final balance ([0-9]+\.[0-9]+)") {
        $finalBalance = [double]$Matches[1]
    }
    if($line -match ": ([0-9]+) ticks, ([0-9]+) bars generated") {
        $ticks = [int64]$Matches[1]
        $bars = [int64]$Matches[2]
    }
}

# Fallback: use full tester log for final balance/deposit if not in the slice.
if($initialDeposit -le 0.0) {
    foreach($line in $testerLines) {
        if($line -match "initial deposit ([0-9]+\.[0-9]+)") {
            $initialDeposit = [double]$Matches[1]
        }
    }
}
if($finalBalance -le 0.0) {
    for($i = $testerLines.Count - 1; $i -ge 0; $i--) {
        if($testerLines[$i] -match "final balance ([0-9]+\.[0-9]+)") {
            $finalBalance = [double]$Matches[1]
            break
        }
    }
}

# Parse latest agent log for entry/exit diagnostics
$testerRoot = Join-Path $env:APPDATA "MetaQuotes\Tester"
$agentLog = Get-ChildItem -Path $testerRoot -Recurse -File -Filter "*.log" |
    Where-Object { $_.FullName -like "*\Agent-127.0.0.1-*\logs\*" } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

$entries = 0
$stopouts = 0
$tpHits = 0

if($agentLog) {
    $agentLines = Get-Content -Path $agentLog.FullName
    $start = -1
    for($i = $agentLines.Count - 1; $i -ge 0; $i--) {
        if($agentLines[$i] -match "testing of Experts\\.+ from \d{4}\.\d{2}\.\d{2} \d{2}:\d{2} to \d{4}\.\d{2}\.\d{2} \d{2}:\d{2} started with inputs") {
            $start = $i
            break
        }
    }
    if($start -ge 0) {
        $slice = $agentLines[$start..($agentLines.Count - 1)]
        $entries = ($slice | Select-String -Pattern "CTrade::OrderSend: market (buy|sell)" -AllMatches).Count
        $stopouts = ($slice | Select-String -Pattern "stop loss triggered" -AllMatches).Count
        $tpHits = ($slice | Select-String -Pattern "take profit triggered" -AllMatches).Count
    }
}

$netPnl = [math]::Round(($finalBalance - $initialDeposit), 2)
$timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

$record = [PSCustomObject]@{
    timestamp       = $timestamp
    label           = $Label
    expert          = $expert
    symbol          = $symbol
    period          = $period
    from_date       = $fromDate
    to_date         = $toDate
    initial_deposit = [math]::Round($initialDeposit, 2)
    final_balance   = [math]::Round($finalBalance, 2)
    net_pnl         = [math]::Round($netPnl, 2)
    entries         = $entries
    stopouts        = $stopouts
    tp_hits         = $tpHits
    ticks           = $ticks
    bars            = $bars
    tester_log      = $testerLog.FullName
    agent_log       = $(if($agentLog){$agentLog.FullName}else{""})
    ini             = $IniPath
    notes           = $Notes
}

if(-not (Test-Path $LedgerPath)) {
    $record | ConvertTo-Csv -NoTypeInformation | Set-Content -Path $LedgerPath -Encoding utf8
} else {
    $record | ConvertTo-Csv -NoTypeInformation | Select-Object -Skip 1 | Add-Content -Path $LedgerPath
}

Write-Host "Recorded backtest -> $LedgerPath"
Write-Host "Label=$Label | Symbol=$symbol,$period | NetPnL=$netPnl | Entries=$entries | Stopouts=$stopouts | TP=$tpHits"
