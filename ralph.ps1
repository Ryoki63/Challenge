# ralph.ps1 - Autonomous loop runner for Claude Code (Ralph pattern)
# Usage:
#   .\ralph.ps1                          # run up to 5 iterations
#   .\ralph.ps1 -MaxIterations 20        # run up to 20 iterations
#   .\ralph.ps1 -PauseSeconds 10         # wait 10s between iterations
param(
    [int]$MaxIterations = 5,
    [int]$PauseSeconds = 3
)

$root = $PSScriptRoot
if (-not (Test-Path (Join-Path $root "LOOP.md"))) {
    Write-Host "LOOP.md not found next to ralph.ps1. Aborting." -ForegroundColor Red
    exit 1
}

Set-Location $root
$bootstrap = "Read LOOP.md and follow its instructions exactly. Process exactly one task this run."

for ($i = 1; $i -le $MaxIterations; $i++) {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host (" Iteration {0} / {1}   {2}" -f $i, $MaxIterations, (Get-Date -Format "yyyy-MM-dd HH:mm:ss")) -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan

    $output = claude -p $bootstrap | Out-String
    Write-Host $output

    if ($output -match "<LOOP_COMPLETE>") {
        Write-Host "Backlog is empty. Loop finished." -ForegroundColor Green
        break
    }
    if ($output -match "<LOOP_BLOCKED>") {
        Write-Host "Task blocked. Check progress/JOURNAL.md before re-running." -ForegroundColor Yellow
        break
    }

    if ($i -lt $MaxIterations) { Start-Sleep -Seconds $PauseSeconds }
}

Write-Host ""
Write-Host "Loop runner exited." -ForegroundColor Cyan
