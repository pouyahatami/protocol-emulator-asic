.PHONY: help test test-top test-units clean

# Modules under src/ that have a unit testbench at test/<module>_tb.py
UNITS = pio_sm_ctrl pio_sm_clkdiv pio_sm_pc pio_sm_decode pio_sm_delay pio_sm_scratch \
        pio_sm_osr pio_sm_pins pio_sm

PYTHON ?= python3

help:
	@echo "make test        - run the top-level and unit cocotb test suites"
	@echo "make test-top    - run the top-level cocotb test suite"
	@echo "make test-units  - run every unit test suite"
	@echo "make test-<unit> - run one unit test suite, for example make test-pio_sm_ctrl"
	@echo "make clean       - remove cocotb build products"

test: test-top test-units

test-units: $(addprefix test-,$(UNITS))

# cocotb exits successfully even when tests fail, so each suite's results file is checked
test-top:
	$(MAKE) -C test -B
	cd test && $(PYTHON) -m cocotb_tools.check_results results.xml

test-%:
	$(MAKE) -C test -B -f unit.mk UNIT=$*
	cd test && $(PYTHON) -m cocotb_tools.check_results results_$*.xml

clean:
	$(MAKE) -C test clean
	$(foreach unit,$(UNITS),$(MAKE) -C test -f unit.mk UNIT=$(unit) clean;)
	rm -f test/results_*.xml
