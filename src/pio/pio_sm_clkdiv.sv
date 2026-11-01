/*
 * Copyright (c) 2026 Bruce Liu
 * SPDX-License-Identifier: Apache-2.0
 */

`timescale 1ns/1ps
`default_nettype none

// Clock divider for one state machine. Emits a one-cycle tick every clkdiv clocks, or every
// clock when clkdiv is 0 or 1. The count is held at 0 unless the SM is enabled and active, so
// the first tick lands on the max(clkdiv, 1)-th clock in EXEC. See docs/spec/control-fsm.md
module pio_sm_clkdiv (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        enable,
    input  logic        active,
    // Must not change while enable is high
    input  logic [15:0] clkdiv,

    output logic        tick
);

  logic [15:0] div_cnt;
  logic        running;
  logic        period_end;

  assign running    = enable && active;
  assign period_end = (clkdiv <= 16'd1) || (div_cnt == clkdiv - 16'd1);
  assign tick       = running && period_end;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      div_cnt <= 16'd0;
    end else if (!running || period_end) begin
      div_cnt <= 16'd0;
    end else begin
      div_cnt <= div_cnt + 16'd1;
    end
  end

endmodule

`default_nettype wire
