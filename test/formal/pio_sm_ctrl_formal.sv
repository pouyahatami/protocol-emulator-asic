/*
 * Copyright (c) 2026 Pouya Hatami
 * SPDX-License-Identifier: Apache-2.0
 */

`timescale 1ns/1ps
`default_nettype none

// Formal wrapper for pio_sm_ctrl. Every input is left free, so the solver may choose any value
// on any cycle. The properties are listed in pio_sm_ctrl_properties.md
module pio_sm_ctrl_formal (
    input logic       clk,
    input logic       rst_n,
    input logic       enable,
    input logic       tick,
    input logic       stall,
    input logic [4:0] delay_val,
    input logic       delay_last
);

  logic commit;
  logic pc_advance;
  logic sideset_en;
  logic delay_load;
  logic delay_dec;
  logic stalled;
  logic active;

  pio_sm_ctrl dut (
      .clk        (clk),
      .rst_n      (rst_n),
      .enable     (enable),
      .tick       (tick),
      .stall      (stall),
      .delay_val  (delay_val),
      .delay_last (delay_last),
      .commit     (commit),
      .pc_advance (pc_advance),
      .sideset_en (sideset_en),
      .delay_load (delay_load),
      .delay_dec  (delay_dec),
      .stalled    (stalled),
      .active     (active)
  );

  // Start in reset, so the state register begins from its reset value
  initial assume (!rst_n);

  // P4: the FSM never asserts delay_load and delay_dec on the same cycle. pio_sm_delay assumes
  // this, so the property is checked in every state, including before the first reset edge
  always @(*) assert (!(delay_load && delay_dec));

  // Cover statements: the solver must find a trace that reaches each one. If a strobe could
  // never be asserted, P4 would pass without checking anything

  always @(*) begin
    // C1: an instruction with a non-zero delay commits and loads the counter
    cover (delay_load);

    // C2: the FSM decrements the counter in DELAY
    cover (delay_dec);
  end

endmodule

`default_nettype wire
