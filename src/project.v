/*
 * Copyright (c) 2026 Pouya Hatami
 * SPDX-License-Identifier: Apache-2.0
 */

`timescale 1ns/1ps
`default_nettype none

module tt_um_pouyahatami_protocol_emulator (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

  // Instruction-memory scaffold. There is no protocol engine yet, so the two instruction
  // memories are exposed through a direct pin-level access port. The port exists for two
  // reasons: synthesis removes a memory whose outputs reach no pin, and every input pin must
  // stay physically connected for LibreLane's disconnected-pin checker. Replace this access
  // port wholesale once the Stage-1 host interface is accepted; nothing here is a committed
  // pin assignment.
  //
  //   ui_in[5:0]   word address
  //   ui_in[6]     memory select: 0 addresses i_imem0, 1 addresses i_imem1
  //   ui_in[7]     access type: 1 writes a word, 0 reads a word
  //   uio_in[7:0]  write access: upper byte of the word; the lower byte is the value this bus
  //                carried at the preceding rising clock edge
  //                read access: bit 0 selects the byte presented on uo_out (0 lower, 1 upper)
  //   uo_out[7:0]  selected byte of the word read at the preceding rising clock edge, or zero
  //                when that edge did not sample a read access
  wire [5:0] access_addr   = ui_in[5:0];
  wire       access_select = ui_in[6];
  wire       access_write  = ui_in[7];

  // An access is sampled only while the design is selected and out of reset, so neither memory
  // is written or read during reset or while ena is low.
  wire       access_active = ena & rst_n;
  wire       imem0_men     = access_active & ~access_select;
  wire       imem1_men     = access_active &  access_select;

  reg  [7:0] wdata_low;
  reg        read_valid;
  reg        read_select;
  reg        read_upper_byte;

  wire [15:0] imem_din = {uio_in, wdata_low};
  wire [15:0] imem0_dout;
  wire [15:0] imem1_dout;

  // The reset is synchronous and active low. The memory contents are not reset: each word is
  // undefined until it has been written. All four registers hold their value while ena is low.
  always @(posedge clk) begin
    if (!rst_n) begin
      wdata_low       <= 8'b0;
      read_valid      <= 1'b0;
      read_select     <= 1'b0;
      read_upper_byte <= 1'b0;
    end else if (ena) begin
      wdata_low       <= uio_in;
      read_valid      <= ~access_write;
      read_select     <= access_select;
      read_upper_byte <= uio_in[0];
    end
  end

  // IHP single-port 64x16 SRAM. The read is synchronous: A_DOUT changes after the rising edge
  // of A_CLK that samples A_MEN and A_REN high, and holds its value otherwise. A_DLY must be
  // tied high per the datasheet. This macro variant has no bit-mask or BIST pins to tie off.
  RM_IHPSG13_1P_64x16_c2 i_imem0 (
      .A_CLK (clk),
      .A_MEN (imem0_men),
      .A_WEN (access_write),
      .A_REN (~access_write),
      .A_ADDR(access_addr),
      .A_DIN (imem_din),
      .A_DLY (1'b1),
      .A_DOUT(imem0_dout)
  );

  RM_IHPSG13_1P_64x16_c2 i_imem1 (
      .A_CLK (clk),
      .A_MEN (imem1_men),
      .A_WEN (access_write),
      .A_REN (~access_write),
      .A_ADDR(access_addr),
      .A_DIN (imem_din),
      .A_DLY (1'b1),
      .A_DOUT(imem1_dout)
  );

  // The memory outputs are registered inside the macros, so the dedicated outputs are a
  // combinational selection of the word read at the preceding clock edge.
  wire [15:0] read_word = read_select ? imem1_dout : imem0_dout;
  wire [7:0]  read_byte = read_upper_byte ? read_word[15:8] : read_word[7:0];

  assign uo_out  = read_valid ? read_byte : 8'b0;

  // The bidirectional bus stays an input until a protocol owns it, so the output enable is held
  // low and the output data is tied off rather than left floating.
  assign uio_out = 8'b0;
  assign uio_oe  = 8'b0;

endmodule

`default_nettype wire
