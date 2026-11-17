# SourcesDir and JobDir are server-generated private snapshots, never HTTP paths.
param(
    [Parameter(Mandatory=$true)][string]$VivadoBin,
    [Parameter(Mandatory=$true)][string]$SourcesDir,
    [Parameter(Mandatory=$true)][string]$JobDir,
    [ValidateRange(1,10000)][int]$Count
)
$ErrorActionPreference = 'Stop'
Push-Location -LiteralPath $JobDir
try {
    & (Join-Path $VivadoBin 'xvlog.bat') (Join-Path $SourcesDir 'axis_fifo.v') (Join-Path $SourcesDir 'fir_core.v') (Join-Path $SourcesDir 'dsp_datapath.v') (Join-Path $SourcesDir 'axi_lite_regs.v') (Join-Path $SourcesDir 'dsp_accelerator.v') | Out-File compile.rtl.console.log -Encoding UTF8
    if ($LASTEXITCODE -ne 0) { throw 'RTL compilation failed.' }
    & (Join-Path $VivadoBin 'xvlog.bat') -sv (Join-Path $SourcesDir 'tb_web_fir.sv') | Out-File compile.bench.console.log -Encoding UTF8
    if ($LASTEXITCODE -ne 0) { throw 'Request bench compilation failed.' }
    & (Join-Path $VivadoBin 'xelab.bat') work.tb_web_fir -debug typical -s web_request | Out-File elaborate.console.log -Encoding UTF8
    if ($LASTEXITCODE -ne 0) { throw 'Request bench elaboration failed.' }
    @('-runall',('-testplusarg "COUNT={0}"' -f $Count),'-log "simulation.log"') | Set-Content -LiteralPath options.txt -Encoding ASCII
    & (Join-Path $VivadoBin 'xsim.bat') web_request -f options.txt | Out-File simulate.console.log -Encoding UTF8
    if ($LASTEXITCODE -ne 0) { throw 'Request simulation failed.' }
    $logText = Get-Content -LiteralPath simulation.log -Raw
    if ($logText -match '(?im)^\s*(fatal|error)\s*:' -or $logText -notmatch '(?m)^PASS: web_request ') { throw 'Request simulation checks failed.' }
} finally { Pop-Location }
