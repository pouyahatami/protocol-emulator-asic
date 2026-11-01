# SPDX-FileCopyrightText: 2026 Bruce Liu
# SPDX-License-Identifier: Apache-2.0

# Runs the cocotb testbench for one module under src/.
# Usage: make -f unit.mk UNIT=pio_sm_ctrl
# The module is src/$(UNIT).sv or src/<subdir>/$(UNIT).sv, and its tests are $(UNIT)_tb.py.

SIM ?= icarus
TOPLEVEL_LANG ?= verilog
# Relative so that make prerequisites survive a checkout path that contains spaces
SRC_DIR = ../src

UNIT ?= pio_sm_ctrl

SIM_BUILD           = sim_build/$(UNIT)
UNIT_SOURCE         = $(firstword $(wildcard $(SRC_DIR)/$(UNIT).sv $(SRC_DIR)/*/$(UNIT).sv))
ifeq ($(UNIT_SOURCE),)
$(error No source for $(UNIT) under $(SRC_DIR))
endif

VERILOG_SOURCES     = $(UNIT_SOURCE)
# The SM wrapper instantiates every child module in the same folder
ifeq ($(UNIT),pio_sm)
VERILOG_SOURCES    += $(wildcard $(dir $(UNIT_SOURCE))pio_sm_*.sv)
endif
TOPLEVEL            = $(UNIT)
COCOTB_TEST_MODULES = $(UNIT)_tb
COCOTB_RESULTS_FILE = results_$(UNIT).xml

include $(shell cocotb-config --makefiles)/Makefile.sim
