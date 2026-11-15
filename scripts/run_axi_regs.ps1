# Unit regression for the AXI4-Lite register bank. No Python arithmetic replay
# is needed here: the bench models the register map, byte masks and bus ordering.
param(
    [string]$VivadoBin = '',
    [int[]]$Seeds = @(1..20),
    [ValidateRange(1,100000)][int]$Transactions = 2000,
    [ValidateRange(1,100000)][int]$SmokeTransactions = 500,
    [switch]$SkipSmoke
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if ($Seeds.Count -eq 0 -or @($Seeds | Where-Object { $_ -le 0 }).Count -gt 0) {
    throw 'Provide at least one positive seed.'
}
$simTools = @{}
foreach ($name in @('xvlog','xelab','xsim')) {
    if ($VivadoBin) {
        $path = Join-Path $VivadoBin ($name + '.bat')
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing tool: $path" }
        $simTools[$name] = (Resolve-Path -LiteralPath $path).Path
    } else { $simTools[$name] = (Get-Command ($name + '.bat') -ErrorAction Stop).Source }
}
$rtlPath = Join-Path $projectRoot 'fpga_streaming_dsp/fpga_streaming_dsp.srcs/sources_1/new/axi_lite_regs.v'
$tbPath = Join-Path $projectRoot 'fpga_streaming_dsp/fpga_streaming_dsp.srcs/sim_1/tb_axi_lite_regs.sv'
$outputPath = Join-Path $projectRoot 'build/axi_regs_sim'
New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
$configurations = @([pscustomobject]@{Taps=8; Width=16; Seeds=$Seeds; Transactions=$Transactions})
if (-not $SkipSmoke) {
    # Narrow byte field, partial second byte, full 32-bit word and maximum map.
    foreach ($dimensions in @(@(1,8),@(4,10),@(8,32),@(32,16))) {
        $configurations += [pscustomobject]@{
            Taps=$dimensions[0]; Width=$dimensions[1]; Seeds=@(1,7,42); Transactions=$SmokeTransactions
        }
    }
}
$results = [System.Collections.Generic.List[object]]::new()
$passed = $false
Push-Location -LiteralPath $outputPath
try {
    & $simTools['xvlog'] $rtlPath
    if ($LASTEXITCODE -ne 0) { throw 'AXI register RTL compile failed.' }
    & $simTools['xvlog'] -sv $tbPath
    if ($LASTEXITCODE -ne 0) { throw 'AXI register testbench compile failed.' }
    foreach ($cfg in $configurations) {
        $snapshot = "regs_t$($cfg.Taps)_w$($cfg.Width)"
        @(
            ('-generic_top "TAPS={0}"' -f $cfg.Taps)
            ('-generic_top "COEFF_WIDTH={0}"' -f $cfg.Width)
            ('-s {0}' -f $snapshot)
            '-debug typical'
            ('-log {0}.elaborate.log' -f $snapshot)
        ) | Set-Content -LiteralPath "$snapshot.elaborate.txt" -Encoding ASCII
        & $simTools['xelab'] work.tb_axi_lite_regs -f "$snapshot.elaborate.txt"
        if ($LASTEXITCODE -ne 0) { throw "AXI register elaboration failed: $snapshot" }
        foreach ($seed in $cfg.Seeds) {
            $run = "${snapshot}_seed$seed"
            @(
                '-runall'
                ('-testplusarg "SEED={0}"' -f $seed)
                ('-testplusarg "TRANSACTIONS={0}"' -f $cfg.Transactions)
                ('-log {0}.log' -f $run)
            ) | Set-Content -LiteralPath "$run.options.txt" -Encoding ASCII
            # Never accept stale PASS text after a failed invocation.
            [System.IO.File]::WriteAllText((Join-Path $outputPath "$run.log"),'')
            & $simTools['xsim'] $snapshot -f "$run.options.txt" | Out-File "$run.console.log" -Encoding UTF8
            if ($LASTEXITCODE -ne 0) { throw "AXI register simulation failed: $run" }
            $logText = Get-Content -LiteralPath "$run.log" -Raw
            $passLine = [regex]::Match($logText,'(?m)^PASS: axi_lite_regs .*')
            if ($logText -match '(?im)^\s*(fatal|error)\s*:' -or -not $passLine.Success) {
                Get-Content -LiteralPath "$run.log" -Tail 25 | Write-Output
                throw "AXI register bench failed: $run"
            }
            $metrics = [ordered]@{}
            foreach ($metric in [regex]::Matches($passLine.Value,'(\w+)=(\d+)')) {
                $metrics[$metric.Groups[1].Value] = [int]$metric.Groups[2].Value
            }
            $accounting = [regex]::Match($logText,'(?m)^ACCOUNTING: .*')
            if (-not $accounting.Success) { throw "Missing AXI accounting: $run" }
            foreach ($metric in [regex]::Matches($accounting.Value,'(\w+)=(\d+)')) {
                $metrics[$metric.Groups[1].Value] = [int]$metric.Groups[2].Value
            }
            if ($metrics.aw_captures -ne ($metrics.commits+$metrics.reset_aw) -or
                $metrics.w_captures -ne ($metrics.commits+$metrics.reset_w) -or
                $metrics.commits -ne ($metrics.write_responses+$metrics.reset_b) -or
                $metrics.ar_captures -ne ($metrics.read_responses+$metrics.reset_r)) {
                throw "AXI channel accounting mismatch: $run"
            }
            if ($metrics.taps -ne $cfg.Taps -or $metrics.coeff_width -ne $cfg.Width -or
                $metrics.seed -ne $seed -or $metrics.random_transactions -ne $cfg.Transactions) {
                throw "AXI register configuration mismatch: $run"
            }
            foreach ($coverage in @('aw_first','w_first','simultaneous','errors','b_stalls','r_stalls',
                'overlapping_reads_writes','history_clears','soft_clears','coefficient_writes',
                'blocked_aw','blocked_w','blocked_ar')) {
                if ($metrics[$coverage] -le 0) { throw "Missing scenario: $run / $coverage" }
            }
            $metrics['log'] = "$run.log"
            $results.Add([pscustomobject]$metrics)
            Write-Output $passLine.Value
        }
    }
    $passed = $true
    Write-Output "AXI register regression passed: $($results.Count) runs. Results: $outputPath/results.json"
} finally {
    $report = [ordered]@{
        status = $(if ($passed) {'passed'} else {'failed'})
        rtl_sha256 = (Get-FileHash -LiteralPath $rtlPath -Algorithm SHA256).Hash
        testbench_sha256 = (Get-FileHash -LiteralPath $tbPath -Algorithm SHA256).Hash
        runs = @($results.ToArray())
    }
    [System.IO.File]::WriteAllText((Join-Path $outputPath 'results.json'),
        ($report | ConvertTo-Json -Depth 6) + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false))
    Pop-Location
}
