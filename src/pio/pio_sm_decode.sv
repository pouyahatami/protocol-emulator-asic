/*
 * Copyright (c) 2026 Bruce Liu
 * SPDX-License-Identifier: Apache-2.0
 */

`timescale 1ns/1ps
`default_nettype none

// Instruction decoder for one state machine. Purely combinational. Splits a 16-bit PIO-encoded
// instruction into its fields and divides the delay/side-set field according to the side-set
// configuration. Flags any instruction outside the v0 subset. See docs/spec/control-fsm.md
module pio_sm_decode (
    input  logic [15:0] instr,
    // sideset_count + sideset_opt must be at most 5, and neither may change while enabled
    input  logic [2:0]  sideset_count,
    input  logic        sideset_opt,

    // One flag per v0 instruction, so no other module needs the raw opcode
    output logic        is_jmp,
    output logic        is_out,
    output logic        is_pull,
    output logic        is_set,

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
    output logic        block,

    // 1 for any instruction outside the v0 subset, so the FSM never commits it
    output logic        unsup_instr
);

  import pio_pkg::*;

  logic [2:0] op;
  logic [4:0] ds_field;
  logic [7:0] args;
  logic [2:0] delay_bits;
  logic       legal_jmp;
  logic       legal_out;
  logic       legal_pull;
  logic       legal_set;

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

  assign is_jmp  = (op == OpJmp);
  assign is_out  = (op == OpOut);
  assign is_pull = (op == OpPushPull) && args[7];
  assign is_set  = (op == OpSet);

  assign jmp_cond = args[7:5];
  assign jmp_addr = args[4:0];
  assign set_dest = args[7:5];
  assign set_data = args[4:0];
  assign out_dest = args[7:5];
  assign out_bits = args[4:0];
  // Qualified like is_pull so a later PUSH stall term cannot pick up bit 5 of another opcode
  assign block    = (op == OpPushPull) && args[5];

  // WAIT, IN, MOV, IRQ, PUSH, PULL variants, and unimplemented conditions, destinations, and
  // bit counts all fall through to unsup_instr
  assign legal_jmp   = is_jmp && ((jmp_cond == JmpAlways) || (jmp_cond == JmpXDec));
  assign legal_out   = is_out && (out_dest == OutDestPins) &&
                       (out_bits >= 5'd1) && (out_bits <= 5'd8);
  // Only plain blocking PULL: IfEmpty (args[6]) needs a pull threshold v0 lacks, and
  // args[4:0] are reserved as 0
  assign legal_pull  = is_pull && block && !args[6] && (args[4:0] == 5'd0);
  assign legal_set   = is_set && ((set_dest == SetDestX) || (set_dest == SetDestY));
  assign unsup_instr = !(legal_jmp || legal_out || legal_pull || legal_set);

endmodule

`default_nettype wire
