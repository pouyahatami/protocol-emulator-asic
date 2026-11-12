/*
 * Copyright (c) 2026 Pouya Hatami
 * SPDX-License-Identifier: Apache-2.0
 */

`timescale 1ns/1ps
`default_nettype none

// Self-checking testbench for imem_port. The port drives two IHP 64x16 SRAM models from the PDK,
// and a monitor checks every read against a golden copy of the 128-word memory
module imem_port_tb;

  // 50MHz clk
  localparam int CLK_PERIOD_NS = 20;

  localparam int DEPTH         = 128;
  localparam int BANK_DEPTH    = 64;

  logic        clk;
  logic        rst_n;

  // Access port
  logic        men;
  logic        wen;
  logic        ren;
  logic [6:0]  addr;
  logic [15:0] din;
  logic [15:0] dout;

  // Macro side
  logic        mem0_men;
  logic        mem1_men;
  logic        mem_wen;
  logic        mem_ren;
  logic [5:0]  mem_addr;
  logic [15:0] mem_din;
  logic [15:0] mem0_dout;
  logic [15:0] mem1_dout;

  imem_port imem_port_instance (
      .clk      (clk),
      .rst_n    (rst_n),
      .men      (men),
      .wen      (wen),
      .ren      (ren),
      .addr     (addr),
      .din      (din),
      .dout     (dout),
      .mem0_men (mem0_men),
      .mem1_men (mem1_men),
      .mem_wen  (mem_wen),
      .mem_ren  (mem_ren),
      .mem_addr (mem_addr),
      .mem_din  (mem_din),
      .mem0_dout(mem0_dout),
      .mem1_dout(mem1_dout)
  );

  // A_DLY must be tied high per the datasheet; the PDK model stops the simulation otherwise
  RM_IHPSG13_1P_64x16_c2 imem0_instance (
      .A_CLK (clk),
      .A_MEN (mem0_men),
      .A_WEN (mem_wen),
      .A_REN (mem_ren),
      .A_ADDR(mem_addr),
      .A_DIN (mem_din),
      .A_DLY (1'b1),
      .A_DOUT(mem0_dout)
  );

  RM_IHPSG13_1P_64x16_c2 imem1_instance (
      .A_CLK (clk),
      .A_MEN (mem1_men),
      .A_WEN (mem_wen),
      .A_REN (mem_ren),
      .A_ADDR(mem_addr),
      .A_DIN (mem_din),
      .A_DLY (1'b1),
      .A_DOUT(mem1_dout)
  );

  // CLK generation
  initial begin
    clk = 1'b0;
    forever begin
      #(CLK_PERIOD_NS / 2) clk = ~clk;
    end
  end

  // Golden memory contents, updated by the monitor on every write
  logic [15:0] expected_mem [DEPTH];

  int          errors;
  int          read_count;     // Read results the monitor has checked
  logic        monitor_en;
  logic        expected_valid; // Set once a read has been sampled since reset
  logic [15:0] expected_dout;  // Word dout must show, from the last read sampled
  int          expected_addr;  // Address of that word, for error messages

  // Counts an error and reports it
  task automatic fail(input string msg);
    errors++;
    $error("%s", msg);
  endtask

  // Outputs are checked at the rising edge. dout is compared before the golden state is updated,
  // because at this edge it still shows the word read at the previous edge
  always @(posedge clk) begin
    if (monitor_en) begin
      if ($isunknown({mem0_men, mem1_men})) fail("macro memory enable is X");
      if (mem0_men && mem1_men) fail("both macros enabled in one cycle");
      if (men != (mem0_men || mem1_men))
        fail($sformatf("men=%b but mem0_men=%b mem1_men=%b", men, mem0_men, mem1_men));
      if (men && (mem1_men != addr[6]))
        fail($sformatf("addr %0d enabled the wrong macro", addr));
      if (mem_addr !== addr[5:0] || mem_din !== din || mem_wen !== wen || mem_ren !== ren)
        fail("shared macro inputs differ from the access port");

      if (expected_valid) begin
        read_count++;
        if (dout !== expected_dout)
          fail($sformatf("addr %0d: dout %h, expected %h", expected_addr, dout, expected_dout));
      end

      if (men && ren) begin
        expected_valid = 1'b1;
        expected_dout  = expected_mem[addr];
        expected_addr  = addr;
      end
      if (men && wen) expected_mem[addr] = din;
    end
  end

  // Holds rst_n low for two clock edges, then enables the monitor
  task automatic reset();
    monitor_en     = 1'b0;
    expected_valid = 1'b0;
    rst_n          = 1'b0;
    idle();
    repeat (2) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
    // The monitor starts after reset, because the macro outputs are unknown before the first read
    monitor_en = 1'b1;
  endtask

  // Drives no access for one cycle
  task automatic idle();
    men  = 1'b0;
    wen  = 1'b0;
    ren  = 1'b0;
    addr = '0;
    din  = '0;
    @(negedge clk);
  endtask

  // Drives one write access for one cycle
  task automatic write_word(input int a, input logic [15:0] data);
    men  = 1'b1;
    wen  = 1'b1;
    ren  = 1'b0;
    addr = 7'(a);
    din  = data;
    @(negedge clk);
  endtask

  // Drives one read access for one cycle. The monitor checks the result one cycle later
  task automatic read_word(input int a);
    men  = 1'b1;
    wen  = 1'b0;
    ren  = 1'b1;
    addr = 7'(a);
    din  = '0;
    @(negedge clk);
  endtask

  // Writes a different word to every address, then reads them all back in back-to-back cycles.
  // A broken bank decode makes the two banks alias, and the second bank's words overwrite the
  // first's
  task automatic test_every_address_is_distinct();
    $display("[%0t] test_every_address_is_distinct", $time);
    reset();
    for (int a = 0; a < DEPTH; a++) write_word(a, 16'hA500 ^ 16'(a * 16'h0101));
    for (int a = 0; a < DEPTH; a++) read_word(a);
    idle();
  endtask

  // Reads alternate between the banks every cycle. The output select must follow with exactly
  // one cycle of latency
  task automatic test_alternating_banks();
    $display("[%0t] test_alternating_banks", $time);
    reset();
    write_word(3, 16'h0003);
    write_word(BANK_DEPTH + 3, 16'h1003);
    write_word(BANK_DEPTH - 1, 16'h003F);
    write_word(BANK_DEPTH, 16'h1000);
    for (int i = 0; i < 4; i++) begin
      read_word(3);
      read_word(BANK_DEPTH + 3);
    end
    // Last word of bank 0, then first word of bank 1
    read_word(BANK_DEPTH - 1);
    read_word(BANK_DEPTH);
    read_word(BANK_DEPTH - 1);
    idle();
  endtask

  // A write or an idle cycle does not change a macro's output, so dout must keep showing the last
  // word read, even when the write goes to the other bank
  task automatic test_dout_holds_after_read();
    $display("[%0t] test_dout_holds_after_read", $time);
    reset();
    write_word(BANK_DEPTH + 6, 16'hBEEF);
    write_word(6, 16'hCAFE);

    read_word(BANK_DEPTH + 6);
    write_word(6, 16'h1234);
    idle();
    idle();

    read_word(6);
    write_word(BANK_DEPTH + 6, 16'h5678);
    idle();

    // Both writes must have landed
    read_word(BANK_DEPTH + 6);
    read_word(6);
    idle();
  endtask

  initial begin
    errors     = 0;
    read_count = 0;
    monitor_en = 1'b0;

    test_every_address_is_distinct();
    test_alternating_banks();
    test_dout_holds_after_read();

    if (errors == 0) $display("PASS: all imem_port tests passed (%0d read checks)", read_count);
    else             $display("FAIL: %0d error(s)", errors);
    $finish;
  end

  // Stops a hung test
  initial begin
    #1ms;
    $fatal(1, "Test hangs");
  end

endmodule

`default_nettype wire
