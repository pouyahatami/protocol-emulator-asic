/*
 * Copyright (c) 2026 Pouya Hatami
 * SPDX-License-Identifier: Apache-2.0
 */

`timescale 1ns/1ps
`default_nettype none

// Bootloader statemachine sits between the SPI slave and the instruction SRAM and lets an
// external host load and read back the program image. Incoming SPI words are decoded as host
// commands and turned into SRAM write and read accesses
module bootloader #(
    parameter int ADDR_WIDTH = 6 
) (
    input  logic              clk,
    input  logic              rst_n,       

    // SPI slave interface
    input  logic              cs_asserted,  
    input  logic              word_ready,   
    input  logic [15:0]       rx_word,      
    output logic [15:0]       tx_word,     
    output logic              tx_load,      

    // SRAM macro interface
    output logic              sram_men,
    output logic              sram_wen,
    output logic              sram_ren,
    output logic [ADDR_WIDTH-1:0] sram_addr,
    output logic [15:0]       sram_din,
    input  logic [15:0]       sram_dout     
);

  localparam logic [15:0]       OPCODE_WRITE = 16'h0002;
  localparam logic [15:0]       OPCODE_READ  = 16'h0003;

  typedef enum logic [2:0] {
    IDLE,
    DECODE,
    WRITE_ADDRESS,
    WRITE_DATA,
    READ_ADDRESS,
    READ_WAIT,
    READ_DATA,
    IGNORE
  } state_t;

  state_t            state_q;
  state_t            state_d;
  
  // In a write burst, addr_q is the address of the next data word. In a read burst, it is the
  // address of the next word to fetch, one ahead of the word in sram_dout
  logic [ADDR_WIDTH-1:0] addr_q;
  logic [ADDR_WIDTH-1:0] addr_d;

  // Words received after chip select deasserts are discarded and never reach the SRAM
  logic word_valid;
  assign word_valid = cs_asserted & word_ready;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state_q <= IDLE;
      addr_q  <= '0;
    end else begin
      state_q <= state_d;
      addr_q  <= addr_d;
    end
  end

  // The defaults are not tied to the clock. always_comb is a combinational block, and it is
  // evaluated again whenever any signal it reads changes 
  always_comb begin
    // Defaults: hold state and address, no SRAM access, no slave load
    state_d   = state_q;
    addr_d    = addr_q;
    sram_men  = 1'b0;
    sram_wen  = 1'b0;
    sram_ren  = 1'b0;
    sram_addr = addr_q;
    tx_load   = 1'b0;

    case (state_q)
      IDLE: begin
        if (cs_asserted) state_d = DECODE;
      end

      DECODE: begin
        if (word_valid) begin
          if (rx_word == OPCODE_WRITE)     state_d = WRITE_ADDRESS;
          else if (rx_word == OPCODE_READ) state_d = READ_ADDRESS;
          else                             state_d = IGNORE;
        end
      end

      WRITE_ADDRESS: begin
        if (word_valid) begin
          addr_d  = rx_word[ADDR_WIDTH-1:0];
          state_d = WRITE_DATA;
        end
      end

      // The write is sampled at the edge that ends this cycle. The burst ends only when chip
      // select is deasserted; the address wraps at the end of the SRAM
      WRITE_DATA: begin
        if (word_valid) begin
          sram_men = 1'b1;
          sram_wen = 1'b1;
          addr_d   = addr_q + ADDR_WIDTH'(1);
        end
      end

      // addr_q is not loaded until the end of this cycle, so the first read takes its address
      // from rx_word directly. This keeps READ_WAIT at one cycle
      READ_ADDRESS: begin
        if (word_valid) begin
          sram_men  = 1'b1;
          sram_ren  = 1'b1;
          sram_addr = rx_word[ADDR_WIDTH-1:0];
          addr_d    = rx_word[ADDR_WIDTH-1:0] + ADDR_WIDTH'(1);
          state_d   = READ_WAIT;
        end
      end

      // sram_dout holds the first word in this cycle. Hand it to the slave and prefetch the
      // next word; the slave samples tx_word before the SRAM output changes
      READ_WAIT: begin
        if (cs_asserted) begin
          tx_load  = 1'b1;
          sram_men = 1'b1;
          sram_ren = 1'b1;
          addr_d   = addr_q + ADDR_WIDTH'(1);
        end
        state_d = READ_DATA;
      end

      // Each word_ready means the previous word has left the slave. The prefetched word is
      // handed over and the next one is fetched, which hides the SRAM's one-cycle latency
      READ_DATA: begin
        if (word_valid) begin
          tx_load  = 1'b1;
          sram_men = 1'b1;
          sram_ren = 1'b1;
          addr_d   = addr_q + ADDR_WIDTH'(1);
        end
      end

      // An unknown opcode discards every word until chip select is deasserted
      IGNORE: begin
      end

      default: state_d = IDLE;
    endcase

    // Deasserting chip select ends any transfer, whatever the current state
    if (!cs_asserted) state_d = IDLE;
  end

  assign sram_din = rx_word;
  assign tx_word  = sram_dout;

endmodule

`default_nettype wire
