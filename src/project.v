/*
 * Copyright (c) 2026 Pouya Hatami
 * SPDX-License-Identifier: Apache-2.0
 */

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

  // Stage-0 skeleton: keep every externally driven signal in a safe state.
  assign uo_out  = 8'b0;
  assign uio_out = 8'b0;
  assign uio_oe  = 8'b0;

  wire _unused = &{ui_in, uio_in, ena, clk, rst_n, 1'b0};

endmodule

`default_nettype wire
