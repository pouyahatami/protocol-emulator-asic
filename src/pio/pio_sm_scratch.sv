/*
 * Copyright (c) 2026 Bruce Liu
 * SPDX-License-Identifier: Apache-2.0
 */

`timescale 1ns/1ps
`default_nettype none

// Scratch registers X and Y for one state machine. Written only on commit: SET X and SET Y load
// the zero-extended immediate, and JMP X-- decrements X whether or not the jump is taken. See
// docs/spec/control-fsm.md
module pio_sm_scratch (
    input  logic       clk,
    input  logic       rst_n,

    input  logic       commit,
    input  logic       is_jmp,
    input  logic       is_set,
    input  logic [2:0] set_dest,
    input  logic [4:0] set_data,
    input  logic [2:0] jmp_cond,

    output logic [7:0] x,
    output logic [7:0] y
);

  import pio_pkg::*;

  logic set_x;
  logic set_y;
  logic dec_x;

  assign set_x = commit && is_set && (set_dest == SetDestX);
  assign set_y = commit && is_set && (set_dest == SetDestY);
  assign dec_x = commit && is_jmp && (jmp_cond == JmpXDec);

  // The jump condition reads x before this edge, so the decrement never affects its own jump
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      x <= 8'd0;
      y <= 8'd0;
    end else begin
      if (set_x) begin
        x <= {3'b000, set_data};
      end else if (dec_x) begin
        x <= x - 8'd1;
      end
      if (set_y) begin
        y <= {3'b000, set_data};
      end
    end
  end

endmodule

`default_nettype wire
