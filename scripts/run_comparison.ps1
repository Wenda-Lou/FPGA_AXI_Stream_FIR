# Full functional and physical comparison, without editing canonical RTL or
# replacing earlier accepted reports. Baseline setup failure is evidence,
# never a passing implementation; all other checks remain mandatory.
param(
    [string]$VivadoBin = '',
    [string]$Python = 'python',
    [switch]$VerifyOnly
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$comparisonRoot = Join-Path $projectRoot 'build/implementation_comparison'
if (-not $VerifyOnly) {
    if ($VivadoBin) { $vivado = Join-Path $VivadoBin 'vivado.bat' }
    else { $vivado = (Get-Command 'vivado.bat' -ErrorAction Stop).Source; $VivadoBin = Split-Path -Parent $vivado }
    if (-not (Test-Path -LiteralPath $vivado -PathType Leaf)) { throw "Missing Vivado: $vivado" }
    & $Python (Join-Path $projectRoot 'scripts/prepare_comparison.py')
    if ($LASTEXITCODE -ne 0) { throw 'Comparison snapshot preparation failed.' }
    foreach ($variant in @('baseline', 'optimized')) {
        $variantRoot = Join-Path $comparisonRoot $variant
        Write-Output "Running $variant complete 47-run regression..."
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $variantRoot 'scripts/run_accelerator.ps1') -VivadoBin $VivadoBin -Python $Python |
            Out-File -LiteralPath (Join-Path $variantRoot 'regression.console.log') -Encoding UTF8
        if ($LASTEXITCODE -ne 0) { throw "$variant regression failed." }
        $outputPath = Join-Path $variantRoot 'build/accelerator_impl'
        New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
        Write-Output "Running $variant placement/routing with identical Tcl and XDC..."
        Push-Location -LiteralPath $outputPath
        try {
            & $vivado -mode batch -nojournal -source (Join-Path $variantRoot 'scripts/implement_accelerator.tcl') -log implementation.log |
                Out-File -LiteralPath implementation.console.log -Encoding UTF8
            $toolExitCode = $LASTEXITCODE
            [System.IO.File]::WriteAllText((Join-Path $outputPath 'process_exit_code.txt'), "$toolExitCode`n")
            if ($toolExitCode -ne 0 -and $variant -ne 'baseline') { throw "$variant implementation failed." }
            # The Python validator accepts a completed baseline only when any
            # failure is setup timing. A crash or routing/hold failure is fatal.
        } finally { Pop-Location }
    }
}
& $Python (Join-Path $projectRoot 'scripts/verify_comparison.py')
if ($LASTEXITCODE -ne 0) { throw 'Comparison evidence verification failed.' }
