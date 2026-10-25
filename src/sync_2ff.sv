/*
 * Copyright (c) 2026 Pouya Hatami
 * SPDX-License-Identifier: Apache-2.0
 */

`timescale 1ns/1ps
`default_nettype none

// Two-flip-flop synchronizer that brings one asynchronous bit into the clk domain with two
// edges of latency. Use it for a single bit only, never for a multi-bit bus
module sync_2ff (
    input  logic clk,
    input  logic rst_n,    // Synchronous, active-low reset
    input  logic async_i,  // Single-bit asynchronous input
    output logic sync_o    // Synchronized output in the clk domain
);

  // Only stage1_q may go metastable. No logic other than stage2_q may read it
  logic stage1_q;
  logic stage2_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      stage1_q <= 1'b0;
      stage2_q <= 1'b0;
    end else begin
      stage1_q <= async_i;
      stage2_q <= stage1_q;
    end
  end

  assign sync_o = stage2_q;

endmodule

`default_nettype wire
