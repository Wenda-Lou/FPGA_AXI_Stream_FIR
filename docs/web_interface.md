# Web Control and Verification Interface — v1

Status: the reference HTTP backend, Web UI and request-driven XSim worker are
implemented; see [startup and tests](webapp.md). RTL is available only when the
server is configured with a valid Vivado tool directory. The delivered hardware
`v1.0.0` remains unchanged.
This contract is independent of the choice of Python HTTP framework.

## Scope and Numerical Contract

Local single-user service, bound to loopback, with one background worker.
The first Web version fixes eight taps, signed 16-bit Q1.15 input/coefficient/
output values and 16-entry FIFOs. The UI/API use **raw signed integers**, not
floating-point real numbers: `16384` means 0.5; `32768` is invalid.

Exactly eight coefficients are required; coefficient zero multiplies the newest
sample. Inputs and coefficients must be integers in [-32768, 32767]. JSON
booleans, numeric strings, floats, nulls and unknown fields are rejected.
Full products and the 35-bit accumulator are retained; arithmetic right shift
by 15 rounds toward negative infinity, then saturates to [-32768, 32767].

Each job starts a fresh history epoch and produces exactly one output per input,
with no implicit FIR-tail samples. Jobs never share filter state. The existing
[Python model](../model/fir.py) defines arithmetic; the existing
[register contract](axi_lite_regs.md) defines legal RTL control sequences.

## Data Upload

`POST /api/v1/datasets` accepts `multipart/form-data` with exactly one file part
named `file`. Its content must be UTF-8 CSV (optional UTF-8 BOM), with the exact
header `sample` and one decimal signed integer per following row. LF/CRLF are
accepted; a final newline is optional. Blank data rows, additional columns,
hexadecimal notation, exponent notation and missing values are rejected.
Surrounding spaces around a data value are trimmed before parsing. Decimal
tokens match `[+-]?[0-9]+`; leading zeros do not change decimal interpretation.

Limits: 1–10,000 samples, 1 MiB file content, 2 MiB total HTTP request body.
The filename is display metadata; it is not a server path. The server persists
an immutable parsed dataset, returning `201 Created` and a `Location` header:

```json
{
  "dataset_id": "ds_example",
  "sample_count": 3,
  "format": "signed-int16-q1.15",
  "sha256": "SHA256_OF_CANONICAL_SAMPLE_BYTES"
}
```

Canonical sample bytes are ASCII decimal values, one per line with LF and a
final LF; values are re-encoded from parsed integers. Thus BOM, line endings,
leading zeros and accepted spaces do not affect the dataset digest.

`GET /api/v1/datasets/{dataset_id}` returns the same metadata (200), or 404.
No deletion or editing API is provided in this increment.

## Capabilities and Job Submission

`GET /api/v1/capabilities` returns 200 with `api_version: "1"`, fixed format and
limits, and `modes.reference` / `modes.rtl`. Each mode has `available` (boolean)
and `reason` (null or a stable error code). The UI disables an unavailable mode.
An installed Vivado executable alone is insufficient to advertise RTL mode:
the request-driven worker must also exist and pass its availability check.

`POST /api/v1/jobs` accepts `application/json`:

```json
{
  "mode": "reference",
  "dataset_id": "ds_example",
  "coefficients": [16384, 0, 0, 0, 0, 0, 0, 0]
}
```

`mode` is exactly `reference` or `rtl`. All three fields are required; there are
no implicit coefficients, modes or caller-supplied tool paths/commands. Validate
the whole request, dataset and mode availability before allocating a job.

Accepted submission returns `202 Accepted`, `Location: /api/v1/jobs/job_example`
and a complete job-status object. Every accepted POST creates a new job;
automatic POST retries are not supported. The UI disables duplicate submission
while its request is in flight and retains the returned job ID.

At most eight jobs may be queued, in addition to the one running job. A full
queue returns 429 without allocating a job. The worker processes FIFO order.
Dataset and coefficient snapshots are immutable for the job's lifetime.

## Job State and Refresh Behavior

`GET /api/v1/jobs/{job_id}` returns 200 for any known state:

```json
{
  "job_id": "job_example",
  "mode": "reference",
  "dataset_id": "ds_example",
  "coefficients": [16384, 0, 0, 0, 0, 0, 0, 0],
  "state": "queued",
  "created_at": "2026-11-16T12:00:00Z",
  "started_at": null,
  "finished_at": null,
  "progress": null,
  "result_url": null,
  "error": null
}
```

The timestamp above is illustrative. All timestamps are UTC ISO 8601.

Allowed transitions:

```text
queued -> running -> succeeded | failed | timed_out
queued -> failed                   (e.g. restart reconciliation)
```

Terminal states never revert. `started_at` is set on worker start;
`finished_at` is set on every terminal transition. Queue failure can retain
null `started_at`. `progress` is null in v1: the UI displays an indeterminate
indicator, not a fabricated percentage. `result_url` is populated only on
success. `error` is non-null only in failed/timed_out states.

The UI stores the job ID in its route/query string and reloads state through
GET after a page refresh. Polling should be approximately once per second and
stop at a terminal state. Browser/Selenium waits use state conditions and a
bounded deadline rather than fixed sleeps as proof of completion.

Persist datasets, requests and terminal results on disk. On server startup,
previous queued/running jobs become failed with `SERVER_RESTART`; do not claim
they completed or automatically repeat them. Terminal jobs remain readable.
Cancellation and multi-user scheduling are outside this increment.

## Result and Download

`GET /api/v1/jobs/{job_id}/result` returns 200 only for a succeeded job:

```json
{
  "job_id": "job_example",
  "mode": "reference",
  "format": "signed-int16-q1.15",
  "input_count": 3,
  "output_count": 3,
  "inputs": [16384, -16384, 1],
  "outputs": [8192, -8192, 0],
  "saturated": [false, false, false],
  "saturation_count": 0,
  "verification": {
    "status": "not_applicable",
    "compared_outputs": 0,
    "mismatches": null
  },
  "metrics": {
    "worker_elapsed_ms": 1.0,
    "rtl_cycles": null,
    "clock_period_ns": null
  },
  "execution": {
    "engine": "python-reference",
    "run_id": "run_example",
    "tool_version": null
  }
}
```

The elapsed time and IDs are illustrative, not measured. A reference result is
computed by the golden model, so it cannot claim independent verification.
For RTL success, `engine` is `vivado-xsim`, `tool_version` is recorded,
`verification.status` is `passed`, `compared_outputs` equals input_count,
`mismatches` is zero and `clock_period_ns` is 10. `rtl_cycles` is the inclusive
interval from the first accepted stream input through the last accepted output,
including stalls but excluding AXI configuration and final readback/drain checks.
Do not infer cycles from wall-clock time. For RTL, `worker_elapsed_ms` includes
source snapshotting, compilation, simulation and comparison; reference mode
reports model compute time. Execution metadata additionally records hardware
source snapshot and artifact SHA-256 hashes.

Arrays have identical length and are ordered by accepted sample index.
`saturation_count` equals the number of true entries. Timing metrics are software
elapsed time / behavioral simulation observations, not board throughput.

While queued/running, the result endpoint returns 409 `RESULT_NOT_READY`.
For failed/timed_out jobs it returns 409 `JOB_NOT_SUCCEEDED`; diagnostics are in
the job error. An unknown job always returns 404.

`GET /api/v1/jobs/{job_id}/result.csv` uses the same readiness/error rules,
returning `text/csv; charset=utf-8` and an attachment filename
`fir-{job_id}.csv` on success. Its exact columns are:

```text
sample_index,input_raw,output_raw,saturated
0,16384,8192,0
1,-16384,-8192,0
2,1,0,0
```

Use zero-based indices, decimal integers, 0/1 flags and LF line endings. The
download and the chart/table must use the same stored result, not rerun the job.

## Errors and Execution Deadlines

Every non-2xx HTTP response uses this envelope:

```json
{
  "error": {
    "code": "COEFFICIENT_OUT_OF_RANGE",
    "message": "Coefficient must be between -32768 and 32767.",
    "field": "coefficients[2]",
    "request_id": "req_example"
  }
}
```

`field` may be null. Tests match code/field, not localized message text. Failed
job status uses the same error object under its `error` field. Internal paths,
subprocess commands and stack traces belong in server logs, correlated by IDs.

| HTTP | Stable error codes / conditions |
| --- | --- |
| 400 | `INVALID_CSV`, `INVALID_JSON` (malformed content) |
| 413 | `UPLOAD_TOO_LARGE` (file/body limit) |
| 415 | `UNSUPPORTED_MEDIA_TYPE` |
| 422 | `INVALID_REQUEST`, `INVALID_COEFFICIENT_COUNT`, `COEFFICIENT_OUT_OF_RANGE`, `SAMPLE_OUT_OF_RANGE`, `INVALID_SAMPLE_COUNT` |
| 404 | `DATASET_NOT_FOUND`, `JOB_NOT_FOUND` |
| 409 | `RESULT_NOT_READY`, `JOB_NOT_SUCCEEDED` |
| 429 | `QUEUE_FULL` |
| 503 | `MODE_UNAVAILABLE` |
| 500 | `INTERNAL_ERROR` |

Worker deadlines start at `running`, excluding queue time: reference 30 s,
RTL 300 s, configurable by the server only. Timeout terminates the worker's own
job processes, records `EXECUTION_TIMEOUT` and sets timed_out. Other asynchronous
codes include `EXECUTION_FAILED`, `RTL_MISMATCH`, `RTL_PROTOCOL_ERROR`,
`RTL_OUTPUT_COUNT_MISMATCH` and `SERVER_RESTART`. A successful tool exit alone
does not establish success. Failed jobs never expose partial data as a result.

## Worker Boundary: Reference Versus Real RTL

Both workers consume the same parsed sample list, eight coefficients and fixed
format; both return ordered data/flags and execution identity.

The reference worker creates a fresh `FirModel`, programs all coefficients and
processes the requested samples. It must not read a previous job's output.

The RTL worker uses the [request-driven bench](../webapp/rtl/tb_web_fir.sv),
separate from the existing preset regression suite. It performs these steps:

1. Hardware-reset a fresh DUT; confirm disabled/idle.
2. Write the eight requested coefficients through actual AXI4-Lite transactions;
   require OKAY responses and check coefficient readback.
3. Legally soft-clear while disabled/idle, then enable ingress.
4. Drive the submitted samples through AXI4-Stream and receive outputs
   concurrently, accounting only real handshakes and enforcing bounded waits.
5. Disable, drain, confirm idle and input/output counts; no reset-discarded data
   is allowed in an ordinary Web processing job.
6. Compare every returned output AND saturation flag with a separately executed
   Python oracle for that exact request. Preserve tool logs and source hashes.

Emit raw arithmetic data to private job files, never use oracle expected outputs
as the reported RTL result. A mismatch fails the job. Never silently fall back
to reference mode when RTL is unavailable or fails. Re-running the existing
47-test suite is not execution of a user's uploaded dataset.

## Frontend and Selenium Agreement

Use stable `data-testid` attributes:

| Element | Test ID |
| --- | --- |
| Mode selector | `mode-select` |
| Eight coefficient fields | `coefficient-0` through `coefficient-7` |
| CSV file input / upload action | `sample-upload` / `upload-dataset` |
| Accepted sample count | `sample-count` |
| Submit action | `submit-job` |
| Task identity / state | `job-id` / `job-status` |
| Execution engine | `execution-engine` |
| Input/form/worker error | `error-message` |
| Plot / accessible result table | `output-chart` / `result-table` |
| Saturation count / download | `saturation-count` / `download-results` |

`job-status` exposes `data-state` with the exact state enum. `error-message`
exposes `data-code`. The submit button remains disabled until a dataset and
valid coefficients/mode exist; it is also disabled during submission and while
the displayed job is active. Backend validation remains authoritative.

The browser renders only authoritative server state; it must not display
"verified" for reference mode. Selenium exercises a real HTTP backend, checks
numeric table/download contents rather than chart pixels, and waits for state
transitions. Mock-worker tests must be labeled separately from real RTL tests.

## First Implementation Acceptance

Capabilities, upload, reference jobs, polling, download and the real RTL adapter
are implemented. Without server-side Vivado configuration, RTL remains
unavailable. Shared tests cover malformed uploads, strict types/ranges, unknown
IDs, unavailable modes, queue bounds, readiness and restart semantics. Selenium
also covers actual RTL jobs, changed coefficients, refresh/download consistency
and a real native-process timeout. Real RTL acceptance compares the exact
submitted inputs and every output/flag without changing this public API.
