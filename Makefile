# Convenience targets for lint, simulation and coverage.
#
# The regression is driven by tb/run_tests.py; the Makefile only supplies the
# common entry points documented in README.md.

PYTHON  ?= python3
VENV    ?= .venv
VERILATOR ?= verilator
WIDTHS  ?= 8,32,64

ifeq ($(wildcard $(VENV)/bin/python),)
PY := $(PYTHON)
else
PY := $(VENV)/bin/python
endif

RTL_SOURCES := $(sort $(wildcard rtl/cores/*.sv rtl/wrappers/*.sv rtl/harness/*.sv))
LINT_COMMON := --lint-only -Wall -Wno-fatal -Irtl/cores
LINT_TOP    := --top-module exp_harness_top

.PHONY: all lint sim sim-quick cov harness clean help

all: lint sim

help:
	@echo "make lint       - Verilator --lint-only -Wall for DATA_WIDTH 8/32/64"
	@echo "make sim        - full cocotb regression (core, wrapper, harness)"
	@echo "make sim-quick  - quick regression subset for local iteration"
	@echo "make cov        - regression with Verilator line coverage"
	@echo "make harness    - harness-only simulation"
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

clean:
	rm -rf sim_build tb/results.xml
	find . -type d -name __pycache__ -prune -exec rm -rf {} +
