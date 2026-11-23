# Convenience targets for lint, simulation and coverage.
#
# The regression is driven by tb/run_tests.py; the Makefile only supplies the
# common entry points documented in README.md.

PYTHON  ?= python3
VENV    ?= .venv
VERILATOR ?= verilator
WIDTHS  ?= 8,32,64

# Simulator-based throughput measurement (ticks per byte).
SIM_CAMPAIGN ?= clean
SIM_WIDTH    ?= 32
SIM_PACKETS  ?= 64
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

.PHONY: all lint sim sim-quick cov harness sim-measure sim-measure-all sim-false-rate test-false-rate gen-vectors clean help

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
	@echo "make test-false-rate - pytest checks for the scientific generators"
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
	MODE=0 NUM_PACKETS=$(SIM_PACKETS) LEN_MAX=$(SIM_LEN_MAX) SEED=$(SIM_SEED) \
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

test-false-rate:
	$(PY) -m pytest tb/test_false_rate_suite.py -q

# Regenerate both HDLen-derived and GF(2)-derived adversarial vector sets.
gen-vectors:
	$(PY) scripts/gen_koopman_vectors.py
	$(PY) scripts/gen_zero_syndrome.py

clean:
	rm -rf sim_build tb/results.xml
	find . -type d -name __pycache__ -prune -exec rm -rf {} +
