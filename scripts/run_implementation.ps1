# Module-level implementation and evidence verification. Run from any directory.
# Generated Vivado diagnostics stay under build/, including phys_opt side files.
param(
    [string]$VivadoBin = '',
    [string]$Python = 'python',
    [switch]$VerifyOnly
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$outputPath = Join-Path $projectRoot 'build/accelerator_impl'
$archivePath = Join-Path $projectRoot 'reports/accelerator/implementation'
New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
if (-not $VerifyOnly) {
    if ($VivadoBin) { $vivado = Join-Path $VivadoBin 'vivado.bat' }
    else { $vivado = (Get-Command 'vivado.bat' -ErrorAction Stop).Source }
    if (-not (Test-Path -LiteralPath $vivado -PathType Leaf)) { throw "Missing Vivado: $vivado" }
    Push-Location -LiteralPath $outputPath
    try {
        & $vivado -mode batch -nojournal -source (Join-Path $projectRoot 'scripts/implement_accelerator.tcl') -log implementation.log |
            Out-File -LiteralPath implementation.console.log -Encoding UTF8
        if ($LASTEXITCODE -ne 0) { throw "Module implementation failed; inspect $outputPath/implementation.log" }
    } finally { Pop-Location }
}
& $Python (Join-Path $projectRoot 'scripts/verify_implementation.py') --build $outputPath --archive $archivePath
if ($LASTEXITCODE -ne 0) { throw 'Implementation evidence verification failed.' }
Write-Output "Implementation evidence archived: $archivePath"
