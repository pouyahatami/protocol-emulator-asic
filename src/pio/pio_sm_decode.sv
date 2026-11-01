/*
 * Copyright (c) 2026 Bruce Liu
 * SPDX-License-Identifier: Apache-2.0
 */

`timescale 1ns/1ps
`default_nettype none

// Instruction decoder for one state machine. Purely combinational. Splits a 16-bit PIO-encoded
// instruction into its fields and divides the delay/side-set field according to the side-set
// configuration. See docs/spec/control-fsm.md
module pio_sm_decode (
    input  logic [15:0] instr,
    // sideset_count + sideset_opt must be at most 5, and neither may change while enabled
    input  logic [2:0]  sideset_count,
    input  logic        sideset_opt,

    output logic [2:0]  op,
    output logic        side_en,
    // Bit i drives side-set pin sideset_base + i. Bits at or above sideset_count are 0
    output logic [4:0]  side_val,
    output logic [4:0]  delay_val,

    output logic [2:0]  jmp_cond,
    output logic [4:0]  jmp_addr,
    output logic [2:0]  set_dest,
    output logic [4:0]  set_data,
    output logic [2:0]  out_dest,
    output logic [4:0]  out_bits,
    output logic        is_pull,
    output logic        block
);

  localparam logic [2:0] OpPushPull = 3'b100;

  logic [4:0] ds_field;
  logic [7:0] args;
  logic [2:0] delay_bits;

  assign op       = instr[15:13];
  assign ds_field = instr[12:8];
  assign args     = instr[7:0];

  // From the MSB down, the field holds the optional enable bit, then sideset_count side-set
  // bits, then delay_bits of delay. Shifting a full mask by 5 leaves it empty, so a
  // zero-width part decodes to 0
  assign delay_bits = 3'd5 - sideset_count - {2'b00, sideset_opt};
  assign delay_val  = ds_field & ~(5'h1F << delay_bits);
  assign side_val   = (ds_field >> delay_bits) & ~(5'h1F << sideset_count);
  assign side_en    = sideset_opt ? ds_field[4] : (sideset_count != 3'd0);

  assign jmp_cond = args[7:5];
  assign jmp_addr = args[4:0];
  assign set_dest = args[7:5];
  assign set_data = args[4:0];
  assign out_dest = args[7:5];
  assign out_bits = args[4:0];
  assign is_pull  = (op == OpPushPull) && args[7];
  assign block    = args[5];

endmodule

`default_nettype wire
