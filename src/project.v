/*
 * Copyright (c) 2026 Pouya Hatami
 * SPDX-License-Identifier: Apache-2.0
 */

`timescale 1ns/1ps
`default_nettype none

module tt_um_pouyahatami_protocol_emulator (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

  // Stage-0 placeholder. There is no protocol engine yet, but every input pin must still reach
  // an output, otherwise synthesis strips the unused ports and LibreLane's disconnected-pin
  // checker aborts the GDS flow. Folding the two input buses into one registered value is the
  // cheapest construct that keeps all nineteen input pins physically connected. Replace this
  // block wholesale once the Stage-1 datapath and its pin interface are accepted.
  reg [7:0] input_digest;

  // The reset is synchronous and active low: input_digest returns to zero on the first rising
  // clock edge with rst_n low, and the digest only advances while the design is powered.
  always @(posedge clk) begin
    if (!rst_n) begin
      input_digest <= 8'b0;
    end else if (ena) begin
      input_digest <= ui_in ^ uio_in;
    end
  end

  // The dedicated outputs expose the digest one clock after its inputs are sampled.
  assign uo_out  = input_digest;

  // The bidirectional bus stays an input until a protocol owns it, so the output enable is held
  // low and the output data is tied off rather than left floating.
  assign uio_out = 8'b0;
  assign uio_oe  = 8'b0;

endmodule

`default_nettype wire
