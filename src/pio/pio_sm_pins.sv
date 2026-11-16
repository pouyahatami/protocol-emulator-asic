/*
 * Copyright (c) 2026 Bruce Liu
 * SPDX-License-Identifier: Apache-2.0
 */

`timescale 1ns/1ps
`default_nettype none

// Pin output registers for one state machine. OUT PINS writes out_data to out_count pins from
// out_base on commit, and side-set writes side_val to sideset_count pins from sideset_base
// whenever the control FSM allows it, including stalled ticks. Side-set wins on a shared pin.
// Pin numbers wrap modulo 32, and pins 24 to 31 do not exist. See docs/spec/control-fsm.md
module pio_sm_pins (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        commit,
    input  logic        is_out,
    input  logic [2:0]  out_dest,
    // Zero above out_bits, so OUT pins beyond out_bits are driven to 0
    input  logic [7:0]  out_data,

    input  logic        sideset_en,
    input  logic        side_en,
    input  logic [4:0]  side_val,

    // Must not change while the SM is enabled
    input  logic [4:0]  out_base,
    input  logic [3:0]  out_count,
    input  logic [4:0]  sideset_base,
    input  logic [2:0]  sideset_count,

    output logic [23:0] pins_out,
    output logic [23:0] pins_oe
);

  import pio_pkg::*;

  localparam int NumPins = 24;

  logic        do_out;
  logic        do_side;
  logic [4:0]  out_off;
  logic [4:0]  side_off;
  logic [23:0] pins_next;

  assign do_out  = commit && is_out && (out_dest == OutDestPins);
  assign do_side = sideset_en && side_en;

  // Pin j is OUT bit (j - out_base) mod 32 and side-set bit (j - sideset_base) mod 32, when
  // that offset is inside the field. Side-set is applied last so it overrides OUT. The
  // offsets are per-pin temporaries, and each is only used as an index once it is in range
  always_comb begin
    pins_next = pins_out;
    out_off   = 5'd0;
    side_off  = 5'd0;
    for (int j = 0; j < NumPins; j++) begin
      out_off  = 5'(j) - out_base;
      side_off = 5'(j) - sideset_base;
      if (do_out && (out_off < {1'b0, out_count})) begin
        pins_next[j] = out_data[out_off];
      end
      if (do_side && (side_off < {2'b00, sideset_count})) begin
        pins_next[j] = side_val[side_off];
      end
    end
  end

  // Pins idle high so a UART TX line does not show a false start bit before the first tick
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pins_out <= '1;
    end else begin
      pins_out <= pins_next;
    end
  end

  // No v0 instruction writes pin directions, so every pin stays released
  assign pins_oe = '0;

endmodule

`default_nettype wire
