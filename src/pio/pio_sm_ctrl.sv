/*
 * Copyright (c) 2026 Bruce Liu
 * SPDX-License-Identifier: Apache-2.0
 */

`timescale 1ns/1ps
`default_nettype none

// Control FSM for one state machine. A Mealy machine that sequences execute, stall, and delay
// one tick at a time. The five strobes are 0 unless tick is high. See docs/spec/control-fsm.md
module pio_sm_ctrl (
    input  logic       clk,
    input  logic       rst_n,

    input  logic       enable,
    input  logic       tick,
    input  logic       stall,
    input  logic [4:0] delay_val,
    input  logic       delay_last,

    output logic       commit,
    output logic       pc_advance,
    output logic       sideset_en,
    output logic       delay_load,
    output logic       delay_dec,
    output logic       stalled,
    output logic       active
);

  typedef enum logic [1:0] {
    Disabled = 2'b00,
    Exec     = 2'b01,
    Stall    = 2'b10,
    Delay    = 2'b11
  } state_e;

  state_e state;
  state_e state_next;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state <= Disabled;
    end else begin
      state <= state_next;
    end
  end

  // The branches follow the spec's transition table in priority order. Leaving enable low acts
  // on the next clock without waiting for a tick, and the DISABLED exit ignores tick because the
  // divider produces none while the FSM is inactive
  always_comb begin
    state_next = state;
    commit     = 1'b0;
    pc_advance = 1'b0;
    sideset_en = 1'b0;
    delay_load = 1'b0;
    delay_dec  = 1'b0;

    if (!enable) begin
      state_next = Disabled;
    end else if (state == Disabled) begin
      state_next = Exec;
    end else if (tick) begin
      case (state)
    
        Exec, Stall: begin
          // Side-set applies on every tick of the instruction, including stalled ones
          sideset_en = 1'b1;
          if (stall) begin
            state_next = Stall;
          end else begin
            commit     = 1'b1;
            pc_advance = 1'b1;
            if (delay_val == 5'd0) begin
              state_next = Exec;
            end else begin
              delay_load = 1'b1;
              state_next = Delay;
            end
          end
        end
        Delay: begin
          delay_dec = 1'b1;
          if (delay_last) begin
            state_next = Exec;
          end
        end
        default: begin
          state_next = Disabled;
        end
      endcase
    end
  end

  assign stalled = (state == Stall);
  assign active  = (state != Disabled);

endmodule

`default_nettype wire
