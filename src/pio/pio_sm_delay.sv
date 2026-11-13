/*
 * Copyright (c) 2026 Bruce Liu
 * SPDX-License-Identifier: Apache-2.0
 */

`timescale 1ns/1ps
`default_nettype none

// Delay counter for one state machine. Holds the delay ticks left after an instruction and
// flags the last one. The control FSM never asserts delay_load and delay_dec together, and only
// decrements while the count is at least 1. See docs/spec/control-fsm.md
module pio_sm_delay (
    input  logic       clk,
    input  logic       rst_n,

    input  logic       delay_load,
    input  logic       delay_dec,
    input  logic [4:0] delay_val,

    output logic       delay_last
);

  logic [4:0] delay_cnt;

  // The count is left as is on disable. The next delay_load overwrites it before it is read
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      delay_cnt <= 5'd0;
    end else if (delay_load) begin
      delay_cnt <= delay_val;
    end else if (delay_dec) begin
      delay_cnt <= delay_cnt - 5'd1;
    end
  end

  assign delay_last = (delay_cnt == 5'd1);

endmodule

`default_nettype wire
