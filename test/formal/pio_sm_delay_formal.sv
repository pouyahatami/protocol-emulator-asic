/*
 * Copyright (c) 2026 Pouya Hatami
 * SPDX-License-Identifier: Apache-2.0
 */

`timescale 1ns/1ps
`default_nettype none

// Formal wrapper for pio_sm_delay. Every input is left free, except where an assumption
// limits it. The properties are listed in pio_sm_delay_properties.md
module pio_sm_delay_formal (
    input logic       clk,
    input logic       rst_n,
    input logic       delay_load,
    input logic       delay_dec,
    input logic [4:0] delay_val
);

  logic delay_last;

  pio_sm_delay dut (
      .clk        (clk),
      .rst_n      (rst_n),
      .delay_load (delay_load),
      .delay_dec  (delay_dec),
      .delay_val  (delay_val),
      .delay_last (delay_last)
  );

  // Environment assumptions: limits on the free inputs that the real design guarantees

  // Start in reset, so the count begins from its reset value
  initial assume (!rst_n);

  // A1: delay_load and delay_dec are never asserted on the same cycle. pio_sm_ctrl drives
  // both strobes, and P4 in pio_sm_ctrl_properties.md proves this for every state
  always @(*) assume (!(delay_load && delay_dec));

  // f_past_valid is 0 on the first cycle, when $past() has no previous value to return
  logic f_past_valid = 1'b0;
  always @(posedge clk) f_past_valid <= 1'b1;

  // Cover statements: the solver must find a trace that reaches each one. A cover that cannot
  // be reached means the assumptions are too strict

  always @(posedge clk) begin
    if (f_past_valid && rst_n) begin
      // C1: loading a delay of 1 flags the last tick immediately
      cover ($past(rst_n) && $past(delay_load) && ($past(delay_val) == 5'd1) && delay_last);

      // C2: a decrement brings a larger delay down to its last tick
      cover ($past(rst_n) && $past(delay_dec) && delay_last);
    end
  end

endmodule

`default_nettype wire
