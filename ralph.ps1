# ralph.ps1 - Autonomous loop runner for Claude Code (Ralph pattern)
# Usage:
#   .\ralph.ps1                          # run up to 5 iterations
#   .\ralph.ps1 -MaxIterations 20        # run up to 20 iterations
#   .\ralph.ps1 -PauseSeconds 10         # wait 10s between iterations
#   .\ralph.ps1 -Safe                    # acceptEdits mode (file edits only;
#                                        #  shell commands outside the allowlist will block)
# Default mode uses --dangerously-skip-permissions, the standard for headless
# Ralph loops: a headless agent cannot answer permission prompts, so anything
# not pre-approved would dead-lock the loop. Guardrails live in LOOP.md
# (one task per run, no push, repo-only scope) and -MaxIterations.
param(
    [int]$MaxIterations = 5,
    [int]$PauseSeconds = 3,
    [switch]$Safe
)

$root = $PSScriptRoot
if (-not (Test-Path (Join-Path $root "LOOP.md"))) {
    Write-Host "LOOP.md not found next to ralph.ps1. Aborting." -ForegroundColor Red
    exit 1
}

Set-Location $root
$bootstrap = "Read LOOP.md and follow its instructions exactly. Process exactly one task this run."

$claudeArgs = @("-p", $bootstrap)
if ($Safe) {
    $claudeArgs += @("--permission-mode", "acceptEdits")
} else {
    $claudeArgs += "--dangerously-skip-permissions"
}

for ($i = 1; $i -le $MaxIterations; $i++) {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host (" Iteration {0} / {1}   {2}" -f $i, $MaxIterations, (Get-Date -Format "yyyy-MM-dd HH:mm:ss")) -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan

    $output = $null | claude @claudeArgs | Out-String
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
