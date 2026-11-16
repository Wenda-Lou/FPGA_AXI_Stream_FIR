# Compile, simulate and independently replay the complete AXI-controlled FIR regression matrix.
# Defaults: 20 full-size runs plus 9 smaller configurations at 3 seeds each.
# VivadoBin selects an installation explicitly; otherwise tools come from PATH.
# Python must name a working Python 3.10+ executable, not a Windows Store alias.
param(
    [string]$VivadoBin = '',
    [string]$Python = 'python',
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
& $Python -c "import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)"
if ($LASTEXITCODE -ne 0) { throw 'Python 3.10 or newer is required.' }
# Resolve each executable before starting work so installation errors fail early.
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
$rtlPath = Join-Path $projectRoot 'fpga_streaming_dsp/fpga_streaming_dsp.srcs/sources_1/new/dsp_accelerator.v'
$tbPath = Join-Path $projectRoot 'fpga_streaming_dsp/fpga_streaming_dsp.srcs/sim_1/tb_dsp_accelerator.sv'
$fifoPath = Join-Path $projectRoot 'fpga_streaming_dsp/fpga_streaming_dsp.srcs/sources_1/new/axis_fifo.v'
$corePath = Join-Path $projectRoot 'fpga_streaming_dsp/fpga_streaming_dsp.srcs/sources_1/new/fir_core.v'
$datapathPath = Join-Path $projectRoot 'fpga_streaming_dsp/fpga_streaming_dsp.srcs/sources_1/new/dsp_datapath.v'
$regsPath = Join-Path $projectRoot 'fpga_streaming_dsp/fpga_streaming_dsp.srcs/sources_1/new/axi_lite_regs.v'
$comparisonPath = Join-Path $projectRoot 'scripts/compare_fir_events.py'
# Keep generated simulator databases, options, logs and traces under build/.
# Source paths are absolute, allowing tools to run from this isolated directory.
$outputPath = Join-Path $projectRoot 'build/accelerator_sim'
New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
$results = [System.Collections.Generic.List[object]]::new()
$passed = $false

# The required configuration receives the full user-selected seed/sample budget.
# Smoke cases exercise minimum/asymmetric FIFO depths, one tap, smaller words,
# mixed binary points, an output wider than the raw accumulator, maximum tap
# count and full 32-bit coefficients passing through the actual register map.
$configurations = @(
    [pscustomobject]@{ Taps=8; InputWidth=16; CoeffWidth=16; OutputWidth=16; InputFrac=15; CoeffFrac=15; OutputFrac=15; InputDepth=16; OutputDepth=16; Seeds=$Seeds; Samples=$Samples }
)
if (-not $SkipSmoke) {
    foreach ($dimensions in @(
        @(8,16,16,16,15,15,15,2,2), @(8,16,16,16,15,15,15,2,16),
        @(8,16,16,16,15,15,15,16,2), @(1,16,16,16,15,15,15,2,4),
        @(4,8,8,8,7,7,7,4,2), @(4,12,10,14,9,8,10,4,8),
        @(1,4,4,12,0,0,0,2,2), @(32,16,16,16,15,15,15,4,4),
        @(4,8,32,32,0,0,0,4,4)
    )) {
        $configurations += [pscustomobject]@{
            Taps=$dimensions[0]; InputWidth=$dimensions[1]; CoeffWidth=$dimensions[2]
            OutputWidth=$dimensions[3]; InputFrac=$dimensions[4]; CoeffFrac=$dimensions[5]
            OutputFrac=$dimensions[6]; InputDepth=$dimensions[7]; OutputDepth=$dimensions[8]; Seeds=@(1,7,42); Samples=$SmokeSamples
        }
    }
}

Push-Location -LiteralPath $outputPath
try {
    # Compile hardware as Verilog and verification as SystemVerilog. Assertions,
    # dynamic queues and longint are testbench features, not RTL requirements.
    & $simTools['xvlog'] $fifoPath $corePath $datapathPath $regsPath $rtlPath
    if ($LASTEXITCODE -ne 0) { throw 'Accelerator RTL compilation failed.' }
    & $simTools['xvlog'] -sv $tbPath
    if ($LASTEXITCODE -ne 0) { throw 'Accelerator bench compilation failed.' }
    $configurationIndex = 0
    foreach ($configuration in $configurations) {
        $snapshot = "accelerator_cfg$configurationIndex"
        $configurationIndex++
        # Parameters are fixed at elaboration, unlike run-time SEED and SAMPLES.
        # Reuse one elaborated snapshot for every seed of a given configuration.
        $parameters = [ordered]@{
            TAPS=$configuration.Taps; DATA_WIDTH=$configuration.InputWidth
            COEFF_WIDTH=$configuration.CoeffWidth; OUTPUT_WIDTH=$configuration.OutputWidth
            INPUT_FRAC_BITS=$configuration.InputFrac; COEFF_FRAC_BITS=$configuration.CoeffFrac
            OUTPUT_FRAC_BITS=$configuration.OutputFrac
            INPUT_FIFO_DEPTH=$configuration.InputDepth; OUTPUT_FIFO_DEPTH=$configuration.OutputDepth
        }
        # Options files preserve quoted NAME=value arguments across Windows batch
        # wrappers, which can otherwise split or strip the equals sign.
        $elaborationOptions = foreach ($parameter in $parameters.GetEnumerator()) {
            '-generic_top "{0}={1}"' -f $parameter.Key, $parameter.Value
        }
        $elaborationOptions += @('-debug typical', "-s $snapshot", "-log $snapshot.elaborate.log")
        $elaborationOptions | Set-Content -LiteralPath "$snapshot.elaborate.txt" -Encoding ASCII
        & $simTools['xelab'] work.tb_dsp_accelerator -f "$snapshot.elaborate.txt"
        if ($LASTEXITCODE -ne 0) { throw "Accelerator elaboration failed: $snapshot" }
        foreach ($seed in $configuration.Seeds) {
            $runName = "${snapshot}_seed$seed"
            $logPath = "$runName.log"
            $eventsPath = "$runName.events.txt"
            $summaryPath = "$runName.python.json"
            $optionsPath = "$runName.options.txt"
            @(
                '-runall'
                ('-testplusarg "SEED={0}"' -f $seed)
                ('-testplusarg "SAMPLES={0}"' -f $configuration.Samples)
                ('-testplusarg "EVENTS={0}"' -f $eventsPath)
                ('-log "{0}"' -f $logPath)
            ) | Set-Content -LiteralPath $optionsPath -Encoding ASCII
            # Erase old evidence before launching: a failed run must never inherit
            # a previous PASS line or an old transaction export with the same name.
            [System.IO.File]::WriteAllText((Join-Path $outputPath $logPath), '')
            [System.IO.File]::WriteAllText((Join-Path $outputPath $eventsPath), '')
            & $simTools['xsim'] $snapshot -f $optionsPath | Out-File -FilePath "$runName.console.log" -Encoding UTF8
            if ($LASTEXITCODE -ne 0) { throw "Accelerator simulation failed for seed $seed" }
            # Check the log as well as the process status: simulation termination
            # does not always propagate a testbench fatal as a nonzero exit code.
            $logText = Get-Content -LiteralPath $logPath -Raw
            $passLine = [regex]::Match($logText, '(?m)^PASS: dsp_accelerator .*')
            if ($logText -match '(?im)^\s*(fatal|error)\s*:' -or -not $passLine.Success) {
                Get-Content -LiteralPath $logPath -Tail 25 | Write-Output
                throw "Accelerator test failed for seed $seed"
            }
            # Replay only real handshakes through the separate Python FIR model.
            # Both numerical output and its per-result saturation flag must agree.
            & $Python $comparisonPath --events $eventsPath --summary $summaryPath | Out-File -FilePath "$runName.python.console.log" -Encoding UTF8
            if ($LASTEXITCODE -ne 0) { throw "Python FIR comparison failed for seed $seed" }
            $comparison = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
            $metrics = [ordered]@{}
            foreach ($metric in [regex]::Matches($passLine.Value, '(\w+)=(\d+)')) {
                $metrics[$metric.Groups[1].Value] = [int]$metric.Groups[2].Value
            }
            # Cross-check counts from two independent consumers of the run. A
            # printed PASS alone is insufficient if the trace is incomplete or
            # came from an incorrectly parameterized simulation snapshot.
            # Retain control-channel accounting and observed coverage as well
            # as stream counts, so reset-discarded requests remain explainable.
            foreach ($label in @('AXI','COVERAGE')) {
                $line = [regex]::Match($logText,('(?m)^{0}: .*' -f $label))
                if (-not $line.Success) { throw "Missing accelerator evidence: $runName / $label" }
                foreach ($metric in [regex]::Matches($line.Value,'(\w+)=(\d+)')) {
                    $metrics[$metric.Groups[1].Value] = [int]$metric.Groups[2].Value
                }
            }
            if ($metrics.aw_captures -ne ($metrics.commits+$metrics.reset_aw) -or
                $metrics.w_captures -ne ($metrics.commits+$metrics.reset_w) -or
                $metrics.commits -ne ($metrics.write_responses+$metrics.reset_b) -or
                $metrics.ar_captures -ne ($metrics.read_responses+$metrics.reset_r) -or
                $metrics.reset_discarded -ne 3*($configuration.InputDepth+$configuration.OutputDepth+2)) {
                throw "Accelerator stream/AXI conservation mismatch: $runName"
            }
            if ($metrics.seed -ne $seed -or $metrics.random_samples -lt $configuration.Samples -or
                $metrics.writes -ne $comparison.inputs -or $metrics.reads -ne $comparison.outputs -or
                $metrics.reset_discarded -ne $comparison.reset_discarded -or
                $metrics.history_clears -ne $comparison.history_clears -or
                $comparison.saturation_checks -ne $comparison.outputs -or $comparison.status -ne 'passed') {
                throw "Accelerator result accounting mismatch for seed $seed"
            }
            $expectedConfig = @{
                taps=$configuration.Taps; input_width=$configuration.InputWidth
                coeff_width=$configuration.CoeffWidth; output_width=$configuration.OutputWidth
                input_frac=$configuration.InputFrac; coeff_frac=$configuration.CoeffFrac
                output_frac=$configuration.OutputFrac
            }
            foreach ($key in $expectedConfig.Keys) {
                if ($metrics[$key] -ne $expectedConfig[$key] -or $comparison.config.$key -ne $expectedConfig[$key]) {
                    throw "Accelerator configuration mismatch: $runName / $key"
                }
            }
            if ($metrics.input_depth -ne $configuration.InputDepth -or $metrics.output_depth -ne $configuration.OutputDepth -or
                $metrics.max_pending -ne ($configuration.InputDepth + $configuration.OutputDepth + 2)) {
                throw 'Accelerator FIFO configuration/capacity mismatch'
            }
            $metrics['python_status'] = $comparison.status
            $metrics['log'] = $logPath
            $metrics['events'] = $eventsPath
            $results.Add([pscustomobject]$metrics)
            Write-Output $passLine.Value
            Write-Output "PASS: Python data/saturation comparison seed=$seed outputs=$($comparison.outputs)"
        }
    }
    $passed = $true
    Write-Output "Accelerator regression passed: $($results.Count) runs. Results: $outputPath/results.json"
} finally {
    # Always record partial progress on failure and restore the caller's directory.
    # Byte hashes identify the exact sources used; even later comment edits will
    # change these hashes without changing the simulated hardware behavior.
    $report = [ordered]@{
        status = $(if ($passed) { 'passed' } else { 'failed' })
        fifo_sha256 = (Get-FileHash -LiteralPath $fifoPath -Algorithm SHA256).Hash
        core_sha256 = (Get-FileHash -LiteralPath $corePath -Algorithm SHA256).Hash
        datapath_sha256 = (Get-FileHash -LiteralPath $datapathPath -Algorithm SHA256).Hash
        regs_sha256 = (Get-FileHash -LiteralPath $regsPath -Algorithm SHA256).Hash
        rtl_sha256 = (Get-FileHash -LiteralPath $rtlPath -Algorithm SHA256).Hash
        testbench_sha256 = (Get-FileHash -LiteralPath $tbPath -Algorithm SHA256).Hash
        model_sha256 = (Get-FileHash -LiteralPath (Join-Path $projectRoot 'model/fir.py') -Algorithm SHA256).Hash
        comparator_sha256 = (Get-FileHash -LiteralPath $comparisonPath -Algorithm SHA256).Hash
        runs = @($results.ToArray())
    }
    [System.IO.File]::WriteAllText((Join-Path $outputPath 'results.json'),
        ($report | ConvertTo-Json -Depth 6) + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false))
    Pop-Location
}
