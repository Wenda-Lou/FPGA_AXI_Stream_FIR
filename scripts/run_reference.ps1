param(
    [string]$Python = 'python',
    [int]$Seed = 1,
    [int]$Count = 10000,
    [string]$Output = 'build/vectors'
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Push-Location -LiteralPath $projectRoot
try {
    & $Python -c "import sys; print(sys.version); sys.exit(0 if sys.version_info >= (3, 10) else 1)"
    if ($LASTEXITCODE -ne 0) { throw 'Python 3.10 or newer is required.' }
    & $Python -m unittest discover -s tests -v
    if ($LASTEXITCODE -ne 0) { throw 'Reference-model tests failed.' }
    & $Python scripts/generate_vectors.py --seed $Seed --count $Count --output $Output
    if ($LASTEXITCODE -ne 0) { throw 'Vector generation failed.' }
} finally {
    Pop-Location
}
