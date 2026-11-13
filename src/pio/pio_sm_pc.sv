/*
 * Copyright (c) 2026 Bruce Liu
 * SPDX-License-Identifier: Apache-2.0
 */

`timescale 1ns/1ps
`default_nettype none

// Program counter for one state machine. Moves to next_pc only when the control FSM asserts
// pc_advance. A taken jump wins over wrap, and wrap wins over increment. See
// docs/spec/control-fsm.md
module pio_sm_pc (
    input  logic       clk,
    input  logic       rst_n,

    input  logic       pc_advance,
    input  logic       jump_taken,
    input  logic [4:0] jmp_addr,
    // Must not change while the SM is enabled
    input  logic [4:0] wrap_top,
    input  logic [4:0] wrap_bottom,

    output logic [4:0] pc
);

  logic [4:0] next_pc;

  // Increment wraps from 31 to 0 on its own when pc runs past wrap_top
  always_comb begin
    if (jump_taken) begin
      next_pc = jmp_addr;
    end else if (pc == wrap_top) begin
      next_pc = wrap_bottom;
    end else begin
      next_pc = pc + 5'd1;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pc <= 5'd0;
    end else if (pc_advance) begin
      pc <= next_pc;
    end
  end

endmodule

`default_nettype wire
