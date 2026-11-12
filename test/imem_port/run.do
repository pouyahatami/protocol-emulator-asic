# Questa/ModelSim script for imem_port_tb. Run from this folder: vsim -do run.do
# The SRAM models are copied from the IHP PDK, ihp-sg13g2/libs.ref/sg13g2_sram/verilog
set SRAM_MODELS ../ihp_sram

vlib work
# FUNCTIONAL selects the PDK model's zero-delay variant, without timing checks.
# 2892: Questa rejects `input logic` ports under `default_nettype none`
vlog -sv +define+FUNCTIONAL -suppress 2892 \
  ../../src/imem_port.sv \
  $SRAM_MODELS/RM_IHPSG13_1P_64x16_c2.v \
  $SRAM_MODELS/RM_IHPSG13_1P_core_behavioral.v \
  imem_port_tb.sv

vsim -voptargs=+acc work.imem_port_tb
add wave -r /imem_port_tb/*
run -all
