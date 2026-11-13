/*
 * Copyright (c) 2026 Pouya Hatami
 * SPDX-License-Identifier: Apache-2.0
 */

`timescale 1ns/1ps
`default_nettype none

// Formal wrapper for spi_slave. Every input is left free, so the solver may choose any value
// on any cycle. The properties are listed in spi_slave_properties.md
module spi_slave_formal (
    input logic        clk,
    input logic        rst_n,
    input logic        sclk,
    input logic        cs_n,
    input logic        mosi,
    input logic [15:0] tx_word,
    input logic        tx_load
);

  logic        miso;
  logic        cs_asserted;
  logic [15:0] rx_word;
  logic        word_ready;

  spi_slave dut (
      .clk        (clk),
      .rst_n      (rst_n),
      .sclk       (sclk),
      .cs_n       (cs_n),
      .mosi       (mosi),
      .miso       (miso),
      .cs_asserted(cs_asserted),
      .rx_word    (rx_word),
      .word_ready (word_ready),
      .tx_word    (tx_word),
      .tx_load    (tx_load)
  );

  // Start in reset, so every register begins from its reset value
  initial assume (!rst_n);

  // f_past_valid is 0 on the first cycle, when $past() has no previous value to return
  logic f_past_valid = 1'b0;
  always @(posedge clk) f_past_valid <= 1'b1;

  // Yosys cannot read dut.sclk_rise, so the wrapper rebuilds the same edge from the sclk pin:
  // two synchronizer stages and a copy one cycle older, reset like the ones in spi_slave
  logic f_sclk_s1_q;
  logic f_sclk_s2_q;
  logic f_sclk_prev_q;
  logic f_sclk_rise;

  always @(posedge clk) begin
    if (!rst_n) begin
      f_sclk_s1_q   <= 1'b0;
      f_sclk_s2_q   <= 1'b0;
      f_sclk_prev_q <= 1'b0;
    end else begin
      f_sclk_s1_q   <= sclk;
      f_sclk_s2_q   <= f_sclk_s1_q;
      f_sclk_prev_q <= f_sclk_s2_q;
    end
  end

  assign f_sclk_rise = cs_asserted && f_sclk_s2_q && !f_sclk_prev_q;

  // f_edges_q counts sclk rising edges since chip select was last deasserted or since the last
  // completed word. It reads 16 on the cycle after the 16th edge
  logic [4:0] f_edges_q;

  always @(posedge clk) begin
    if (!rst_n || !cs_asserted) begin
      f_edges_q <= 5'd0;
    end else if (word_ready) begin
      f_edges_q <= f_sclk_rise ? 5'd1 : 5'd0;
    end else if (f_sclk_rise) begin
      f_edges_q <= f_edges_q + 5'd1;
    end
  end

  // f_partial_q is set once chip select is deasserted in the middle of a word
  logic f_partial_q;

  always @(posedge clk) begin
    if (!rst_n) begin
      f_partial_q <= 1'b0;
    end else if (!cs_asserted && f_edges_q != 5'd0 && f_edges_q != 5'd16) begin
      f_partial_q <= 1'b1;
    end
  end

  // P1: a word completes only after 16 rising edges. Edges counted before chip select was
  // deasserted do not count toward the next word, so a partial word is discarded
  always @(*) begin
    if (f_past_valid && word_ready) begin
      assert (f_edges_q == 5'd16);
    end
  end

  // P2: miso is 0 on every cycle after a cycle with chip select deasserted
  always @(posedge clk) begin
    if (f_past_valid && !$past(cs_asserted)) begin
      assert (!miso);
    end
  end

  // Cover statements: the solver must find a trace that reaches each one. If a case could never
  // be reached, the property that depends on it would pass without checking anything. Each
  // cover reads only states after the first reset edge, because the registers hold arbitrary
  // values on the first cycle

  always @(*) begin
    if (f_past_valid) begin
      // C1: a word completes after a partial word was discarded
      cover (f_partial_q && word_ready);
    end
  end

  always @(posedge clk) begin
    if (f_past_valid && $past(rst_n)) begin
      // C2: chip select is deasserted while miso is 1
      cover ($past(miso) && !$past(cs_asserted));
    end
  end

endmodule

`default_nettype wire
