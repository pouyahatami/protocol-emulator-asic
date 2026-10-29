/*
 * Copyright (c) 2026 Pouya Hatami
 * SPDX-License-Identifier: Apache-2.0
 */

`timescale 1ns/1ps
`default_nettype none

// Self-checking testbench for bootloader. The testbench plays the SPI slave, and the bootloader
// drives the IHP 64x16 SRAM model from the PDK
module bootloader_tb;

  // 50MHz clk
  localparam int          CLK_PERIOD_NS        = 20;

  // RM_IHPSG13_1P_64x16_c2: the IHP SG13G2 single-port SRAM with
  // 64 words of 16 bits. Reads have one clock cycle of latency
  localparam int          ADDR_WIDTH           = 6;

  localparam int          DEPTH                = 1 << ADDR_WIDTH;

  localparam logic [15:0] OPCODE_WRITE         = 16'h0002;
  localparam logic [15:0] OPCODE_READ          = 16'h0003;

  // Idle cycles after each word_ready pulse. A real 16-bit SPI word takes many more cycles
  localparam int          CYCLES_BETWEEN_WORDS = 3;

  // SPI slave interface
  logic        clk;
  logic        rst_n;
  logic        cs_asserted;
  logic        word_ready;
  logic [15:0] rx_word;
  logic [15:0] tx_word;
  logic        tx_load;

  // SRAM macro interface
  logic                  sram_men;
  logic                  sram_wen;
  logic                  sram_ren;
  logic [ADDR_WIDTH-1:0] sram_addr;
  logic [15:0]           sram_din;
  logic [15:0]           sram_dout;

  bootloader #(
      .ADDR_WIDTH(ADDR_WIDTH)
  ) bootloader_instance (
      .clk        (clk),
      .rst_n      (rst_n),
      .cs_asserted(cs_asserted),
      .word_ready (word_ready),
      .rx_word    (rx_word),
      .tx_word    (tx_word),
      .tx_load    (tx_load),
      .sram_men   (sram_men),
      .sram_wen   (sram_wen),
      .sram_ren   (sram_ren),
      .sram_addr  (sram_addr),
      .sram_din   (sram_din),
      .sram_dout  (sram_dout)
  );

  // A_DLY must be tied high per the datasheet; the PDK model stops the simulation otherwise
  RM_IHPSG13_1P_64x16_c2 sram_instance (
      .A_CLK (clk),
      .A_MEN (sram_men),
      .A_WEN (sram_wen),
      .A_REN (sram_ren),
      .A_ADDR(sram_addr),
      .A_DIN (sram_din),
      .A_DLY (1'b1),
      .A_DOUT(sram_dout)
  );

  // CLK generation
  initial begin
    clk = 1'b0;
    forever begin
      #(CLK_PERIOD_NS / 2) clk = ~clk;
    end
  end

  // Golden SRAM contents: write_burst fills it, the monitor checks reads against it
  logic [15:0] expected_mem [DEPTH];

  // These variables are defined at the module level so each task can read/write them.
  int   errors;
  int   write_count;  // SRAM writes since reset
  int   tx_count;     // tx_load pulses since the last reset or read_burst
  int   read_addr;    // Address of the next word the host should receive
  int   reads_left;   // Words the host still expects in the current read burst
  logic monitor_en;

  // Counts an error and reports it
  task automatic fail(input string msg);
    errors++;
    $error("%s", msg);
  endtask

  // Outputs are checked at the rising edge
  always @(posedge clk) begin
    if (monitor_en) begin
      if ($isunknown({sram_men, sram_wen, sram_ren, tx_load}))
        fail("SRAM strobe or tx_load is X");
      if (!sram_men && (sram_wen || sram_ren))
        fail($sformatf("wen=%b ren=%b while men is low", sram_wen, sram_ren));
      if (sram_men && sram_wen && sram_ren)
        fail("wen and ren both high in one access");

      // Monitoring a write even
      if (sram_men && sram_wen)
        write_count++;

      if (tx_load) begin
        tx_count++;
        if (reads_left > 0) begin
          if (tx_word !== expected_mem[read_addr])
            fail($sformatf("read addr %0d: got %h, expected %h", read_addr, tx_word,
                           expected_mem[read_addr]));
          read_addr  = (read_addr + 1) % DEPTH;
          reads_left--;
        end
      end
    end
  end

  // Holds rst_n low for two clock edges, clears the counters, then enables the monitor
  task automatic reset();
    monitor_en  = 1'b0;
    rst_n       = 1'b0;
    cs_asserted = 1'b0;
    word_ready  = 1'b0;
    rx_word     = '0;
    repeat (2) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
    @(negedge clk);
    write_count = 0;
    tx_count    = 0;
    reads_left  = 0;
    // The monitor starts after reset, because the bootloader's outputs are unknown before it
    monitor_en = 1'b1;
  endtask

  // Presents one received word as a one-cycle word_ready pulse
  task automatic send_word(input logic [15:0] word);
    rx_word    = word;
    word_ready = 1'b1;
    @(negedge clk);
    word_ready = 1'b0;
    repeat (CYCLES_BETWEEN_WORDS) @(negedge clk);
  endtask

  // Writes data starting at addr and checks that each word caused exactly one SRAM write
  task automatic write_burst(input int addr, input logic [15:0] data[$]);
    int prev_write_count = write_count;
    int expected_writes  = data.size();
    int actual_writes;
    cs_asserted = 1'b1;
    @(negedge clk);
    send_word(OPCODE_WRITE);
    send_word(16'(addr));
    foreach (data[i]) begin
      send_word(data[i]);
      // updated golden reference 
      expected_mem[(addr + i) % DEPTH] = data[i];
    end
    cs_asserted = 1'b0;

    repeat (2) @(negedge clk);
    actual_writes = write_count - prev_write_count;
    if (actual_writes != expected_writes)
      fail($sformatf("expected %0d SRAM writes, got %0d", expected_writes, actual_writes));
  endtask

  // Reads BurstLen words starting at addr. The monitor checks each word against expected_mem
  task automatic read_burst(input int addr, input int BurstLen);
    read_addr  = addr;
    reads_left = BurstLen;
    tx_count   = 0;
    cs_asserted = 1'b1;
    @(negedge clk);
    send_word(OPCODE_READ);
    send_word(16'(addr));
    // SPI is full duplex, so the host only receives a word while it sends one
    repeat (BurstLen) send_word(16'h0000);
    cs_asserted = 1'b0;
    repeat (2) @(negedge clk);
    if (reads_left != 0) fail($sformatf("%0d read words never arrived", reads_left));
    // The bootloader always loads one word ahead, so the last load is never sent back to the host
    if (tx_count != BurstLen + 1)
      fail($sformatf("expected %0d tx loads, got %0d", BurstLen + 1, tx_count));
  endtask

  // Writes 8 random words, then reads them back
  task automatic test_write_then_read_burst();
    logic [15:0] data[$];
    $display("[%0t] test_write_then_read_burst", $time);
    reset();
    repeat (8) data.push_back(16'($urandom));
    write_burst(5, data);
    read_burst(5, data.size());
  endtask

  // Checks that a one-word write and a one-word read work
  task automatic test_length_one_bursts();
    $display("[%0t] test_length_one_bursts", $time);
    reset();
    write_burst(17, {16'hBEEF});
    read_burst(17, 1);
  endtask

  // Checks that a burst past the last address wraps to address 0
  task automatic test_address_wraps_at_end_of_sram();
    $display("[%0t] test_address_wraps_at_end_of_sram", $time);
    reset();
    write_burst(DEPTH - 2, {16'h1111, 16'h2222, 16'h3333, 16'h4444});
    read_burst(DEPTH - 2, 4);
    // Address 0 must hold the third word, not an older value
    read_burst(0, 2);
  endtask

  // Checks that an unknown opcode sends the bootloader to IGNORE
  task automatic test_unknown_opcode_is_ignored();
    $display("[%0t] test_unknown_opcode_is_ignored", $time);
    reset();

    cs_asserted = 1'b1;
    @(negedge clk);
    // Unknown opcode 
    send_word(16'h1234);
    // Write 
    send_word(OPCODE_WRITE);
    // Address 
    send_word(16'h0000);
    // Word 
    send_word(16'hDEAD);
    cs_asserted = 1'b0;
    repeat (2) @(negedge clk);
    if (write_count != 0) fail("SRAM written during an unknown command");
    if (tx_count != 0) fail("tx_load pulsed during an unknown command");

    // The next transfer is decoded normally
    write_burst(3, {16'hCAFE});
    read_burst(3, 1);
  endtask

  // Checks that deasserting chip select ends a transfer and blocks words sent after it
  task automatic test_chip_select_ends_transfer();
    int prev_write_count;
    $display("[%0t] test_chip_select_ends_transfer", $time);
    reset();

    // The host stops after the address. The next transfer must start from a new opcode, not
    // continue the old burst
    cs_asserted = 1'b1;
    @(negedge clk);
    send_word(OPCODE_WRITE);
    send_word(16'h0008);
    cs_asserted = 1'b0;
    repeat (2) @(negedge clk);
    write_burst(9, {16'hA5A5});
    read_burst(9, 1);

    // A word that arrives while chip select is deasserted never reaches the SRAM
    prev_write_count = write_count;
    cs_asserted = 1'b1;
    @(negedge clk);
    send_word(OPCODE_WRITE);
    send_word(16'h0020);
    cs_asserted = 1'b0;
    send_word(16'h5555);
    @(negedge clk);
    if (write_count != prev_write_count) fail("word written after chip select was deasserted");
  endtask

  initial begin
    errors     = 0;
    monitor_en = 1'b0;

    test_write_then_read_burst();
    test_length_one_bursts();
    test_address_wraps_at_end_of_sram();
    test_unknown_opcode_is_ignored();
    test_chip_select_ends_transfer();

    if (errors == 0) $display("PASS: all bootloader tests passed");
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
