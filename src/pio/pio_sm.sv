/*
 * Copyright (c) 2026 Bruce Liu
 * SPDX-License-Identifier: Apache-2.0
 */

`timescale 1ns/1ps
`default_nettype none

// Wires the divider, control FSM, PC, decoder, delay counter, and
// datapath, and holds the stall check and jump condition. Instruction memory and the TX FIFO
// sit outside. See docs/spec/control-fsm.md
module pio_sm (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        enable,

    // Must not change while enable is high
    input  logic [15:0] clkdiv,
    input  logic [4:0]  wrap_top,
    input  logic [4:0]  wrap_bottom,
    input  logic [2:0]  sideset_count,
    input  logic        sideset_opt,
    input  logic [4:0]  sideset_base,
    input  logic [4:0]  out_base,
    input  logic [3:0]  out_count,
    input  logic        shift_right,

    output logic [4:0]  imem_addr,
    input  logic [15:0] imem_data,

    input  logic [7:0]  txf_data,
    input  logic        txf_empty,
    output logic        txf_pop,

    // Synchronized pin levels. Unused by UART TX
    input  logic [23:0] pins_in,
    output logic [23:0] pins_out,
    output logic [23:0] pins_oe,
    output logic        stalled,
    output logic [4:0]  pc,
    // Sticky. Set when EXEC or STALL sees a v0-illegal instruction. Clears only on reset
    output logic        unsupported
);

  import pio_pkg::*;

  logic        tick;
  logic        commit;
  logic        pc_advance;
  logic        sideset_en;
  logic        delay_load;
  logic        delay_dec;
  logic        active;
  logic        delay_last;
  logic        stall;
  logic        jump_taken;
  logic        on_instr;
  logic        unsup_instr;

  logic        is_jmp;
  logic        is_out;
  logic        is_pull;
  logic        is_set;
  logic        side_en;
  logic [4:0]  side_val;
  logic [4:0]  delay_val;
  logic [2:0]  jmp_cond;
  logic [4:0]  jmp_addr;
  logic [2:0]  set_dest;
  logic [4:0]  set_data;
  logic [2:0]  out_dest;
  logic [4:0]  out_bits;
  logic        block;

  logic [7:0]  x;
  logic [7:0]  y;
  logic [7:0]  osr;
  logic [3:0]  osr_count;
  logic [7:0]  out_data;

  assign imem_addr = pc;
  assign stall     = is_pull && block && txf_empty;
  assign txf_pop   = commit && is_pull;

  // Sticky until reset so the host can still see a bad program after disable
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      unsupported <= 1'b0;
    end else if (enable && on_instr && unsup_instr) begin
      unsupported <= 1'b1;
    end
  end

  // The jump reads X before the JMP X-- decrement, because X is a register
  assign jump_taken = is_jmp && (
      (jmp_cond == JmpAlways) || ((jmp_cond == JmpXDec) && (x != 8'd0))
  );

  pio_sm_clkdiv u_clkdiv (
      .clk    (clk),
      .rst_n  (rst_n),
      .enable (enable),
      .active (active),
      .clkdiv (clkdiv),
      .tick   (tick)
  );

  pio_sm_ctrl u_ctrl (
      .clk         (clk),
      .rst_n       (rst_n),
      .enable      (enable),
      .tick        (tick),
      .stall       (stall),
      .unsup_instr (unsup_instr),
      .delay_val   (delay_val),
      .delay_last  (delay_last),
      .commit      (commit),
      .pc_advance  (pc_advance),
      .sideset_en  (sideset_en),
      .delay_load  (delay_load),
      .delay_dec   (delay_dec),
      .stalled     (stalled),
      .active      (active),
      .on_instr    (on_instr)
  );

  pio_sm_pc u_pc (
      .clk         (clk),
      .rst_n       (rst_n),
      .pc_advance  (pc_advance),
      .jump_taken  (jump_taken),
      .jmp_addr    (jmp_addr),
      .wrap_top    (wrap_top),
      .wrap_bottom (wrap_bottom),
      .pc          (pc)
  );

  pio_sm_decode u_decode (
      .instr         (imem_data),
      .sideset_count (sideset_count),
      .sideset_opt   (sideset_opt),
      .is_jmp        (is_jmp),
      .is_out        (is_out),
      .is_pull       (is_pull),
      .is_set        (is_set),
      .side_en       (side_en),
      .side_val      (side_val),
      .delay_val     (delay_val),
      .jmp_cond      (jmp_cond),
      .jmp_addr      (jmp_addr),
      .set_dest      (set_dest),
      .set_data      (set_data),
      .out_dest      (out_dest),
      .out_bits      (out_bits),
      .block         (block),
      .unsup_instr   (unsup_instr)
  );

  pio_sm_delay u_delay (
      .clk        (clk),
      .rst_n      (rst_n),
      .delay_load (delay_load),
      .delay_dec  (delay_dec),
      .delay_val  (delay_val),
      .delay_last (delay_last)
  );

  pio_sm_scratch u_scratch (
      .clk      (clk),
      .rst_n    (rst_n),
      .commit   (commit),
      .is_jmp   (is_jmp),
      .is_set   (is_set),
      .set_dest (set_dest),
      .set_data (set_data),
      .jmp_cond (jmp_cond),
      .x        (x),
      .y        (y)
  );

  pio_sm_osr u_osr (
      .clk         (clk),
      .rst_n       (rst_n),
      .commit      (commit),
      .is_out      (is_out),
      .is_pull     (is_pull),
      .out_bits    (out_bits),
      .shift_right (shift_right),
      .txf_data    (txf_data),
      .osr         (osr),
      .osr_count   (osr_count),
      .out_data    (out_data)
  );

  pio_sm_pins u_pins (
      .clk           (clk),
      .rst_n         (rst_n),
      .commit        (commit),
      .is_out        (is_out),
      .out_dest      (out_dest),
      .out_data      (out_data),
      .sideset_en    (sideset_en),
      .side_en       (side_en),
      .side_val      (side_val),
      .out_base      (out_base),
      .out_count     (out_count),
      .sideset_base  (sideset_base),
      .sideset_count (sideset_count),
      .pins_out      (pins_out),
      .pins_oe       (pins_oe)
  );

endmodule

`default_nettype wire
