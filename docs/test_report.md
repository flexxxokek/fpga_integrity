# Test Report — FPGA Integrity Module

**Date:** 2026-11-21
**Command:** `make sim` → `python tb/run_tests.py --mode all --widths 8,32,64`
**Result:** PASS (process exit code 0, `All tests passed.`)

## 1. Environment

| Component | Version |
|-----------|---------|
| Verilator | 5.054 2026-11-01 |
| cocotb | 2.1.0 |
| Python | 3.14.10 (`.venv`) |
| OS | Linux |

Core test dependencies (`cocotb`, `cocotb-tools`, `crcmod`, `pytest`) are installed.
`pandas` is **not** installed in the venv; it is only required by the data-analysis
scripts (`requirements.txt`), not by the simulation regression, so it did not
affect this run.

## 2. Regression results

| Metric | Value |
|--------|-------|
| Build/test configurations | 80 |
| cocotb tests | 158 |
| Passed | 158 |
| Failed | 0 |
| Skipped | 0 |
| Aggregate test sim time | 2,186,450 ns (~2.19 ms) |
| Aggregate test CPU time | 6.06 s (build time excluded) |
| Fatal warnings | 0 |

### Configuration matrix

- **Levels:** `core` (bare algorithm cores), `wrapper` (TX+RX loopback),
  `harness` (full instrumented stand).
- **Algorithms (14):** parity even/odd; checksum-16 (one's complement),
  checksum-8 (wrap); Fletcher-16, Fletcher-32; Adler-32;
  CRC-8, CRC-16/CCITT-FALSE, CRC-16/ARC, CRC-32, CRC-32C; SHA-256.
- **Data widths:** 8, 32, 64 bit for core/wrapper; 8 bit for harness.
- **Total:** 14 algorithms × 3 widths × 2 levels = 78 configurations
  (156 tests, 2 tests each) + 2 harness campaigns (1 test each) = 80 / 158.

### Test groups exercised

| Level | Tests | Content |
|-------|-------|---------|
| Core | `directed_and_random` | Empty packet, 1 byte, boundary lengths W−1/W/W+1, all-`FF`, 24 seeded random packets up to 320 B per config |
| Core | `known_vectors` | CRC catalogue check for `"123456789"`, Adler-32 check value, SHA-256 `"abc"` digest |
| Wrapper | `clean_roundtrip` | Payload/tag transparency with randomized `tvalid` gaps and `tready` backpressure |
| Wrapper | `injected_error_detected` | Single-bit corruption is flagged via `tag_error` and passed through |
| Harness | `campaign` | Clean campaign: 16 packets, 0 corrupted / 0 detected / 0 missed / 0 false alarms on all 6 lanes; single-bit campaign: 16/16 corrupted, 16/16 detected, 0 missed, 0 false alarms on all 6 lanes |

All results matched the Python reference models in `tb/model.py`
(XOR-reduce, RFC 1071 checksum, Fletcher, `zlib.adler32`, `crcmod`/bitwise CRC,
`hashlib.sha256`).

## 3. Lint

`make lint` (`verilator --lint-only -Wall -Wno-fatal`) completed for
DATA_WIDTH = 8 / 32 / 64. **2 non-fatal warnings**, both at width 8:

| Location | Warning | Note |
|----------|---------|------|
| `rtl/harness/error_injector.sv:91-92` | `SELRANGE` — `s_axis_tdata[15:8]` outside `7:0` | Byte-swap branch (MODE=3) is guarded by `BEAT_BYTES >= 2`, so unreachable at width 8; benign for the current campaigns (MODE 0/1), but byte-swap is non-functional at width 8. Consider a generate guard or a width-aware implementation. |

## 4. Other findings (non-blocking)

| Count | Finding | Location | Impact |
|-------|---------|----------|--------|
| 6 | `%Warning-WIDTHEXPAND` — OR operand width mismatch (16-bit `next_blk` vs 8-bit selected byte) | `rtl/cores/fletcher_core.sv:51` | Cosmetic; zero-extension is intended, tests pass. Worth an explicit cast to silence. |
| 24 | `%Warning-WIDTHTRUNC` — 32-bit `CRC_POLY`/`CRC_INIT` literals truncated to 8/16-bit parameters | `tb/tb_core_wrap.sv:11-12`, `tb/tb_wrapper.sv:11-12` | Testbench-only; matches intended CRC-8/CRC-16 presets. Silence with properly sized literals. |
| 119 | `DeprecationWarning`: `Simulator.build *verilog_sources* parameter is deprecated. Use *sources* instead.` | `tb/run_tests.py:166` | Will break with a future `cocotb-tools` release; update to the `sources=` argument. |
| 1 | `tb/results.xml` is overwritten on every configuration, so only the last one remains after a full run | `tb/run_tests.py:185-194` | Reporting/artifact convenience only. |

## 5. Not covered by this run

- **`make cov`** (line/functional coverage) was not executed. The verification
  plan's readiness criterion of ≥95% RTL line coverage is therefore **not yet
  demonstrated**.
- Only `harness_clean` and `harness_single_bit` campaigns were run; the planned
  burst, byte-swap, zero-insert and permutation campaigns are not yet exercised
  by `tb/test_harness.py`.
- No synthesis / board measurements (stage 3–5 of the project plan).

## 6. Conclusion

The current RTL and testbench pass the complete simulation regression:
**158/158 tests green across all 14 algorithm configurations, 3 data widths and
both verification levels, with no functional failures.** Remaining items are
lint/testbench hygiene (width casts, deprecated API) and the still-missing
coverage measurement and extended error campaigns.
