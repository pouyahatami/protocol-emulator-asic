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
    // 1 when the instruction at PC is outside the v0 subset. Holds PC with no strobes
    input  logic       unsup_instr,
    input  logic [4:0] delay_val,
    input  logic       delay_last,

    output logic       commit,
    output logic       pc_advance,
    output logic       sideset_en,
    output logic       delay_load,
    output logic       delay_dec,
    output logic       stalled,
    output logic       active,
    // 1 in EXEC or STALL, so the wrapper can latch unsupported while this instruction is current
    output logic       on_instr
);

  // The encodings are fixed because the spec and the testbenches read the raw state
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
    end else begin
      case (state)
        Disabled: begin
          state_next = Exec;
        end
        Exec, Stall: begin
          if (tick) begin
            if (unsup_instr) begin
              // Hold like a stall, but do not side-set or enter STALL. The sticky flag is outside
              state_next = Exec;
            end else begin
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
          end
        end
        Delay: begin
          if (tick) begin
            delay_dec = 1'b1;
            if (delay_last) begin
              state_next = Exec;
            end
          end
        end
        // Unreachable while all four encodings are states. Kept so an X state in simulation, or
        // a future fifth state, falls back to DISABLED
        default: begin
          state_next = Disabled;
        end
      endcase
    end
  end

  assign stalled  = (state == Stall);
  assign active   = (state != Disabled);
  assign on_instr = (state == Exec) || (state == Stall);

endmodule

`default_nettype wire
