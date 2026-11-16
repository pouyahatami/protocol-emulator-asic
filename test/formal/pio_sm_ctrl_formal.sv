/*
 * Copyright (c) 2026 Pouya Hatami, Bruce Liu
 * SPDX-License-Identifier: Apache-2.0
 */

`timescale 1ns/1ps
`default_nettype none

// Formal wrapper for pio_sm_ctrl. Every input is left free, so the solver may choose any value
// on any cycle. The properties are listed in pio_sm_ctrl_properties.md. They read the state only
// through stalled, active, and on_instr, which together decode all four states
module pio_sm_ctrl_formal (
    input logic       clk,
    input logic       rst_n,
    input logic       enable,
    input logic       tick,
    input logic       stall,
    input logic       unsup_instr,
    input logic [4:0] delay_val,
    input logic       delay_last
);

  logic commit;
  logic pc_advance;
  logic sideset_en;
  logic delay_load;
  logic delay_dec;
  logic stalled;
  logic active;
  logic on_instr;

  pio_sm_ctrl dut (
      .clk        (clk),
      .rst_n      (rst_n),
      .enable     (enable),
      .tick       (tick),
      .stall      (stall),
      .unsup_instr(unsup_instr),
      .delay_val  (delay_val),
      .delay_last (delay_last),
      .commit     (commit),
      .pc_advance (pc_advance),
      .sideset_en (sideset_en),
      .delay_load (delay_load),
      .delay_dec  (delay_dec),
      .stalled    (stalled),
      .active     (active),
      .on_instr   (on_instr)
  );

  logic       in_disabled;
  logic       in_exec;
  logic       in_stall;
  logic       in_delay;
  logic [3:0] state_seen;
  logic       any_strobe;

  assign in_disabled = !active;
  assign in_exec     = on_instr && !stalled;
  assign in_stall    = stalled;
  assign in_delay    = active && !on_instr;
  assign state_seen  = {in_delay, in_stall, in_exec, in_disabled};
  assign any_strobe  = commit || pc_advance || sideset_en || delay_load || delay_dec;

  // One flag per row of the transition table, in priority order. Exactly one is 1 each cycle
  logic row_idle;
  logic row_delay;
  logic row_unsup;
  logic row_stall;
  logic row_commit;

  assign row_idle   = !enable || !tick || in_disabled;
  assign row_delay  = !row_idle && in_delay;
  assign row_unsup  = !row_idle && on_instr && unsup_instr;
  assign row_stall  = !row_idle && on_instr && !unsup_instr && stall;
  assign row_commit = !row_idle && on_instr && !unsup_instr && !stall;

  logic f_past_valid = 1'b0;

  always_ff @(posedge clk) begin
    f_past_valid <= 1'b1;
  end

  // A1: start in reset, so the state register begins from its reset value
  a1_reset_at_power_up: assume property (@(posedge clk) f_past_valid || !rst_n);

  // The open-source flow has no implication operator, so each "if A then B" is written !A || B

  p1_enable_low_disables: assert property (@(posedge clk) disable iff (!f_past_valid)
      !$past(rst_n && !enable) || in_disabled);
  p2_no_tick_holds: assert property (@(posedge clk) disable iff (!f_past_valid)
      !$past(rst_n && enable && !in_disabled && !tick) || state_seen == $past(state_seen));
  p3_sideset_en: assert property (@(posedge clk)
      sideset_en == (enable && tick && on_instr && !unsup_instr));
  // pio_sm_delay assumes P4 as its A1, so it is checked in every state, including reset
  p4_delay_strobes_exclusive: assert property (@(posedge clk) !(delay_load && delay_dec));
  p5_reset_disables: assert property (@(posedge clk) disable iff (!f_past_valid)
      $past(rst_n) || in_disabled);
  p6_enable_starts_exec: assert property (@(posedge clk) disable iff (!f_past_valid)
      !$past(rst_n && enable && in_disabled) || in_exec);
  p7_delay_continues: assert property (@(posedge clk) disable iff (!f_past_valid)
      !$past(rst_n && row_delay && !delay_last) || in_delay);
  p8_delay_ends: assert property (@(posedge clk) disable iff (!f_past_valid)
      !$past(rst_n && row_delay && delay_last) || in_exec);
  p9_unsup_holds_exec: assert property (@(posedge clk) disable iff (!f_past_valid)
      !$past(rst_n && row_unsup) || in_exec);
  p10_stall_enters_stall: assert property (@(posedge clk) disable iff (!f_past_valid)
      !$past(rst_n && row_stall) || in_stall);
  p11_commit_no_delay_exec: assert property (@(posedge clk) disable iff (!f_past_valid)
      !$past(rst_n && row_commit && delay_val == 5'd0) || in_exec);
  p12_commit_delay_enters_delay: assert property (@(posedge clk) disable iff (!f_past_valid)
      !$past(rst_n && row_commit && delay_val != 5'd0) || in_delay);

  // stalled implies on_instr, and on_instr implies active, so the three decode one state
  p13_stalled_on_instr: assert property (@(posedge clk) !stalled || on_instr);
  p14_on_instr_active:  assert property (@(posedge clk) !on_instr || active);

  p15_idle_no_strobes: assert property (@(posedge clk) !row_idle || !any_strobe);
  p16_delay_strobes: assert property (@(posedge clk)
      !row_delay || (delay_dec && !commit && !pc_advance && !sideset_en && !delay_load));
  p17_unsup_no_strobes: assert property (@(posedge clk) !row_unsup || !any_strobe);
  p18_stall_strobes: assert property (@(posedge clk)
      !row_stall || (sideset_en && !commit && !pc_advance && !delay_load && !delay_dec));
  p19_commit_strobes: assert property (@(posedge clk)
      !row_commit || (commit && pc_advance && sideset_en && !delay_dec
                      && delay_load == (delay_val != 5'd0)));

  // Cover statements: the solver must find a trace that reaches each one. If a case could never
  // happen, the assertions that depend on it would pass without checking anything
  c1_delay_load: cover property (@(posedge clk) delay_load);
  c2_delay_dec: cover property (@(posedge clk) delay_dec);
  c3_stall_held: cover property (@(posedge clk)
      f_past_valid && $past(rst_n) && in_stall && $past(in_stall));
  c4_commit_from_stall: cover property (@(posedge clk)
      f_past_valid && $past(rst_n) && in_stall && commit);
  c5_delay_held: cover property (@(posedge clk)
      f_past_valid && $past(rst_n) && in_delay && $past(in_delay));
  c6_delay_ends: cover property (@(posedge clk)
      f_past_valid && $past(rst_n) && in_exec && $past(in_delay));
  c7_unsup_held: cover property (@(posedge clk)
      f_past_valid && $past(rst_n && row_unsup) && in_exec);
  c8_disable_from_delay: cover property (@(posedge clk)
      f_past_valid && $past(rst_n) && in_disabled && $past(in_delay));
  c9_disable_from_stall: cover property (@(posedge clk)
      f_past_valid && $past(rst_n) && in_disabled && $past(in_stall));

endmodule

`default_nettype wire
