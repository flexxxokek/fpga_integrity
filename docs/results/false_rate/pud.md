# Pud(undetected error probability)

Upper 95% bound on Pud, estimated from HW_m fractions measured by
`hd_sweep` (m=1..4; zero-miss buckets use the Wilson upper bound).
Source: Koopman FAA TC-14-49 / Maxino & Koopman (2009) methodology.

Approximation truncates m at 4, so it is valid only for BER·n << 1.
With ~2000 trials per weight the Wilson bound (~2e-3) dominates for
algorithms with no observed misses: the table is sample-limited and
must not be read as a ranking of those algorithms.

| algorithm | bits | Pud<= @ 0.0001 | Pud<= @ 1e-05 | Pud<= @ 1e-06 | Pud<= @ 1e-07 |
|---|---:|---:|---:|---:|---:|
| adler32 | 64 | 0.000116 | 1.16e-05 | 1.16e-06 | 1.16e-07 |
| adler32 | 256 | 0.000458 | 4.64e-05 | 4.64e-06 | 4.64e-07 |
| adler32 | 1024 | 0.00176 | 0.000185 | 1.86e-05 | 1.86e-06 |
| adler32 | 2048 | 0.00337 | 0.000367 | 3.71e-05 | 3.71e-06 |
| checksum16 | 64 | 0.000122 | 1.17e-05 | 1.16e-06 | 1.16e-07 |
| checksum16 | 256 | 0.000548 | 4.73e-05 | 4.65e-06 | 4.64e-07 |
| checksum16 | 1024 | 0.00338 | 0.000202 | 1.87e-05 | 1.86e-06 |
| checksum16 | 2048 | 0.00838 | 0.000427 | 3.77e-05 | 3.72e-06 |
| crc32 | 64 | 0.000116 | 1.16e-05 | 1.16e-06 | 1.16e-07 |
| crc32 | 256 | 0.000458 | 4.64e-05 | 4.64e-06 | 4.64e-07 |
| crc32 | 1024 | 0.00176 | 0.000185 | 1.86e-05 | 1.86e-06 |
| crc32 | 2048 | 0.00337 | 0.000367 | 3.71e-05 | 3.71e-06 |
| fletcher16 | 64 | 0.000116 | 1.16e-05 | 1.16e-06 | 1.16e-07 |
| fletcher16 | 256 | 0.000458 | 4.64e-05 | 4.64e-06 | 4.64e-07 |
| fletcher16 | 1024 | 0.00177 | 0.000185 | 1.86e-05 | 1.86e-06 |
| fletcher16 | 2048 | 0.00337 | 0.000367 | 3.71e-05 | 3.71e-06 |
| parity | 64 | 0.000135 | 1.18e-05 | 1.16e-06 | 1.16e-07 |
| parity | 256 | 0.000766 | 4.95e-05 | 4.67e-06 | 4.65e-07 |
| parity | 1024 | 0.00634 | 0.000235 | 1.91e-05 | 1.86e-06 |
| parity | 2048 | 0.0199 | 0.000566 | 3.91e-05 | 3.73e-06 |
| sha256 | 64 | 0.000116 | 1.16e-05 | 1.16e-06 | 1.16e-07 |
| sha256 | 256 | 0.000458 | 4.64e-05 | 4.64e-06 | 4.64e-07 |
| sha256 | 1024 | 0.00176 | 0.000185 | 1.86e-05 | 1.86e-06 |
| sha256 | 2048 | 0.00337 | 0.000367 | 3.71e-05 | 3.71e-06 |
