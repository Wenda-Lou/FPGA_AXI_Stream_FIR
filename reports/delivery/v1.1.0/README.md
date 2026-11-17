# v1.1.0 Software Acceptance

The Web console uses a persistent Python service and actual request-driven XSim.

- [Full local acceptance](web/summary.json): 27 Python model tests, 14 backend /
  evidence-parser tests, 14 Selenium tests, eight successful RTL HTTP requests
  matching 11,353 outputs and flags, and a deliberately timed-out native job.
- [Reference-only acceptance](web/reference/summary.json): 27 / 14 / 11 tests,
  using the same command configured for hosted CI, with no Vivado requirement.
- [Selenium evidence](web/selenium_results.json): actual Edge version, source
  hashes and real RTL job records. The reference timeout uses an explicitly
  injected slow worker. Refresh/restart recovery uses a gated real reference
  worker and restarts HTTP/storage/worker components on the same workstation.
- [RTL matrix](web/rtl_acceptance.json): exact-request interface simulation,
  signed arithmetic, both clipping signs, random data, 10,000-sample transfer,
  changed coefficients and a real process-tree timeout.

Run `python scripts/run_web_tests.py --rtl --vivado-bin YOUR_VIVADO_BIN` from the
repository root after installing `web_tests/requirements.txt`. Omit RTL options
for the reference-only profile. Raw screenshots, page HTML and job traces remain
under `build/`. Summaries and phase logs here are preserved byte-for-byte.

This archive records locally observed execution. The GitHub workflow is defined
in `.github/workflows/web-tests.yml`; its hosted result is separate from these
local measurements. There is no board execution, new physical timing result or
change to the delivered v1.0.0 hardware RTL.
