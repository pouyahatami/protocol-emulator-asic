/*
 * Copyright (c) 2026 Pouya Hatami
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

// Black-box declaration of the IHP single-port 64x16 SRAM macro, for lint and synthesis. It
// gives the tools the port names, directions, and widths; the macro's contents come from the
// PDK layout. Simulation must use the PDK behavioural model instead, so this declaration is
// only read when SIM is not defined
`ifndef SIM
(* blackbox *)
module RM_IHPSG13_1P_64x16_c2 (
    input  wire        A_CLK,
    input  wire        A_MEN,
    input  wire        A_WEN,
    input  wire        A_REN,
    input  wire [5:0]  A_ADDR,
    input  wire [15:0] A_DIN,
    input  wire        A_DLY,
    output wire [15:0] A_DOUT
);
endmodule
`endif

`default_nettype wire
