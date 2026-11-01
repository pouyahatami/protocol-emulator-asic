# Questa/ModelSim script for spi_slave_tb. Run from this folder: vsim -do run.do
# Add +seed=<n> to the vsim line to change the random seed

vlib work
# 2892: Questa rejects `input logic` ports under `default_nettype none`, as in
# test/bootloader/run.do
vlog -sv -suppress 2892 \
  ../../src/sync_2ff.sv \
  ../../src/spi_slave.sv \
  ../../src/bootloader.sv \
  spi_slave_tb.sv

vsim -voptargs=+acc work.spi_slave_tb
add wave -r /spi_slave_tb/*
run -all
