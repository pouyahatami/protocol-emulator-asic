/*
 * Copyright (c) 2026 Bruce Liu
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

// Instruction encodings shared by the PIO state machine modules. Values follow the RP2040 PIO
// encoding. Only the v0 subset is legal. See docs/spec/control-fsm.md
package pio_pkg;

  // Major opcode, instr[15:13]
  localparam logic [2:0] OpJmp      = 3'b000;
  localparam logic [2:0] OpWait     = 3'b001;
  localparam logic [2:0] OpIn       = 3'b010;
  localparam logic [2:0] OpOut      = 3'b011;
  localparam logic [2:0] OpPushPull = 3'b100;
  localparam logic [2:0] OpMov      = 3'b101;
  localparam logic [2:0] OpIrq      = 3'b110;
  localparam logic [2:0] OpSet      = 3'b111;

  // JMP condition, instr[7:5]
  localparam logic [2:0] JmpAlways = 3'b000;
  localparam logic [2:0] JmpXDec   = 3'b010;

  // SET destination, instr[7:5]
  localparam logic [2:0] SetDestX = 3'b001;
  localparam logic [2:0] SetDestY = 3'b010;

  // OUT destination, instr[7:5]
  localparam logic [2:0] OutDestPins = 3'b000;

endpackage

`default_nettype wire
