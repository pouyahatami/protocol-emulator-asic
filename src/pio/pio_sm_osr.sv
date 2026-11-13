/*
 * Copyright (c) 2026 Bruce Liu
 * SPDX-License-Identifier: Apache-2.0
 */

`timescale 1ns/1ps
`default_nettype none

// Output shift register for one state machine. Written only on commit: PULL loads a FIFO byte
// and clears the shift count, and OUT shifts out_bits bits out and fills with zeros. out_data
// presents the bits leaving on this commit, right-aligned. See docs/spec/control-fsm.md
module pio_sm_osr (
    input  logic       clk,
    input  logic       rst_n,

    input  logic       commit,
    input  logic       is_out,
    input  logic       is_pull,
    // 1 to 8. The wrapper never commits 0 or values above 8, which are unsupported in v0
    input  logic [4:0] out_bits,
    // Must not change while the SM is enabled
    input  logic       shift_right,
    input  logic [7:0] txf_data,

    output logic [7:0] osr,
    output logic [3:0] osr_count,
    output logic [7:0] out_data
);

  logic       do_pull;
  logic       do_out;
  logic [3:0] shift_count;
  logic [4:0] count_sum;

  assign do_pull = commit && is_pull;
  assign do_out  = commit && is_out;

  assign shift_count = (out_bits > 5'd8) ? 4'd8 : out_bits[3:0];
  assign count_sum   = {1'b0, osr_count} + {1'b0, shift_count};

  // A right shift sends the low shift_count bits, and a left shift sends the high ones
  assign out_data = shift_right ? (osr & ~(8'hFF << shift_count))
                                : (osr >> (4'd8 - shift_count));

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      osr       <= 8'd0;
      osr_count <= 4'd0;
    end else if (do_pull) begin
      osr       <= txf_data;
      osr_count <= 4'd0;
    end else if (do_out) begin
      osr       <= shift_right ? (osr >> shift_count) : (osr << shift_count);
      osr_count <= (count_sum > 5'd8) ? 4'd8 : count_sum[3:0];
    end
  end

endmodule

`default_nettype wire
