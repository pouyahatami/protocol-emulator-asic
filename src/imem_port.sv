/*
 * Copyright (c) 2026 Pouya Hatami
 * SPDX-License-Identifier: Apache-2.0
 */

`timescale 1ns/1ps
`default_nettype none

// Joins the two 64x16 instruction SRAMs into one 128-word memory with a single access port.
// Address bit 6 selects the macro: 0 addresses i_imem0 and 1 addresses i_imem1. The read latency
// is one clock cycle, the same as a single macro
module imem_port (
    input  logic        clk,
    input  logic        rst_n,

    // Access port. The signals have the same meaning and timing as the macro pins
    input  logic        men,
    input  logic        wen,
    input  logic        ren,
    input  logic [6:0]  addr,
    input  logic [15:0] din,
    output logic [15:0] dout,

    // Macro side. Only the memory enable differs between the two macros; the other inputs are
    // shared
    output logic        mem0_men,
    output logic        mem1_men,
    output logic        mem_wen,
    output logic        mem_ren,
    output logic [5:0]  mem_addr,
    output logic [15:0] mem_din,
    input  logic [15:0] mem0_dout,
    input  logic [15:0] mem1_dout
);

  // Bank of the word currently held on the macro outputs. A macro's output changes only after a
  // read access, so the bank is captured on reads only. A write or an idle cycle leaves it
  // unchanged, and dout keeps showing the last word read
  logic read_bank_q;

  always_ff @(posedge clk) begin
    if (!rst_n)          read_bank_q <= 1'b0;
    else if (men && ren) read_bank_q <= addr[6];
  end

  always_comb begin
    mem0_men = men & ~addr[6];
    mem1_men = men &  addr[6];
    mem_wen  = wen;
    mem_ren  = ren;
    mem_addr = addr[5:0];
    mem_din  = din;
    dout     = read_bank_q ? mem1_dout : mem0_dout;
  end

endmodule

`default_nettype wire
