# Python Backend and Web Console

Software delivery: **v1.1.0**. Unified local acceptance covers the model,
backend, reference/RTL browser flows, recovery and request-driven simulation.
The [frozen delivery evidence](../reports/delivery/v1.1.0/README.md) retains both
local acceptance profiles and their phase logs.

The software increment implements reference processing and request-driven RTL
simulation through
[the Web interface contract](web_interface.md). The existing hardware and its
`v1.0.0` evidence are unchanged. Without a configured Vivado directory,
capabilities report RTL unavailable, the UI disables it and submission returns
503 `MODE_UNAVAILABLE`. With valid configuration, the server runs the actual
submitted coefficients and CSV through XSim, with no fallback to Python.

## Start

From the repository root, with Python 3.10+ (tested: Python 3.13.0):

```powershell
python -m webapp.server
```

On the development machine, use the working interpreter explicitly:

```powershell
& 'H:/2025.1/tps/win64/python-3.13.0/python.exe' -m webapp.server
```

To enable real RTL jobs on the development machine:

```powershell
& 'H:/2025.1/tps/win64/python-3.13.0/python.exe' -m webapp.server --vivado-bin 'E:/2026.1/Vivado/bin'
```

Alternatively set `FIR_VIVADO_BIN` for the server process. The adapter checks
that all three simulation tools and its bench/runner sources exist. Actual tool
execution errors still fail the job; a capability check is not a fake simulation.

Open **http://127.0.0.1:8000**. The runtime uses only Python's standard library;
there are no frontend build steps, external fonts, CDN assets or backend package
dependencies. RTL mode additionally requires Windows PowerShell and Vivado
(`xvlog.bat`, `xelab.bat`, `xsim.bat`); tested: Vivado 2026.1. Stop a foreground
server with Ctrl+C.

Options: `--port 8001`, `--data-dir build/webapp-other` and
`--reference-timeout 30` / `--rtl-timeout 300`. The service binds only to loopback. One server may own
a data directory at a time; use a separate directory for independent instances.

Use the Example CSV download or create a UTF-8 file:

```csv
sample
16384
-16384
1
```

Upload it, retain the half-gain preset `[16384,0,0,0,0,0,0,0]`, and click Run
filter. Expected outputs are `[8192,-8192,0]` with no saturated results. The
browser displays the server result as a plot and a paginated exact-value table;
CSV downloads come from that same stored result. All values are signed raw
Q1.15 integers. Model compute time is not FPGA performance.

Job IDs are retained in the page URL. Refresh reloads the dataset, coefficients,
state and completed result without submitting another job. Network lookup
failures expose a retry action. Unknown jobs and validation/worker errors display
their stable error codes. Invalid coefficients disable submission and identify
the offending field. RTL mode shows `vivado-xsim` only after actual tool execution
and successful comparison, never a fictitious successful result.

## Implementation

- [service.py](../webapp/service.py): strict CSV/request validation, immutable
  datasets, SQLite persistence, FIFO queue and one worker coordinator.
- [server.py](../webapp/server.py): bounded HTTP request parsing, JSON error
  envelopes, API routing and a fixed allowlist of static assets.
- [static/](../webapp/static): plain HTML/CSS/JavaScript using the agreed
  `data-testid` selectors, server-state polling, canvas plot and accessible table.
- [rtl_runner.py](../webapp/rtl_runner.py), [request bench](../webapp/rtl/tb_web_fir.sv)
  and [PowerShell runner](../scripts/run_web_rtl.ps1): private immutable source
  snapshots, real AXI4-Lite configuration/readback, concurrent stream traffic,
  count/status checks and independent Python comparison of data AND flags.

Each accepted job starts a new process with a fresh `FirModel`; no filter history
is shared between jobs. The worker writes an atomic private JSON result file.
The coordinator monitors the process against a deadline, terminates it on
timeout, and publishes the result in SQLite only after successful completion.
This avoids blocking result-pipe reads during Windows process startup/termination.
Large HTTP uploads are drained for a bounded interval before rejection so a
Windows socket reset does not mask the expected 413 response. Idle HTTP
connections have a timeout so browser preconnections cannot block server exit.

Default state is in `build/webapp/`: `service.sqlite3`, an OS-held ownership lock,
and private per-job files. On restart, unfinished queued/running jobs become
failed with `SERVER_RESTART`; terminal results remain readable. There is no
cancellation, authentication or external binding in this local single-user increment.

RTL jobs run in their own `runs/{job_id}` directory. The bench receives only
input/coefficient memory files and a sample count, not expected outputs. It
exports the actual accepted inputs and outputs, and observes the existing
internal per-result saturation flag without forcing DUT state. Source/outputs
are snapshotted and hashed. Compile and simulation logs, handshake traces,
comparison results and `evidence.json` remain in the job directory. Tool
deadlines terminate this job's owned process tree, without killing other Vivado
sessions. Failed or timed-out jobs cannot download partial results.

`rtl_cycles` measures the inclusive span from first accepted input to last
accepted output, including intentional source gaps/output stalls. It excludes
configuration and final drain/readback checks. RTL wall time includes compilation,
simulation and comparison, not board processing time. No FPGA board is used.

## Tests

After installing the optional Selenium dependency below, use one entry point:

```powershell
python scripts/run_web_tests.py
python scripts/run_web_tests.py --rtl --vivado-bin 'E:/2026.1/Vivado/bin'
```

The first command is the **reference-only CI profile**: 27 model tests,
14 backend/evidence tests and 11 Selenium tests; no Vivado installation is
required. The second is the **full-rtl profile**: the same model/backend checks,
14 Selenium tests and the real RTL HTTP matrix. The runner freezes source hashes,
checks exit codes, exact test counts, RTL snapshots/artifacts and source stability,
then archives its summary and phase logs under `reports/web/` (full) or
`reports/web/reference/` (reference-only). Failed runs retain diagnostics
under `build/web_validation/{profile}/` without publishing a new passing report.

Backend tests use real loopback HTTP requests and temporary persisted stores:

```powershell
python -m unittest discover -s web_tests -v
python -m unittest discover -s tests -v
```

Recorded results: **14 backend/lifecycle/evidence-parser tests** and the **27 existing Python
reference tests** passed. Backend coverage includes actual processing and CSV
downloads, reload from disk, strict inputs, unavailable RTL, maximum-size
datasets, queue limits, exclusive ownership, restart reconciliation and explicitly
fault-injected timeout/crash workers. Fault injection is test-only; there is no
public endpoint for selecting an arbitrary worker or tool command.
Negative parser cases reject wrong accepted inputs, altered data or flags,
missing outputs and duplicate output indices; these synthetic fixtures are
explicitly separate from real simulation acceptance.

Selenium is optional and needed only for browser tests:

```powershell
python -m pip install --target build/web_test_deps -r web_tests/requirements.txt
python web_tests/browser_acceptance.py
python web_tests/browser_acceptance.py --rtl --vivado-bin 'E:/2026.1/Vivado/bin'
python web_tests/rtl_acceptance.py --vivado-bin 'E:/2026.1/Vivado/bin'
```

The script uses an installed Edge browser and a temporary isolated browser
profile. [Selenium Manager](https://www.selenium.dev/documentation/selenium_manager/)
resolves a matching driver; its cache is placed under `build/selenium_cache/`
unless overridden by the environment. First execution may require network
access for driver download. The tested Selenium dependency is pinned in
[requirements.txt](../web_tests/requirements.txt).

The default **11 Selenium tests** exercise real reference processing, upload errors,
coefficient validation, refresh without rerun, an actual downloaded CSV, disabled
RTL selection, pagination, a 390px emulated viewport, unknown job recovery, and
an explicitly injected worker timeout. Tests use condition waits; backend FIR
processing is not mocked in the successful flow. Recovery cases use a test-only
timing gate around the real reference worker: refreshing while running keeps one
job, and restarting the HTTP/storage/worker components fails running/queued work
while preserving an earlier completed result.

With `--rtl`, **14 Selenium tests** pass. The three additional cases exercise
actual RTL saturation/refresh/download, two jobs with changed coefficients, and
a real native-process timeout. The dedicated RTL HTTP matrix passes eight
successful jobs (11,353 data/flag comparisons, including 10,000 samples in one
request) plus an intentionally timed-out ninth job. Cases include negative
rounding, impulse order, zero coefficients, both clipping signs, signed extrema,
random seeds and different coefficients for the same data.

Screenshots, captured page HTML, downloaded CSVs and the JSON report with browser
version and executed source hashes are under `build/web_e2e/`. Run backend tests
before browser tests when editing the service. The RTL HTTP matrix retains its
summary and per-case results under `build/web_rtl_acceptance/`, with raw job
files under `state/runs/`. Selenium preserves selected RTL job logs and source
snapshots under `build/web_e2e/rtl_jobs/`. Neither suite reruns or replaces
the hardware's historical 285-run acceptance evidence.

## Continuous Integration

[web-tests.yml](../.github/workflows/web-tests.yml) runs the reference-only
profile on GitHub-hosted Windows for pushes, pull requests and manual dispatch.
It installs Python 3.13 and the pinned Selenium dependency, uses Edge, and uploads
logs, screenshots, page HTML and result JSON even after failure. It has read-only
repository permissions and does not require or claim Vivado execution.
Run the full profile locally or on a suitably provisioned trusted runner.
