# Complete acceptance entry point. Run from a fresh Git tree export/checkout.
# Existing accepted history is retained; this run records its own evidence.
param([string]$VivadoBin = '', [string]$Python = 'python')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$outputPath = Join-Path $projectRoot 'build/release'
New-Item -ItemType Directory -Force -Path $outputPath | Out-Null
if (-not $VivadoBin) { $VivadoBin = Split-Path -Parent (Get-Command 'vivado.bat' -ErrorAction Stop).Source }
& $Python (Join-Path $projectRoot 'scripts/verify_release.py') --start
if ($LASTEXITCODE -ne 0) { throw 'Could not freeze release source inputs.' }
$steps = [System.Collections.Generic.List[object]]::new()
$passed = $false
try {
    foreach ($name in @('reference','fifo','fir','datapath','axi_regs','accelerator','comparison','waveforms')) {
        $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f (Join-Path $projectRoot "scripts/run_$name.ps1")))
        if ($name -ne 'reference') { $arguments += @('-VivadoBin',('"{0}"' -f $VivadoBin)) }
        if ($name -notin @('fifo','axi_regs')) { $arguments += @('-Python',('"{0}"' -f $Python)) }
        $start = [DateTimeOffset]::UtcNow
        Write-Output "Release acceptance: $name ..."
        $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru -WorkingDirectory $projectRoot -RedirectStandardOutput (Join-Path $outputPath "$name.stdout.txt") -RedirectStandardError (Join-Path $outputPath "$name.stderr.txt")
        $steps.Add([pscustomobject]@{ name=$name; exit_code=$process.ExitCode; started_at_utc=$start.ToString('o'); duration_seconds=[math]::Round(([DateTimeOffset]::UtcNow-$start).TotalSeconds,3) })
        if ($process.ExitCode -ne 0) { throw "Release step '$name' failed; inspect build/release/$name.*.txt" }
    }
    $passed = $true
} finally {
    $report = [ordered]@{ status=$(if ($passed) { 'passed' } else { 'failed' }); steps=@($steps.ToArray()) }
    [System.IO.File]::WriteAllText((Join-Path $outputPath 'steps.json'), ($report | ConvertTo-Json -Depth 5) + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
}
& $Python (Join-Path $projectRoot 'scripts/verify_release.py')
if ($LASTEXITCODE -ne 0) { throw 'Release evidence verification failed.' }
