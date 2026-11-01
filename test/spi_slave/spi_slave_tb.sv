/*
 * Copyright (c) 2026 Benjamin Heyfitch
 * SPDX-License-Identifier: Apache-2.0
 */

`timescale 1ns/1ps
`default_nettype none

// Self-checking testbench for spi_slave. The testbench plays the RP2040 as an SPI mode 0
// master, MSB first, with chip select held low for a whole burst. spi_slave drives the real
// bootloader, and the bootloader drives a behavioural SRAM with one cycle of read latency. A
// few unit tests drive tx_word and tx_load directly instead of the bootloader
//
// Master timing is set in clk cycles. The legal range checked here is: sclk period of at least
// 16 clk (ADR-003), sclk low and high phases of at least 4 clk, chip select high for at least
// 5 clk between bursts, and chip select rising at least 3 clk after the last sclk rising edge
//
// Faster timing is run at the end for information only and does not affect the result. Run
// with +seed=<n> to change the random seed. A failing run ends with $fatal
module spi_slave_tb;

  localparam int CLK_PERIOD_NS = 20;
  localparam int DEPTH         = 64;
  // Longest burst: opcode, address and DEPTH + 8 data words, so a write wraps the address
  localparam int FRAME_MAX     = DEPTH + 10;
  // A miso change is expected this many clk edges after the master's sclk falling edge or
  // chip select rising edge: two synchronizer stages, the edge detector and the register
  localparam int EDGE_WIN_MIN  = 3;
  localparam int EDGE_WIN_MAX  = 5;

  logic        clk;
  logic        rst_n;
  logic        sclk;
  logic        cs_n;
  logic        mosi;
  logic        miso;
  logic        cs_asserted;
  logic [15:0] rx_word;
  logic        word_ready;
  logic [15:0] tx_word;
  logic        tx_load;

  logic [15:0] boot_tx_word;
  logic        boot_tx_load;
  logic        sram_men;
  logic        sram_wen;
  logic        sram_ren;
  logic [5:0]  sram_addr;
  logic [15:0] sram_din;
  logic [15:0] sram_dout;

  // In unit tests the testbench drives the slave's tx inputs instead of the bootloader
  logic        tb_tx_mode;
  logic [15:0] tb_tx_word;
  logic        tb_tx_load;

  assign tx_word = tb_tx_mode ? tb_tx_word : boot_tx_word;
  assign tx_load = tb_tx_mode ? tb_tx_load : boot_tx_load;

  spi_slave dut (
      .clk        (clk),
      .rst_n      (rst_n),
      .sclk       (sclk),
      .cs_n       (cs_n),
      .mosi       (mosi),
      .miso       (miso),
      .cs_asserted(cs_asserted),
      .rx_word    (rx_word),
      .word_ready (word_ready),
      .tx_word    (tx_word),
      .tx_load    (tx_load)
  );

  bootloader bootloader_instance (
      .clk        (clk),
      .rst_n      (rst_n),
      .cs_asserted(cs_asserted),
      .word_ready (word_ready),
      .rx_word    (rx_word),
      .tx_word    (boot_tx_word),
      .tx_load    (boot_tx_load),
      .sram_men   (sram_men),
      .sram_wen   (sram_wen),
      .sram_ren   (sram_ren),
      .sram_addr  (sram_addr),
      .sram_din   (sram_din),
      .sram_dout  (sram_dout)
  );

  // Behavioural stand-in for the IHP 64x16 SRAM: synchronous write, and read data that appears
  // after the edge that samples the read and holds until the next read
  logic [15:0] sram_mem [DEPTH];

  always_ff @(posedge clk) begin
    if (sram_men) begin
      if (sram_wen) sram_mem[sram_addr] <= sram_din;
      if (sram_ren) sram_dout <= sram_mem[sram_addr];
    end
  end

  initial clk = 1'b0;
  always #(CLK_PERIOD_NS / 2) clk = ~clk;

  integer      seed;
  int          errors;
  // In quiet mode a failed check is counted but not reported. Used for the informational runs
  bit          quiet;

  // Master timing, in clk cycles. Each sclk phase is picked from [min, max], and the high phase
  // is stretched if needed so that one sclk period is at least period_min
  int          lo_min;
  int          lo_max;
  int          hi_min;
  int          hi_max;
  int          period_min;
  // When set, mosi changes on a random cycle of the low phase instead of at the falling edge,
  // always at least two cycles before the rising edge
  bit          mosi_skew;
  // Cycles from chip select falling to the start of the first bit's low phase
  int          cs_setup;
  // With final_fall set, sclk falls after the last bit and chip select rises cs_hold cycles
  // later. Without it, chip select rises cs_hold cycles after the last rising edge while sclk
  // is still high, and sclk falls two cycles after that
  bit          final_fall;
  int          cs_hold;
  // Cycles chip select stays high after a burst
  int          cs_gap;
  // Extra cycles with sclk held high after the 16th bit of a word, and held low after the word
  int          pause_hi;
  int          pause_lo;
  // Bits of word n sent before chip select rises in an aborted burst
  int          abort_bits;

  // Monitor state
  bit          monitor_en;
  int          rx_count;
  int          write_count;
  logic [15:0] rx_log [FRAME_MAX];
  logic        word_ready_prev;
  logic [15:0] rx_word_prev;
  logic        miso_prev;
  logic        tx_load_prev;
  // Clk edges since the master last drove sclk low, and since chip select last rose
  int          since_fall;
  int          since_cs_rise;

  logic [15:0] frame [FRAME_MAX];
  logic [15:0] data [FRAME_MAX];
  logic [15:0] master_rx [FRAME_MAX];
  logic [15:0] expected_mem [DEPTH];

  task automatic fail(input string msg);
    errors++;
    if (!quiet) $error("%s", msg);
  endtask

  function automatic int pick(input int lo_v, input int hi_v);
    int r;
    r = $random(seed) & 32'h7fff_ffff;
    return lo_v + (r % (hi_v - lo_v + 1));
  endfunction

  // Checks every rising clk edge. Values read here are the ones that edge samples
  always @(posedge clk) begin
    since_fall++;
    since_cs_rise++;
    if (monitor_en) begin
      if ((^{cs_asserted, word_ready, rx_word}) === 1'bx)
        fail("cs_asserted, word_ready or rx_word is X");

      if (word_ready) begin
        if (word_ready_prev) fail("word_ready high for more than one cycle");
        // Every word the slave reports must reach the bootloader as a valid word
        if (!cs_asserted) fail("word_ready pulsed while cs_asserted is low");
        if (rx_count < FRAME_MAX) rx_log[rx_count] = rx_word;
        rx_count++;
      end

      // rx_word may only change together with a word_ready pulse
      if (rx_word !== rx_word_prev && !word_ready)
        fail($sformatf("rx_word changed from %h to %h without word_ready", rx_word_prev,
                       rx_word));

      if (sram_men && sram_wen) write_count++;

      // miso may change only after a load, after an sclk falling edge or after chip select rises
      if (miso !== miso_prev && !tx_load_prev &&
          !(since_fall >= EDGE_WIN_MIN && since_fall <= EDGE_WIN_MAX) &&
          !(since_cs_rise >= EDGE_WIN_MIN && since_cs_rise <= EDGE_WIN_MAX))
        fail($sformatf("miso changed %b to %b %0d edges after an sclk fall", miso_prev, miso,
                       since_fall));

      // Once chip select has been high long enough to reach the slave, miso must idle at 0
      if (cs_n && since_cs_rise > EDGE_WIN_MAX && miso !== 1'b0)
        fail($sformatf("miso is %b while deselected", miso));
    end
    word_ready_prev = word_ready;
    rx_word_prev    = rx_word;
    miso_prev       = miso;
    tx_load_prev    = tx_load;
  end

  task automatic wait_cycles(input int n);
    repeat (n) @(negedge clk);
  endtask

  task automatic set_default_timing();
    lo_min     = 8;
    lo_max     = 8;
    hi_min     = 8;
    hi_max     = 8;
    period_min = 16;
    mosi_skew  = 1'b0;
    cs_setup   = 8;
    final_fall = 1'b1;
    cs_hold    = 8;
    cs_gap     = 32;
    pause_hi   = 0;
    pause_lo   = 0;
    abort_bits = 0;
  endtask

  task automatic set_half(input int half);
    lo_min = half;
    lo_max = half;
    hi_min = half;
    hi_max = half;
  endtask

  task automatic clear_counts();
    rx_count    = 0;
    write_count = 0;
  endtask

  task automatic reset();
    monitor_en = 1'b0;
    rst_n      = 1'b0;
    sclk       = 1'b0;
    cs_n       = 1'b1;
    mosi       = 1'b0;
    tb_tx_mode = 1'b0;
    tb_tx_word = '0;
    tb_tx_load = 1'b0;
    wait_cycles(3);
    rst_n = 1'b1;
    wait_cycles(3);
    clear_counts();
    since_cs_rise = 1000;
    monitor_en    = 1'b1;
  endtask

  task automatic raise_cs();
    cs_n          = 1'b1;
    since_cs_rise = 0;
  endtask

  // Shifts one bit each way. In mode 0 the master changes mosi while sclk is low and samples
  // miso on the rising edge of sclk. The rising edge is driven on a falling clk edge, between
  // the slave's register updates, so the miso value taken here is the settled value a real
  // master would see. The rising-edge monitor separately checks when miso is allowed to change
  task automatic shift_bit(input logic bit_out, output logic bit_in, input int extra_hi,
                           input bit is_last);
    int lo;
    int hi;
    int k;
    lo = pick(lo_min, lo_max);
    hi = pick(hi_min, hi_max);
    if (lo + hi < period_min) hi = period_min - lo;
    if (mosi_skew) begin
      k = pick(0, lo - 2);
      wait_cycles(k);
      mosi = bit_out;
      wait_cycles(lo - k);
    end else begin
      mosi = bit_out;
      wait_cycles(lo);
    end
    sclk   = 1'b1;
    bit_in = miso;
    if (is_last && !final_fall) begin
      wait_cycles(cs_hold);
      raise_cs();
      wait_cycles(2);
      sclk       = 1'b0;
      since_fall = 0;
    end else begin
      wait_cycles(hi + extra_hi);
      sclk       = 1'b0;
      since_fall = 0;
      if (is_last) begin
        wait_cycles(cs_hold);
        raise_cs();
      end
    end
  endtask

  // Sends the first n words of frame in one chip-select frame, then abort_bits bits of word n,
  // and stores what came back on miso in master_rx
  task automatic burst(input int n);
    logic b;
    cs_n = 1'b0;
    wait_cycles(cs_setup);
    for (int w = 0; w < n; w++) begin
      for (int i = 15; i >= 0; i--) begin
        shift_bit(frame[w][i], b, (i == 0) ? pause_hi : 0,
                  (w == n - 1) && (i == 0) && (abort_bits == 0));
        master_rx[w][i] = b;
      end
      if (!(w == n - 1 && abort_bits == 0)) wait_cycles(pause_lo);
    end
    for (int j = 0; j < abort_bits; j++) begin
      shift_bit(frame[n][15 - j], b, 0, j == abort_bits - 1);
    end
    wait_cycles(cs_gap);
  endtask

  task automatic check_rx(input int first, input int n, input string name);
    for (int i = 0; i < n; i++) begin
      if (rx_log[first + i] !== frame[i])
        fail($sformatf("%s: word %0d received as %h, expected %h", name, i, rx_log[first + i],
                       frame[i]));
    end
  endtask

  task automatic write_mem(input int addr, input int n, input string name);
    int rx_before;
    frame[0] = 16'h0002;
    frame[1] = 16'(addr);
    for (int i = 0; i < n; i++) begin
      frame[i + 2]                     = data[i];
      expected_mem[(addr + i) % DEPTH] = data[i];
    end
    rx_before   = rx_count;
    write_count = 0;
    burst(n + 2);
    if (rx_count - rx_before != n + 2)
      fail($sformatf("%s: %0d words reached the bootloader, expected %0d", name,
                     rx_count - rx_before, n + 2));
    if (write_count != n)
      fail($sformatf("%s: %0d SRAM writes, expected %0d", name, write_count, n));
    for (int i = 0; i < n && i < DEPTH; i++) begin
      if (sram_mem[(addr + n - 1 - i) % DEPTH] !== expected_mem[(addr + n - 1 - i) % DEPTH])
        fail($sformatf("%s: SRAM[%0d] holds %h, expected %h", name, (addr + n - 1 - i) % DEPTH,
                       sram_mem[(addr + n - 1 - i) % DEPTH],
                       expected_mem[(addr + n - 1 - i) % DEPTH]));
    end
  endtask

  // A read of n words needs n placeholder words after the opcode and address. Word i + 2 on
  // miso is the word at address addr + i. Nothing meaningful is loaded during the opcode and
  // address words, so miso must be 0 for both
  task automatic read_mem_and_check(input int addr, input int n, input string name);
    frame[0] = 16'h0003;
    frame[1] = 16'(addr);
    for (int i = 0; i < n; i++) frame[i + 2] = 16'(pick(0, 65535));
    burst(n + 2);
    if (master_rx[0] !== 16'h0000 || master_rx[1] !== 16'h0000)
      fail($sformatf("%s: miso sent %h %h during opcode and address, expected 0", name,
                     master_rx[0], master_rx[1]));
    for (int i = 0; i < n; i++) begin
      if (master_rx[i + 2] !== expected_mem[(addr + i) % DEPTH])
        fail($sformatf("%s: word %0d from address %0d read %h, expected %h", name, i,
                       (addr + i) % DEPTH, master_rx[i + 2], expected_mem[(addr + i) % DEPTH]));
    end
  endtask

  task automatic write_then_read(input int addr, input int n, input string name);
    for (int i = 0; i < n; i++) data[i] = 16'(pick(0, 65535));
    write_mem(addr, n, name);
    read_mem_and_check(addr, (n < DEPTH) ? n : DEPTH, name);
  endtask

  task automatic test_receive_words(input string name);
    reset();
    frame[0] = 16'h1234;
    frame[1] = 16'hA5C3;
    frame[2] = 16'hFFFF;
    frame[3] = 16'h0000;
    frame[4] = 16'h8001;
    frame[5] = 16'h7FFE;
    burst(6);
    if (rx_count != 6) fail($sformatf("%s: received %0d words, expected 6", name, rx_count));
    check_rx(0, 6, name);
  endtask

  // The core set run at every legal timing setting
  task automatic run_core(input string name);
    test_receive_words(name);
    reset();
    write_then_read(5, 8, name);
    write_then_read(17, 1, name);
    write_then_read(62, 4, name);
  endtask

  // Chip select rises after 7 bits. The partial word must be dropped and the next transfer must
  // start from bit 15 again
  task automatic test_partial_word_is_dropped();
    $display("[%0t] test_partial_word_is_dropped", $time);
    reset();
    frame[0]   = 16'hFFFF;
    abort_bits = 7;
    burst(0);
    abort_bits = 0;
    if (rx_count != 0) fail($sformatf("partial word: %0d words reported", rx_count));
    frame[0] = 16'h1234;
    burst(1);
    if (rx_count != 1) fail($sformatf("partial word: received %0d words, expected 1", rx_count));
    check_rx(0, 1, "partial word");
  endtask

  // sclk pulses while chip select is high must not be counted or move miso
  task automatic test_sclk_ignored_while_deselected();
    $display("[%0t] test_sclk_ignored_while_deselected", $time);
    reset();
    repeat (5) begin
      mosi = 1'b1;
      wait_cycles(8);
      sclk = 1'b1;
      wait_cycles(8);
      sclk       = 1'b0;
      since_fall = 0;
    end
    if (rx_count != 0) fail("deselected sclk: a word was reported");
    frame[0] = 16'hBEEF;
    burst(1);
    if (rx_count != 1) fail($sformatf("deselected sclk: %0d words, expected 1", rx_count));
    check_rx(0, 1, "deselected sclk");
  endtask

  // An unknown opcode must be ignored until chip select rises, then a normal burst must work
  task automatic test_unknown_opcode();
    $display("[%0t] test_unknown_opcode", $time);
    reset();
    frame[0]    = 16'h1234;
    frame[1]    = 16'h0002;
    frame[2]    = 16'h0005;
    frame[3]    = 16'hAAAA;
    frame[4]    = 16'h5555;
    write_count = 0;
    burst(5);
    if (rx_count != 5) fail($sformatf("unknown opcode: %0d words, expected 5", rx_count));
    if (write_count != 0) fail($sformatf("unknown opcode: %0d SRAM writes", write_count));
    write_then_read(5, 3, "after unknown opcode");
  endtask

  // Both ends of the memory and a write burst longer than the memory
  task automatic test_memory_size_bursts();
    $display("[%0t] test_memory_size_bursts", $time);
    reset();
    write_then_read(0, DEPTH, "full memory");
    reset();
    // 70 data words from address 10 wrap and overwrite addresses 10 to 15
    write_then_read(10, DEPTH + 6, "write longer than memory");
  endtask

  // A read aborted in the middle of a word must leave miso at 0, and the next read must be
  // correct from its first word
  task automatic test_read_aborted_mid_word();
    $display("[%0t] test_read_aborted_mid_word", $time);
    reset();
    for (int i = 0; i < 6; i++) data[i] = 16'(pick(0, 65535));
    write_mem(20, 6, "aborted read setup");
    frame[0]   = 16'h0003;
    frame[1]   = 16'd20;
    frame[2]   = 16'h0000;
    frame[3]   = 16'h0000;
    frame[4]   = 16'h0000;
    abort_bits = 7;
    burst(4);
    abort_bits = 0;
    if (master_rx[2] !== expected_mem[20] || master_rx[3] !== expected_mem[21])
      fail("aborted read: words before the abort were wrong");
    read_mem_and_check(22, 4, "read after aborted read");
  endtask

  // Bursts separated by the minimum chip select high time of 5 clk
  task automatic test_min_cs_gap();
    $display("[%0t] test_min_cs_gap", $time);
    reset();
    cs_gap = 5;
    for (int i = 0; i < 4; i++) data[i] = 16'(pick(0, 65535));
    write_mem(40, 4, "min cs gap write 1");
    for (int i = 0; i < 4; i++) data[i] = 16'(pick(0, 65535));
    write_mem(44, 4, "min cs gap write 2");
    read_mem_and_check(40, 8, "min cs gap read");
    read_mem_and_check(42, 2, "min cs gap second read");
    set_default_timing();
  endtask

  // The first sclk rising edge at the minimum 4 clk after chip select falls
  task automatic test_min_cs_setup();
    $display("[%0t] test_min_cs_setup", $time);
    reset();
    cs_setup = 0;
    set_half(4);
    period_min = 16;
    write_then_read(30, 4, "min cs setup");
    set_default_timing();
  endtask

  // Chip select rising 3 clk after the last sclk rising edge, with and without a final falling
  // edge before it. The last word must still be written
  task automatic test_min_cs_hold();
    $display("[%0t] test_min_cs_hold", $time);
    reset();
    final_fall = 1'b0;
    cs_hold    = 3;
    write_then_read(50, 4, "min cs hold, no final fall");
    final_fall = 1'b1;
    cs_hold    = 0;
    write_then_read(54, 4, "cs rises with the final fall");
    set_default_timing();
  endtask

  // Long pauses inside a burst. With sclk held high after bit 16 the next word is loaded long
  // before the 16th falling edge, and with sclk held low the loaded MSB must stay on miso
  task automatic test_pauses_inside_burst();
    $display("[%0t] test_pauses_inside_burst", $time);
    reset();
    pause_hi = 300;
    write_then_read(8, 4, "pause high");
    pause_hi = 0;
    pause_lo = 300;
    write_then_read(12, 4, "pause low");
    set_default_timing();
  endtask

  // tx_load driven directly. A load in the cycle a falling edge would shift (bit counter 5)
  // must win over the shift
  task automatic test_load_priority_over_shift();
    logic [15:0] w_first;
    logic [15:0] w_new;
    $display("[%0t] test_load_priority_over_shift", $time);
    reset();
    tb_tx_mode = 1'b1;
    w_first    = 16'hA5A5;
    w_new      = 16'h3C3C;
    frame[0]   = 16'h0000;
    fork
      burst(1);
      begin
        do @(negedge clk); while (!cs_asserted);
        tb_tx_word = w_first;
        tb_tx_load = 1'b1;
        @(negedge clk);
        tb_tx_load = 1'b0;
        do @(negedge clk); while (!(dut.sclk_fall && dut.bit_cnt_q == 4'd5));
        tb_tx_word = w_new;
        tb_tx_load = 1'b1;
        @(negedge clk);
        tb_tx_load = 1'b0;
      end
    join
    if (master_rx[0] !== {w_first[15:11], w_new[15:5]})
      fail($sformatf("load vs shift: master read %h, expected %h", master_rx[0],
                     {w_first[15:11], w_new[15:5]}));
  endtask

  // tx_load driven directly in the cycle the 16th falling edge is detected (bit counter 0). The
  // new word's MSB must be the first bit of the next word
  task automatic test_load_on_16th_fall();
    logic [15:0] w_first;
    logic [15:0] w_new;
    $display("[%0t] test_load_on_16th_fall", $time);
    reset();
    tb_tx_mode = 1'b1;
    w_first    = 16'h8001;
    w_new      = 16'hC003;
    frame[0]   = 16'h0000;
    frame[1]   = 16'h0000;
    fork
      burst(2);
      begin
        do @(negedge clk); while (!cs_asserted);
        tb_tx_word = w_first;
        tb_tx_load = 1'b1;
        @(negedge clk);
        tb_tx_load = 1'b0;
        do @(negedge clk); while (!(dut.sclk_fall && dut.bit_cnt_q == 4'd0));
        tb_tx_word = w_new;
        tb_tx_load = 1'b1;
        @(negedge clk);
        tb_tx_load = 1'b0;
      end
    join
    if (master_rx[0] !== w_first || master_rx[1] !== w_new)
      fail($sformatf("load on 16th fall: master read %h %h, expected %h %h", master_rx[0],
                     master_rx[1], w_first, w_new));
  endtask

  // A load while deselected must not reach miso. The monitor checks miso stays 0
  task automatic test_load_while_deselected();
    $display("[%0t] test_load_while_deselected", $time);
    reset();
    tb_tx_mode = 1'b1;
    wait_cycles(10);
    tb_tx_word = 16'hFFFF;
    tb_tx_load = 1'b1;
    @(negedge clk);
    tb_tx_load = 1'b0;
    wait_cycles(10);
    if (miso !== 1'b0) fail("load while deselected reached miso");
  endtask

  // Reset in the middle of a write burst. No write may happen after reset, and a clean burst
  // afterwards must work
  task automatic test_reset_mid_burst();
    logic b;
    $display("[%0t] test_reset_mid_burst", $time);
    reset();
    frame[0] = 16'h0002;
    frame[1] = 16'd3;
    frame[2] = 16'hDEAD;
    cs_n     = 1'b0;
    wait_cycles(cs_setup);
    for (int w = 0; w < 2; w++) begin
      for (int i = 15; i >= 0; i--) shift_bit(frame[w][i], b, 0, 1'b0);
    end
    for (int i = 15; i >= 11; i--) shift_bit(frame[2][i], b, 0, 1'b0);
    monitor_en = 1'b0;
    rst_n      = 1'b0;
    wait_cycles(2);
    raise_cs();
    wait_cycles(2);
    rst_n = 1'b1;
    wait_cycles(4);
    clear_counts();
    monitor_en = 1'b1;
    wait_cycles(cs_gap);
    if (write_count != 0) fail("reset mid burst: an SRAM write happened after reset");
    write_then_read(3, 2, "after reset mid burst");
  endtask

  initial begin
    int errors_at_info;
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    $display("seed = %0d", seed);
    errors = 0;
    quiet  = 1'b0;
    set_default_timing();

    $display("[%0t] core at clk/16", $time);
    run_core("clk/16");
    test_partial_word_is_dropped();
    test_sclk_ignored_while_deselected();
    test_unknown_opcode();
    test_memory_size_bursts();
    test_read_aborted_mid_word();
    test_min_cs_gap();
    test_min_cs_setup();
    test_min_cs_hold();
    test_pauses_inside_burst();
    test_load_priority_over_shift();
    test_load_on_16th_fall();
    test_load_while_deselected();
    test_reset_mid_burst();

    // Slower sclk is also legal
    for (int k = 0; k < 4; k++) begin
      int half_slow;
      half_slow = (k == 0) ? 9 : (k == 1) ? 13 : (k == 2) ? 25 : 100;
      $display("[%0t] core at clk/%0d", $time, 2 * half_slow);
      set_default_timing();
      set_half(half_slow);
      run_core($sformatf("clk/%0d", 2 * half_slow));
    end

    // Uneven duty cycle at the fastest legal period
    $display("[%0t] core with low 4, high 12", $time);
    set_default_timing();
    lo_min = 4;
    lo_max = 4;
    hi_min = 12;
    hi_max = 12;
    run_core("low 4 high 12");
    $display("[%0t] core with low 12, high 4", $time);
    lo_min = 12;
    lo_max = 12;
    hi_min = 4;
    hi_max = 4;
    run_core("low 12 high 4");

    // Random phase lengths and mosi timing, within the legal range
    for (int k = 0; k < 3; k++) begin
      $display("[%0t] core with jittered sclk and mosi, pass %0d", $time, k);
      set_default_timing();
      lo_min    = 4;
      lo_max    = 14;
      hi_min    = 4;
      hi_max    = 14;
      mosi_skew = 1'b1;
      run_core($sformatf("jitter pass %0d", k));
    end

    if (errors == 0) $display("PASS at all legal timings");

    // Faster sclk is outside the ADR-003 limit. These runs only report where reads stop
    // working with this testbench's fixed clk-to-sclk phase
    errors_at_info = errors;
    quiet          = 1'b1;
    for (int h = 7; h >= 2; h--) begin
      int errors_before;
      errors_before = errors;
      set_default_timing();
      set_half(h);
      period_min = 0;
      reset();
      write_then_read(5, 8, "informational");
      $display("info: sclk = clk/%0d %s", 2 * h,
               (errors == errors_before) ? "passes" : "fails");
    end
    errors = errors_at_info;
    quiet  = 1'b0;

    if (errors == 0) begin
      $display("PASS: all spi_slave tests passed");
      $finish;
    end else begin
      $fatal(1, "FAIL: %0d error(s)", errors);
    end
  end

  initial begin
    #500ms;
    $fatal(1, "watchdog: simulation hung");
  end

endmodule

`default_nettype wire
