/*
 * Copyright (c) 2026 Pouya Hatami
 * SPDX-License-Identifier: Apache-2.0
 */

`timescale 1ns/1ps
`default_nettype none

// Formal wrapper for pio_sm_osr. Every input is left free, so the solver may choose any value
// on any cycle. The assertions check the OSR rows in docs/spec/control-fsm.md
module pio_sm_osr_formal (
    input logic       clk,
    input logic       rst_n,
    input logic       commit,
    input logic [2:0] op,
    input logic       is_pull,
    input logic [4:0] out_bits,
    input logic       shift_right,
    input logic [7:0] txf_data
);

  localparam logic [2:0] OpOut      = 3'b011;
  localparam logic [2:0] OpPushPull = 3'b100;

  logic [7:0] osr;
  logic [3:0] osr_count;
  logic [7:0] out_data;

  pio_sm_osr dut (
      .clk        (clk),
      .rst_n      (rst_n),
      .commit     (commit),
      .op         (op),
      .is_pull    (is_pull),
      .out_bits   (out_bits),
      .shift_right(shift_right),
      .txf_data   (txf_data),
      .osr        (osr),
      .osr_count  (osr_count),
      .out_data   (out_data)
  );

  // Environment assumptions: limits on the free inputs that the real design guarantees

  // Start in reset, so the registers begin from their reset values
  initial assume (!rst_n);

  // The decoder sets is_pull only for the PUSH/PULL opcode, so PULL and OUT never coincide
  always @(*) assume (!is_pull || (op == OpPushPull));

  // Reference model: values computed from the spec, independently of the RTL

  logic       f_pull;
  logic       f_out;
  logic [3:0] f_shift;
  logic [4:0] f_count_next;

  assign f_pull = commit && is_pull;
  assign f_out  = commit && (op == OpOut);

  // The port comment defines out_bits above 8 as acting like 8
  assign f_shift = (out_bits > 5'd8) ? 4'd8 : out_bits[3:0];

  // OUT adds the shift count to osr_count, saturating at 8
  assign f_count_next = ((osr_count + f_shift) > 5'd8) ? 5'd8 : (osr_count + f_shift);

  // f_past_valid is 0 on the first cycle, when $past() has no previous value to return
  logic f_past_valid = 1'b0;
  always @(posedge clk) f_past_valid <= 1'b1;

  // Properties that hold on every cycle

  // P1: the shift count never exceeds the register width. Checked from the second cycle,
  // because before the first clock edge the registers have not been reset yet
  always @(*) if (f_past_valid) assert (osr_count <= 4'd8);

  always @(*) begin
    // P2: out_data is right-aligned, so every bit above the shift count is 0
    assert ((out_data >> f_shift) == 8'd0);

    // P3: out_data holds the bits that leave the OSR. A right shift sends the low bits and
    // a left shift sends the high bits
    for (int i = 0; i < 8; i++) begin
      if (i < f_shift) begin
        if (shift_right) assert (out_data[i] == osr[i]);
        else             assert (out_data[i] == osr[8 - f_shift + i]);
      end
    end
  end

  // Properties that compare this cycle with the previous one

  always @(posedge clk) begin
    if (f_past_valid) begin
      // P4: reset clears the OSR and the shift count
      if (!$past(rst_n)) begin
        assert (osr == 8'd0);
        assert (osr_count == 4'd0);
      end

      // P5: PULL loads the FIFO byte and clears the shift count
      if ($past(rst_n) && $past(f_pull)) begin
        assert (osr == $past(txf_data));
        assert (osr_count == 4'd0);
      end

      // P6: OUT shifts the OSR by the shift count, filling with zeros, and adds the shift
      // count to osr_count
      if ($past(rst_n) && $past(f_out)) begin
        if ($past(shift_right)) assert (osr == ($past(osr) >> $past(f_shift)));
        else                    assert (osr == ($past(osr) << $past(f_shift)));
        assert (osr_count == $past(f_count_next[3:0]));
      end

      // P7: without a committed PULL or OUT, the OSR and the shift count hold
      if ($past(rst_n) && !$past(f_pull) && !$past(f_out)) begin
        assert (osr == $past(osr));
        assert (osr_count == $past(osr_count));
      end
    end
  end

  // Cover statements: the solver must find a trace that reaches each one. A cover that cannot
  // be reached means the assumptions are too strict, which would make the assertions pass
  // without checking anything

  always @(posedge clk) begin
    if (f_past_valid && rst_n) begin
      // C1: a PULL followed by OUTs that empty the OSR
      cover (osr_count == 4'd8);

      // C2: a PULL that loads a non-zero byte
      cover ($past(rst_n) && $past(f_pull) && (osr != 8'd0));
    end
  end

endmodule

`default_nettype wire
