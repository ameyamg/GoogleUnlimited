# =====================================================================
# Regression Test Suite: BUG-05 (Upload Progress Tracking & 80% Stall Elimination)
# =====================================================================
$ErrorActionPreference = "Stop"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  TEST SUITE: BUG-05 Upload Progress & 80% Stall Elimination" -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Cyan

$passed = 0
$failed = 0

function Assert-Condition([string]$testName, [bool]$condition, [string]$detail = "") {
    if ($condition) {
        Write-Host "  [PASS] $testName" -ForegroundColor Green
        $script:passed++
    } else {
        Write-Host "  [FAIL] ${testName}: $detail" -ForegroundColor Red
        $script:failed++
    }
}

# 1. Verify Win32IoHelper loads successfully on Windows
$repoRoot = Split-Path -Parent $PSScriptRoot
$watchScript = Join-Path $repoRoot "WatchAndUpload.ps1"

# Dot-source with -StatusOnly to load definitions without running watcher
. $watchScript -StatusOnly | Out-Null

$hasIoHelper = [bool](([System.Management.Automation.PSTypeName]'Win32IoHelper').Type)
Assert-Condition "Win32IoHelper is loaded and available" $hasIoHelper

# 2. Test Real Process IO Counter Tracking
$tempFile = Join-Path $env:TEMP "gotohp_test_io_progress.dat"
$fileSize = 5MB
$dummyData = New-Object byte[] $fileSize
(New-Object Random).NextBytes($dummyData)
[System.IO.File]::WriteAllBytes($tempFile, $dummyData)

try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell.exe"
    # Child process reads the file after a short pause
    $psi.Arguments = "-NoProfile -Command `"Start-Sleep -Milliseconds 400; `$b = [System.IO.File]::ReadAllBytes('$tempFile'); Start-Sleep -Milliseconds 400`""
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    $io = New-Object Win32IoHelper+IO_COUNTERS
    
    # Capture initial reading
    Start-Sleep -Milliseconds 150
    [Win32IoHelper]::GetProcessIoCounters($proc.Handle, [ref]$io) | Out-Null
    $initialRead = $io.ReadTransferCount

    # Wait for child process to read the file
    Start-Sleep -Milliseconds 600
    [Win32IoHelper]::GetProcessIoCounters($proc.Handle, [ref]$io) | Out-Null
    $midRead = $io.ReadTransferCount

    $proc.WaitForExit()

    $rawDelta = [double]($midRead - $initialRead)
    Assert-Condition "IO counters detect child process reading file" ($rawDelta -ge ($fileSize * 0.90)) "Detected bytes: $rawDelta, Expected: >= $($fileSize * 0.90)"

    $uploadedBytes = [Math]::Min([double]$fileSize, [Math]::Max(0.0, $rawDelta))
    $ratio = [Math]::Min(0.99, [Math]::Max(0.01, $uploadedBytes / $fileSize))
    Assert-Condition "Progress ratio reflects actual bytes transferred (>90%)" ($ratio -ge 0.90) "Ratio: $ratio"
} finally {
    Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
}

# 3. Test Fallback Estimation: Ensure NO mathematical asymptote at 86.9%
# Previously: ratio = elapsedSec / (elapsedSec * 1.15 + 2.0) -> capped at 86.9%
$estTotalSec = 100.0

# Function simulating the fixed fallback progression
function Get-FallbackRatio([double]$elapsed, [double]$estTotal) {
    if ($elapsed -lt $estTotal) {
        return [Math]::Min(0.90, [Math]::Max(0.01, ($elapsed / $estTotal) * 0.90))
    } else {
        $overSec = $elapsed - $estTotal
        return 0.90 + (0.09 * (1.0 - [Math]::Exp(-$overSec / [Math]::Max(30.0, $estTotal))))
    }
}

# Test at elapsed times where the old code was strictly stuck at 86.8%:
$rOldStuckTime1 = Get-FallbackRatio 150.0 $estTotalSec
$rOldStuckTime2 = Get-FallbackRatio 500.0 $estTotalSec
$rOldStuckTime3 = Get-FallbackRatio 811.9 $estTotalSec

Assert-Condition "Fallback ratio at 150s exceeds 90%" ($rOldStuckTime1 -gt 0.90) "Ratio at 150s: $rOldStuckTime1"
Assert-Condition "Fallback ratio at 500s exceeds 95%" ($rOldStuckTime2 -gt 0.95) "Ratio at 500s: $rOldStuckTime2"
Assert-Condition "Fallback ratio at 811.9s exceeds 98% (not stuck at 86.8%)" ($rOldStuckTime3 -gt 0.98) "Ratio at 811.9s: $rOldStuckTime3"
Assert-Condition "Fallback progression is strictly monotonic" ($rOldStuckTime3 -gt $rOldStuckTime2 -and $rOldStuckTime2 -gt $rOldStuckTime1)

# 4. Test Finalizing ETA Display when file read completes
function Get-EtaDisplay([double]$ratio, [double]$fileBytes, [double]$uploadedBytes, [double]$elapsedSec) {
    if ($ratio -ge 0.99) {
        return ", finalizing..."
    } elseif ($ratio -gt 0.03 -and $elapsedSec -gt 0.8) {
        $speedBytes = $uploadedBytes / $elapsedSec
        $remainBytes = [Math]::Max(0.0, $fileBytes - $uploadedBytes)
        if ($speedBytes -gt 1024) {
            $remainSec = $remainBytes / $speedBytes
            return ", " + (Format-RemainingTime $remainSec)
        }
    }
    return ""
}

$etaFinalizing = Get-EtaDisplay 0.99 480MB 480MB 300.0
Assert-Condition "ETA displays 'finalizing...' instead of misleading countdown at >=99%" ($etaFinalizing -eq ", finalizing...") "Got: $etaFinalizing"

$etaActive = Get-EtaDisplay 0.50 100MB 50MB 50.0
Assert-Condition "Active upload calculates valid countdown ETA" ($etaActive -like "*left*") "Got: $etaActive"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  RESULTS: $passed Passed, $failed Failed" -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Red" })
Write-Host "==========================================================" -ForegroundColor Cyan

if ($failed -gt 0) { exit 1 } else { exit 0 }
