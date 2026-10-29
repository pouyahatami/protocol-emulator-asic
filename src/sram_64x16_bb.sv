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
    input  logic        A_CLK,
    input  logic        A_MEN,
    input  logic        A_WEN,
    input  logic        A_REN,
    input  logic [5:0]  A_ADDR,
    input  logic [15:0] A_DIN,
    input  logic        A_DLY,
    output logic [15:0] A_DOUT
);
endmodule
`endif

`default_nettype wire
