/*
 * Copyright (c) 2026 Benjamin Heyfitch
 * SPDX-License-Identifier: Apache-2.0
 */

`timescale 1ns/1ps
`default_nettype none

// SPI mode 0 slave between the RP2040 and the bootloader. Collects MOSI bits into 16-bit words
// and shifts words from the bootloader out on MISO, MSB first. Everything runs on clk: the SPI
// pins are synchronized and sclk is only sampled for edges, so sclk must stay at or below
// clk/16 (ADR-003)
module spi_slave (
    input  logic        clk,
    input  logic        rst_n,

    // SPI pins from the RP2040, asynchronous to clk
    input  logic        sclk,
    input  logic        cs_n,
    input  logic        mosi,
    output logic        miso,

    // Bootloader interface
    output logic        cs_asserted,
    output logic [15:0] rx_word,
    output logic        word_ready,
    input  logic [15:0] tx_word,
    input  logic        tx_load
);

  logic sclk_sync;
  logic mosi_sync;

  // Each SPI input gets its own synchronizer, so sclk and mosi reach the logic with the same
  // two-cycle delay and each synchronized mosi bit lines up with its sclk edge
  sync_2ff i_sync_sclk (
      .clk    (clk),
      .rst_n  (rst_n),
      .async_i(sclk),
      .sync_o (sclk_sync)
  );

  sync_2ff i_sync_mosi (
      .clk    (clk),
      .rst_n  (rst_n),
      .async_i(mosi),
      .sync_o (mosi_sync)
  );

  // Chip select is inverted before the synchronizer, so the synchronizer's reset value of 0
  // reads as "not selected" instead of selecting the slave for two cycles after reset
  sync_2ff i_sync_cs (
      .clk    (clk),
      .rst_n  (rst_n),
      .async_i(~cs_n),
      .sync_o (cs_asserted)
  );

  // sclk_prev_q is sclk_sync one cycle ago. A rising edge is 0 then 1, a falling edge 1 then 0
  logic sclk_prev_q;
  logic sclk_rise;
  logic sclk_fall;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      sclk_prev_q <= 1'b0;
    end else begin
      sclk_prev_q <= sclk_sync;
    end
  end

  assign sclk_rise = cs_asserted &  sclk_sync & ~sclk_prev_q;
  assign sclk_fall = cs_asserted & ~sclk_sync &  sclk_prev_q;

  // bit_cnt_q counts sclk rising edges in the current word and wraps from 15 to 0 when a word
  // completes. It is held at 0 outside a transfer, so a partial word is discarded when chip
  // select is deasserted
  logic [3:0] bit_cnt_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      bit_cnt_q <= '0;
    end else if (!cs_asserted) begin
      bit_cnt_q <= '0;
    end else if (sclk_rise) begin
      bit_cnt_q <= bit_cnt_q + 4'd1;
    end
  end

  // Only the first 15 bits of a word are stored here. The 16th bit goes straight into rx_word
  // with them, in the same cycle it is sampled
  logic [14:0] rx_shift_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rx_shift_q <= '0;
    end else if (sclk_rise) begin
      rx_shift_q <= {rx_shift_q[13:0], mosi_sync};
    end
  end

  // rx_word only changes when a word completes, so it holds its value while word_ready is high
  // and for the whole of the next word
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rx_word    <= '0;
      word_ready <= 1'b0;
    end else begin
      word_ready <= 1'b0;
      if (sclk_rise && bit_cnt_q == 4'd15) begin
        rx_word    <= {rx_shift_q, mosi_sync};
        word_ready <= 1'b1;
      end
    end
  end

  // miso is the top bit of tx_shift_q. A load takes priority over a shift. The register shifts
  // only on falling edges 1 to 15 of a word: the 16th falling edge comes after the last read of
  // a word and before the first read of the next one, and shifting there would drop the next
  // word's MSB before the RP2040 samples it. Outside a transfer the register is cleared, so
  // miso idles at 0 and the extra word loaded at the end of a read burst is dropped
  logic [15:0] tx_shift_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      tx_shift_q <= '0;
    end else if (!cs_asserted) begin
      tx_shift_q <= '0;
    end else if (tx_load) begin
      tx_shift_q <= tx_word;
    end else if (sclk_fall && bit_cnt_q != 4'd0) begin
      tx_shift_q <= {tx_shift_q[14:0], 1'b0};
    end
  end

  assign miso = tx_shift_q[15];

endmodule

`default_nettype wire
