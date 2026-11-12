param(
    [string]$VivadoBin = '',
    [string]$Python = 'python',
    [int[]]$Seeds = @(1, 7, 42),
    [ValidateRange(1, 100000)]
    [int]$Samples = 10000
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if ($Seeds.Count -eq 0 -or @($Seeds | Where-Object { $_ -le 0 }).Count -gt 0) {
    throw 'Provide at least one positive seed.'
}
& $Python -c "import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)"
if ($LASTEXITCODE -ne 0) { throw 'Python 3.10 or newer is required.' }
$simTools = @{}
foreach ($name in @('xvlog', 'xelab', 'xsim')) {
    if ($VivadoBin) {
        $toolPath = Join-Path $VivadoBin ($name + '.bat')
        if (-not (Test-Path -LiteralPath $toolPath -PathType Leaf)) { throw "Missing tool: $toolPath" }
        $simTools[$name] = (Resolve-Path -LiteralPath $toolPath).Path
    } else {
        $simTools[$name] = (Get-Command ($name + '.bat') -ErrorAction Stop).Source
    }
}
$rtlPath = Join-Path $projectRoot 'fpga_streaming_dsp/fpga_streaming_dsp.srcs/sources_1/new/fir_core.v'
$tbPath = Join-Path $projectRoot 'fpga_streaming_dsp/fpga_streaming_dsp.srcs/sim_1/tb_fir_core.sv'
$comparisonPath = Join-Path $projectRoot 'scripts/compare_fir_events.py'
$outputPath = Join-Path $projectRoot 'build/fir_sim'
New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
$results = [System.Collections.Generic.List[object]]::new()
$passed = $false

Push-Location -LiteralPath $outputPath
try {
    & $simTools['xvlog'] $rtlPath
    if ($LASTEXITCODE -ne 0) { throw 'FIR RTL compilation failed.' }
    & $simTools['xvlog'] -sv $tbPath
    if ($LASTEXITCODE -ne 0) { throw 'FIR testbench compilation failed.' }
    & $simTools['xelab'] work.tb_fir_core -s fir_check -debug typical
    if ($LASTEXITCODE -ne 0) { throw 'FIR elaboration failed.' }
    foreach ($seed in $Seeds) {
        $logPath = "seed_$seed.log"
        $eventsPath = "seed_$seed.events.txt"
        $summaryPath = "seed_$seed.python.json"
        $optionsPath = "seed_$seed.options.txt"
        @(
            '-runall'
            ('-testplusarg "SEED={0}"' -f $seed)
            ('-testplusarg "SAMPLES={0}"' -f $Samples)
            ('-testplusarg "EVENTS={0}"' -f $eventsPath)
            ('-log "{0}"' -f $logPath)
        ) | Set-Content -LiteralPath $optionsPath -Encoding ASCII
        [System.IO.File]::WriteAllText((Join-Path $outputPath $logPath), '')
        [System.IO.File]::WriteAllText((Join-Path $outputPath $eventsPath), '')
        & $simTools['xsim'] fir_check -f $optionsPath | Out-File -FilePath "seed_$seed.console.log" -Encoding UTF8
        if ($LASTEXITCODE -ne 0) { throw "FIR simulation failed for seed $seed" }
        $logText = Get-Content -LiteralPath $logPath -Raw
        $passLine = [regex]::Match($logText, '(?m)^PASS: fir_core .*')
        if ($logText -match '(?im)^\s*(fatal|error)\s*:' -or -not $passLine.Success) {
            Get-Content -LiteralPath $logPath -Tail 25 | Write-Output
            throw "FIR test failed for seed $seed"
        }
        & $Python $comparisonPath --events $eventsPath --summary $summaryPath | Out-File -FilePath "seed_$seed.python.console.log" -Encoding UTF8
        if ($LASTEXITCODE -ne 0) { throw "Python FIR comparison failed for seed $seed" }
        $comparison = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
        $metrics = [ordered]@{}
        foreach ($metric in [regex]::Matches($passLine.Value, '(\w+)=(\d+)')) {
            $metrics[$metric.Groups[1].Value] = [int]$metric.Groups[2].Value
        }
        if ($metrics.seed -ne $seed -or $metrics.random_samples -lt $Samples -or
            $metrics.writes -ne $comparison.inputs -or $metrics.reads -ne $comparison.outputs -or
            $metrics.reset_discarded -ne $comparison.reset_discarded) {
            throw "FIR result accounting mismatch for seed $seed"
        }
        $metrics['python_status'] = $comparison.status
        $metrics['log'] = $logPath
        $metrics['events'] = $eventsPath
        $results.Add([pscustomobject]$metrics)
        Write-Output $passLine.Value
        Write-Output "PASS: Python comparison seed=$seed outputs=$($comparison.outputs)"
    }
    $passed = $true
    Write-Output "FIR regression passed: $($results.Count) runs. Results: $outputPath/results.json"
} finally {
    $report = [ordered]@{
        status = $(if ($passed) { 'passed' } else { 'failed' })
        rtl_sha256 = (Get-FileHash -LiteralPath $rtlPath -Algorithm SHA256).Hash
        testbench_sha256 = (Get-FileHash -LiteralPath $tbPath -Algorithm SHA256).Hash
        model_sha256 = (Get-FileHash -LiteralPath (Join-Path $projectRoot 'model/fir.py') -Algorithm SHA256).Hash
        runs = @($results.ToArray())
    }
    [System.IO.File]::WriteAllText((Join-Path $outputPath 'results.json'),
        ($report | ConvertTo-Json -Depth 6) + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false))
    Pop-Location
}
