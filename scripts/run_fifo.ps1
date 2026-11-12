param(
    [string]$VivadoBin = '',
    [int[]]$Seeds = @(1..20),
    [ValidateRange(1, 100000)]
    [int]$Samples = 10000,
    [ValidateRange(1, 100000)]
    [int]$SmokeSamples = 1000,
    [switch]$SkipSmoke
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if ($Seeds.Count -eq 0 -or @($Seeds | Where-Object { $_ -le 0 }).Count -gt 0) {
    throw 'Provide at least one positive seed.'
}
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
$rtlPath = Join-Path $projectRoot 'fpga_streaming_dsp/fpga_streaming_dsp.srcs/sources_1/new/axis_fifo.v'
$tbPath = Join-Path $projectRoot 'fpga_streaming_dsp/fpga_streaming_dsp.srcs/sim_1/tb_axis_fifo.sv'
$outputPath = Join-Path $projectRoot 'build/fifo_sim'
New-Item -ItemType Directory -Path $outputPath -Force | Out-Null

$configurations = @(
    [pscustomobject]@{ Width = 16; Depth = 16; Seeds = $Seeds; Samples = $Samples }
)
if (-not $SkipSmoke) {
    foreach ($dimensions in @(@(16, 2), @(16, 4), @(8, 4), @(32, 16))) {
        $configurations += [pscustomobject]@{
            Width = $dimensions[0]; Depth = $dimensions[1]
            Seeds = @(1, 7, 42); Samples = $SmokeSamples
        }
    }
}
$results = [System.Collections.Generic.List[object]]::new()
$regressionPassed = $false

Push-Location -LiteralPath $outputPath
try {
    # Compile the DUT as Verilog and the testbench as SystemVerilog.
    & $simTools['xvlog'] $rtlPath
    if ($LASTEXITCODE -ne 0) { throw 'FIFO Verilog compilation failed.' }
    & $simTools['xvlog'] -sv $tbPath
    if ($LASTEXITCODE -ne 0) { throw 'FIFO testbench compilation failed.' }
    foreach ($configuration in $configurations) {
        $snapshot = "fifo_w$($configuration.Width)_d$($configuration.Depth)"
        $elaborationOptions = "$snapshot.elaborate.txt"
        @(
            ('-generic_top "DATA_WIDTH={0}"' -f $configuration.Width)
            ('-generic_top "DEPTH={0}"' -f $configuration.Depth)
            ('-s {0}' -f $snapshot)
            '-debug typical'
            ('-log {0}.elaborate.log' -f $snapshot)
        ) | Set-Content -LiteralPath $elaborationOptions -Encoding ASCII
        & $simTools['xelab'] work.tb_axis_fifo -f $elaborationOptions
        if ($LASTEXITCODE -ne 0) { throw "FIFO elaboration failed: $snapshot" }

        foreach ($seed in $configuration.Seeds) {
            $runName = "${snapshot}_seed$seed"
            $logPath = "$runName.log"
            $optionsPath = "$runName.options.txt"
            # Options files preserve '=' through the Windows batch wrappers.
            @(
                '-runall'
                ('-testplusarg "SEED={0}"' -f $seed)
                ('-testplusarg "SAMPLES={0}"' -f $configuration.Samples)
                ('-log "{0}"' -f $logPath)
            ) | Set-Content -LiteralPath $optionsPath -Encoding ASCII
            # Clear the old log so an engine startup failure cannot reuse a PASS.
            [System.IO.File]::WriteAllText((Join-Path $outputPath $logPath), '')
            & $simTools['xsim'] $snapshot -f $optionsPath | Out-File -FilePath "$runName.console.log" -Encoding UTF8
            if ($LASTEXITCODE -ne 0) { throw "FIFO simulation failed: $runName" }
            $logText = Get-Content -LiteralPath $logPath -Raw
            $pass = [regex]::Match($logText, '(?m)^PASS: axis_fifo .*')
            if ($logText -match '(?im)^\s*(fatal|error)\s*:' -or -not $pass.Success) {
                Get-Content -LiteralPath $logPath -Tail 25 | Write-Output
                throw "FIFO test did not pass: $runName; see $outputPath/$logPath"
            }
            $metrics = [ordered]@{}
            foreach ($metric in [regex]::Matches($pass.Value, '(\w+)=(\d+)')) {
                $metrics[$metric.Groups[1].Value] = [int]$metric.Groups[2].Value
            }
            if ($metrics.width -ne $configuration.Width -or $metrics.depth -ne $configuration.Depth -or
                $metrics.seed -ne $seed -or $metrics.random_samples -lt $configuration.Samples) {
                throw "FIFO result configuration mismatch: $runName"
            }
            $metrics['log'] = $logPath
            $results.Add([pscustomobject]$metrics)
            Write-Output $pass.Value
        }
    }
    $regressionPassed = $true
    Write-Output "FIFO regression passed: $($results.Count) runs. Logs and results.json: $outputPath"
} finally {
    $report = [ordered]@{
        status = $(if ($regressionPassed) { 'passed' } else { 'failed' })
        rtl_sha256 = (Get-FileHash -LiteralPath $rtlPath -Algorithm SHA256).Hash
        testbench_sha256 = (Get-FileHash -LiteralPath $tbPath -Algorithm SHA256).Hash
        runs = @($results.ToArray())
    }
    [System.IO.File]::WriteAllText(
        (Join-Path $outputPath 'results.json'),
        ($report | ConvertTo-Json -Depth 6) + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false)
    )
    Pop-Location
}
