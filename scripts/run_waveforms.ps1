# Recompile the unchanged top/bench in an isolated directory, capture a real VCD
# and render selected rising-edge samples. No GUI or Python packages required.
param([string]$VivadoBin = '', [string]$Python = 'python')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$outputPath = Join-Path $projectRoot 'build/waveforms'
New-Item -ItemType Directory -Force -Path $outputPath | Out-Null
Copy-Item -LiteralPath (Join-Path $projectRoot 'scripts/capture_waveforms.tcl') -Destination (Join-Path $outputPath 'capture_waveforms.tcl') -Force
$simTools = @{}
foreach ($name in @('xvlog','xelab','xsim')) {
    if ($VivadoBin) { $simTools[$name] = Join-Path $VivadoBin ($name + '.bat') }
    else { $simTools[$name] = (Get-Command ($name + '.bat') -ErrorAction Stop).Source }
    if (-not (Test-Path -LiteralPath $simTools[$name] -PathType Leaf)) { throw "Missing tool: $name" }
}
$rtlDir = Join-Path $projectRoot 'fpga_streaming_dsp/fpga_streaming_dsp.srcs/sources_1/new'
$bench = Join-Path $projectRoot 'fpga_streaming_dsp/fpga_streaming_dsp.srcs/sim_1/tb_dsp_accelerator.sv'
Push-Location -LiteralPath $outputPath
try {
    & $simTools['xvlog'] (Join-Path $rtlDir 'axis_fifo.v') (Join-Path $rtlDir 'fir_core.v') (Join-Path $rtlDir 'dsp_datapath.v') (Join-Path $rtlDir 'axi_lite_regs.v') (Join-Path $rtlDir 'dsp_accelerator.v') | Out-File compile.console.log -Encoding UTF8
    if ($LASTEXITCODE -ne 0) { throw 'Waveform RTL compilation failed.' }
    & $simTools['xvlog'] -sv $bench | Out-File bench.console.log -Encoding UTF8
    if ($LASTEXITCODE -ne 0) { throw 'Waveform bench compilation failed.' }
    & $simTools['xelab'] work.tb_dsp_accelerator -debug typical -s waveform_snapshot | Out-File elaborate.console.log -Encoding UTF8
    if ($LASTEXITCODE -ne 0) { throw 'Waveform elaboration failed.' }
    @(
        '-tclbatch capture_waveforms.tcl'
        '-testplusarg "SEED=1"'
        '-testplusarg "SAMPLES=1000"'
        '-testplusarg "EVENTS=waveform.events.txt"'
        '-log "waveform.log"'
    ) | Set-Content -LiteralPath waveform.options.txt -Encoding ASCII
    # Truncate stale evidence before invoking the simulator.
    foreach ($name in @('waveform.log','accelerator.vcd','waveform.events.txt')) {
        [System.IO.File]::WriteAllText((Join-Path $outputPath $name), '')
    }
    & $simTools['xsim'] waveform_snapshot -f waveform.options.txt | Out-File simulation.console.log -Encoding UTF8
    if ($LASTEXITCODE -ne 0) { throw 'Waveform simulation failed.' }
    $logText = Get-Content -LiteralPath waveform.log -Raw
    if ($logText -match '(?im)^\s*(fatal|error)\s*:' -or $logText -notmatch '(?m)^PASS: dsp_accelerator ') { throw 'Waveform self-checks did not pass.' }
    & $Python (Join-Path $projectRoot 'scripts/compare_fir_events.py') --events waveform.events.txt --summary python.json
    if ($LASTEXITCODE -ne 0) { throw 'Waveform Python comparison failed.' }
} finally { Pop-Location }
& $Python (Join-Path $projectRoot 'scripts/render_waveforms.py')
if ($LASTEXITCODE -ne 0) { throw 'Waveform validation/rendering failed.' }
