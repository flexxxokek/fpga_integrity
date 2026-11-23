# Convenience targets for lint, simulation and coverage.
#
# The regression is driven by tb/run_tests.py; the Makefile only supplies the
# common entry points documented in README.md.

PYTHON  ?= python3
VENV    ?= .venv
VERILATOR ?= verilator
WIDTHS  ?= 8,32,64

# Vendor flow (Terasic DE2-115, Quartus Prime Lite 21.1)
QUARTUS_ROOT ?= /opt/intelFPGA/21.1/quartus
QUARTUS_SH   ?= $(QUARTUS_ROOT)/bin/quartus_sh
QUARTUS_PGM  ?= $(QUARTUS_ROOT)/bin/quartus_pgm
BOARD_DIR    ?= boards/de2_115
INTERACTIVE_DIR ?= boards/de2_115_interactive

# Simulator-based throughput measurement (ticks per byte).
SIM_CAMPAIGN ?= clean
SIM_WIDTH    ?= 32
SIM_PACKETS  ?= 64
SIM_LEN_MIN  ?= 0
SIM_LEN_MAX  ?= 64
SIM_SEED     ?= 0x12345678
SIM_LOG      ?= data/sim_$(SIM_CAMPAIGN)_w$(SIM_WIDTH).log
SIM_CSV      ?= data/sim_$(SIM_CAMPAIGN)_w$(SIM_WIDTH).csv

# False-rate campaign with the Gilbert-Elliott burst-noise channel.
SIM_FAULT_SEED    ?= 305419896
SIM_FAULT_PACKETS ?= 256
SIM_FAULT_LEN_MAX ?= 64
SIM_FAULT_P_GB    ?= 128    # Q16: 1/512 bits between bursts
SIM_FAULT_P_BG    ?= 8192   # Q16: mean burst = 8 bits
SIM_FAULT_LOG     ?= data/sim_gilbert_elliott.log
SIM_FAULT_CSV     ?= data/sim_gilbert_elliott.csv
# Approximate BER of the GE channel: h * burst/(gap+burst) = 8/(512+8).
SIM_FAULT_BER     ?= 0.01538462
SIM_HD_PACKETS    ?= 6000

ifeq ($(wildcard $(VENV)/bin/python),)
PY := $(PYTHON)
else
PY := $(VENV)/bin/python
endif

RTL_SOURCES := $(sort $(wildcard rtl/cores/*.sv rtl/wrappers/*.sv rtl/harness/*.sv))
LINT_COMMON := --lint-only -Wall -Wno-fatal -Irtl/cores
LINT_TOP    := --top-module exp_harness_top

.PHONY: all lint sim sim-quick cov harness sim-measure sim-measure-all sim-false-rate sim-tag-rate test-false-rate gen-vectors synth cov-report test-report board-build board-program board-report board-capture interactive-build interactive-program hash-demo clean help

all: lint sim

help:
	@echo "make lint       - Verilator --lint-only -Wall for DATA_WIDTH 8/32/64"
	@echo "make sim        - full cocotb regression (core, wrapper, harness)"
	@echo "make sim-quick  - quick regression subset for local iteration"
	@echo "make cov        - regression with Verilator line coverage"
	@echo "make harness    - harness-only simulation"
	@echo "make sim-measure - simulator data collection: ticks/byte per algorithm"
	@echo "make sim-measure-all - both DATA_WIDTH 8 and 32 in one summary"
	@echo "make sim-false-rate  - scientific false-rate campaign (Gilbert-Elliott + Koopman + HD sweep)"
	@echo "make sim-tag-rate    - tag-corruption campaign (RX must detect a damaged tag)"
	@echo "make test-false-rate - pytest checks for the scientific generators"
	@echo "make synth         - Yosys synthesis + static LUT/FF comparison table"
	@echo "make cov-report    - merge per-config coverage into docs/coverage.md"
	@echo "make board-build   - Quartus compile of the DE2-115 stand + timing report"
	@echo "make board-report  - render docs/results/board.md from Quartus reports"
	@echo "make board-program - program the DE2-115 over JTAG (connect the board first)"
	@echo "make board-capture PORT=/dev/ttyUSB0 - receive UART report and diff with sim"
	@echo "make interactive-build   - Quartus build of the interactive hash demo"
	@echo "make interactive-program - flash the interactive hash demo"
	@echo "make hash-demo PORT=/dev/ttyUSB0 TEXT=... - run interactive demo vs Python"
	@echo "make gen-vectors   - regenerate HDLen + GF(2) adversarial vector sets"
	@echo "make clean      - remove simulation builds and caches"

lint:
	@for w in 8 32 64; do \
		echo "== verilator lint DATA_WIDTH=$$w =="; \
		$(VERILATOR) $(LINT_COMMON) $(LINT_TOP) $(RTL_SOURCES) \
			-GDATA_WIDTH=$$w -GINCLUDE_SHA=1 || exit 1; \
	done

sim:
	$(PY) tb/run_tests.py --mode all --widths $(WIDTHS)

sim-quick:
	$(PY) tb/run_tests.py --mode all --widths 8,32 --quick

cov:
	$(PY) tb/run_tests.py --mode all --widths $(WIDTHS) --coverage

harness:
	$(PY) tb/run_tests.py --mode harness --widths 32

# Run one deterministic simulator campaign, feed its RESULT lines to
# scripts/collect.py and build the speed tables in docs/results/.
sim-measure:
	@mkdir -p data docs/results
	@rm -f $(SIM_LOG)
	MODE=0 NUM_PACKETS=$(SIM_PACKETS) LEN_MIN=$(SIM_LEN_MIN) LEN_MAX=$(SIM_LEN_MAX) SEED=$(SIM_SEED) \
	SIM_REPORT_LOG=$(SIM_LOG) CAMPAIGN=$(SIM_CAMPAIGN) \
	$(PY) tb/run_tests.py --mode harness --widths $(SIM_WIDTH) --only harness_clean
	$(PY) scripts/collect.py --input $(SIM_LOG) --board sim_verilator_w$(SIM_WIDTH) \
		--campaign $(SIM_CAMPAIGN)_w$(SIM_WIDTH) --seed $(SIM_SEED) --out $(SIM_CSV)
	$(PY) scripts/analyze.py --input $(SIM_CSV) --out docs/results --no-plot

# Both widths in one summary: 8-bit exposes tag-beat costs, 32-bit shows
# payload-beat throughput.
sim-measure-all:
	$(MAKE) sim-measure SIM_WIDTH=8
	$(MAKE) sim-measure SIM_WIDTH=32
	$(PY) scripts/analyze.py --input data/sim_clean_w8.csv data/sim_clean_w32.csv \
		--out docs/results --no-plot

# Model-level scientific generators + the same burst model in RTL.
sim-false-rate:
	@mkdir -p data docs/results/false_rate
	@rm -f $(SIM_FAULT_LOG)
	MODE=5 NUM_PACKETS=$(SIM_FAULT_PACKETS) LEN_MAX=$(SIM_FAULT_LEN_MAX) \
	SEED=$(SIM_FAULT_SEED) \
	GE_P_GB_Q16=$(SIM_FAULT_P_GB) GE_P_BG_Q16=$(SIM_FAULT_P_BG) \
	SIM_REPORT_LOG=$(SIM_FAULT_LOG) CAMPAIGN=gilbert_elliott \
	$(PY) tb/run_tests.py --mode harness --widths 32 \
		--only harness_fault_mode5
	$(PY) scripts/collect.py --input $(SIM_FAULT_LOG) \
		--board sim_verilator_ge --campaign gilbert_elliott_rtl \
		--seed $(SIM_FAULT_SEED) --out $(SIM_FAULT_CSV) \
		--ber $(SIM_FAULT_BER) --codeword-bits $$(( $(SIM_FAULT_LEN_MAX) * 8 )) \
		--data-pattern prng --fault-source gilbert_elliott
	$(PY) scripts/false_rate_suite.py --generator gilbert_elliott \
		--packets $(SIM_FAULT_PACKETS) --length $(SIM_FAULT_LEN_MAX) \
		--seed $(SIM_FAULT_SEED) --min-missed-events 20 \
		--mean-gap $$(( 65536 / $(SIM_FAULT_P_GB) )) \
		--mean-burst $$(( 65536 / $(SIM_FAULT_P_BG) )) \
		--out data/model_gilbert_elliott.csv
	$(PY) scripts/false_rate_suite.py --generator koopman \
		--out data/model_koopman.csv
	$(PY) scripts/false_rate_suite.py --generator koopman_random \
		--out data/model_koopman_random.csv
	$(PY) scripts/false_rate_suite.py --generator hd_sweep \
		--packets $(SIM_HD_PACKETS) --seed $(SIM_FAULT_SEED) \
		--out data/model_hd_sweep.csv
	$(PY) scripts/analyze.py \
		--input data/model_gilbert_elliott.csv data/model_koopman.csv \
			data/model_koopman_random.csv $(SIM_FAULT_CSV) \
			data/model_hd_sweep.csv \
		--out docs/results/false_rate --no-plot
	$(PY) scripts/pud_eval.py --input data/model_hd_sweep.csv \
		--out docs/results/false_rate/pud.md

# Tag-corruption campaign: verifies the RX actually detects a damaged tag.
sim-tag-rate:
	@mkdir -p data
	@rm -f data/sim_tag.log
	MODE=9 NUM_PACKETS=$(SIM_FAULT_PACKETS) LEN_MAX=$(SIM_FAULT_LEN_MAX) \
	SEED=$(SIM_FAULT_SEED) SIM_REPORT_LOG=data/sim_tag.log \
	CAMPAIGN=tag_corruption \
	$(PY) tb/run_tests.py --mode harness --widths 32 \
		--only harness_fault_mode9
	$(PY) scripts/collect.py --input data/sim_tag.log \
		--board sim_verilator_tag --campaign tag_corruption \
		--seed $(SIM_FAULT_SEED) --out data/sim_tag.csv

test-false-rate:
	$(PY) -m pytest tb/test_false_rate_suite.py -q

# Static hardware-cost comparison.  Uses WASM Yosys (`pip install
# yowasp-yosys`) when a system yosys is not available.
synth:
	$(PY) scripts/synth.py
	$(PY) scripts/parse_reports.py --input syn/reports --out data/synthesis.csv
	$(PY) scripts/synth_table.py --input data/synthesis.csv \
		--out docs/results/synthesis.md

# Merge every per-configuration coverage file into one report.  The old
# "coverage >= 95%" claim was never backed by such a report.
cov-report:
	$(PY) scripts/cov_report.py --build-root sim_build/regression \
		--out docs/coverage.md

# Prefer a concrete regression log (LOG=path/to/log), otherwise aggregate the
# per-configuration results.xml files left by `make sim` / `make cov`.
test-report:
	$(PY) scripts/test_report.py --build-root sim_build/regression \
		$(if $(LOG),--log $(LOG),) --out docs/test_report.md

# Regenerate both HDLen-derived and GF(2)-derived adversarial vector sets.
gen-vectors:
	$(PY) scripts/gen_koopman_vectors.py
	$(PY) scripts/gen_zero_syndrome.py

# Vendor flow: synthesis, place-and-route, TimeQuest timing and board report.
board-build:
	cd $(BOARD_DIR) && $(QUARTUS_SH) --flow compile de2_115
	$(PY) scripts/board_report.py --project $(BOARD_DIR) --out docs/results/board.md

board-report:
	$(PY) scripts/board_report.py --project $(BOARD_DIR) --out docs/results/board.md

# Run only after the USB-Blaster / JTAG cable is connected and recognised.
board-program:
	cd $(BOARD_DIR) && $(QUARTUS_PGM) -m JTAG -o "p;de2_115.sof@1"

board-capture:
	@test -n "$(PORT)" || (echo "usage: make board-capture PORT=/dev/ttyUSB0" >&2; exit 1)
	$(PY) scripts/board_capture.py --port $(PORT) $(if $(BAUD),--baud $(BAUD),)

# Interactive hash demo (separate firmware; reflash to switch back to the stand).
interactive-build:
	cd $(INTERACTIVE_DIR) && $(QUARTUS_SH) --flow compile de2_115_interactive

interactive-program:
	cd $(INTERACTIVE_DIR) && $(QUARTUS_PGM) -m JTAG -o "p;de2_115_interactive.sof@1"

hash-demo:
	@test -n "$(PORT)" || (echo "usage: make hash-demo PORT=/dev/ttyUSB0 TEXT=..." >&2; exit 1)
	$(PY) scripts/hash_demo.py --port $(PORT) \
		$(if $(TEXT),--text "$(TEXT)",) $(if $(HEX),--hex $(HEX),) \
		$(if $(FILE),--file $(FILE),) $(if $(BAUD),--baud $(BAUD),)

clean:
	rm -rf sim_build tb/results.xml tb/coverage.dat
	rm -rf syn/yosys/build
	rm -f data/*.log data/*.tmp
	find . -type d -name __pycache__ -prune -exec rm -rf {} +
