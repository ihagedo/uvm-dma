// File:        dma_probe_tb.sv
// Author:      Isaac Hagedorn
// Date:        2026-10-08
// Description: Directed probe of the DMA behaviours the spec claims. Prints PASS or FAIL per check.

`timescale 1ns / 10ps
`default_nettype none

// Word memory behind an AHB port: latency wait states per transfer, ERROR at or above NREGS words.
module probe_mem #(
    parameter int NREGS = 4096
) (
    input logic CLK,
    input logic nRST,
    input int latency,
    ahb_if.subordinate s
);
  logic [31:0] regs[NREGS];
  logic act, wr, e, e2;   // data phase active, write, ERROR, second ERROR cycle
  logic [31:0] a;
  int w;   // wait states left
  logic ready;

  assign ready = !act || (w == 0 && (!e || e2));
  assign s.HREADYOUT = ready;
  assign s.HRESP = act && e && (w == 0);
  assign s.HRDATA = (act && !wr && !e) ? regs[a[$clog2(NREGS)+1:2]] : '0;

  always @(posedge CLK or negedge nRST) begin
    if (!nRST) begin
      {act, e2} <= '0;
      w <= 0;
    end else begin
      if (act && w > 0) w <= w - 1;
      else if (act && e && !e2) e2 <= 1;
      else if (act) begin
        if (wr && !e)
          for (int i = 0; i < 4; i++)
            if (s.HWSTRB[i]) regs[a[$clog2(NREGS)+1:2]][8*i+:8] <= s.HWDATA[8*i+:8];
        act <= 0;
      end
      if (ready && s.HSEL && s.HTRANS[1]) begin
        act <= 1;
        a <= s.HADDR;
        wr <= s.HWRITE;
        w <= latency;
        e <= (s.HADDR >= 32'(4 * NREGS));
        e2 <= 0;
      end
    end
  end
endmodule
`ifndef NCH
`define NCH 8
`endif
`ifndef FDEPTH
`define FDEPTH 16
`endif

module dma_probe_tb;
  localparam int NUM_CHANNELS = `NCH;
  localparam int NUM_SOURCES = 32;
  localparam logic [31:0] BASE = 32'h9000_1000;
  localparam int MEM_NREGS = 4096;
  localparam int STAT0 = NUM_CHANNELS * 16;
  localparam int TRIG0 = NUM_CHANNELS * 32;
  localparam logic [2:0] ONESHOT = 3'd0, CONTINUOUS = 3'd1, RING = 3'd2;
  localparam logic [1:0] BYTE = 2'd0, HALF = 2'd1, WORD = 2'd2;

  logic CLK = 0, nRST = 0, dma_interrupt;
  logic [NUM_SOURCES-1:0] trigger_in = '0;
  int src_lat = 0, dst_lat = 0;
  int fails = 0;
  always #5 CLK = ~CLK;

  ahb_if reg_if (.HCLK(CLK), .HRESETn(nRST));
  ahb_if rd_if (.HCLK(CLK), .HRESETn(nRST));
  ahb_if wr_if (.HCLK(CLK), .HRESETn(nRST));

  dma_controller #(.NUM_CHANNELS(NUM_CHANNELS), .NUM_SOURCES(NUM_SOURCES), .FIFO_DEPTH(`FDEPTH)) DUT (
      .CLK(CLK), .nRST(nRST),
      .ahb_sub_if(reg_if.subordinate), .read_manager_if(rd_if.manager),
      .write_manager_if(wr_if.manager), .trigger_in(trigger_in), .dma_interrupt(dma_interrupt));

  probe_mem #(.NREGS(MEM_NREGS)) src_mem (.CLK(CLK), .nRST(nRST), .latency(src_lat), .s(rd_if.subordinate));
  probe_mem #(.NREGS(MEM_NREGS)) dst_mem (.CLK(CLK), .nRST(nRST), .latency(dst_lat), .s(wr_if.subordinate));

  int cyc = 0;
  int wch = 0;   // channel being watched
  int rd_n, wr_n, c_rd1, c_wr1, c_wrN, c_done, c_irq, c_ctrl;
  bit rd_pend, wr_pend, done_seen, irq_seen;
  logic [31:0] rd_addr_q[$], wr_addr_q[$];
  logic [2:0] rd_size_q[$], wr_size_q[$];
  logic [3:0] wr_strb_q[$];
  bit wr_resp_q[$];
  logic [2:0] rd_burst_q[$], wr_burst_q[$];
  logic [1:0] rd_trans_q[$], wr_trans_q[$];
  bit tl_on = 0;
  string tl_rows[$];
  int tl_cyc[$];
  int collisions = 0, lost = 0;
  bit col_check = 0;

  function automatic string tr(input logic [1:0] t);
    case (t)
      2'b00: return "IDLE";
      2'b01: return "BUSY";
      2'b10: return "NONSEQ";
      default: return "SEQ";
    endcase
  endfunction

  always @(posedge CLK) begin
    string rd_a, rd_d, wr_a, wr_d;
    rd_a = "";
    rd_d = "";
    wr_a = "";
    wr_d = "";
    if (nRST) begin
      if (DUT.engine.ch_manager.control_written && DUT.engine.ch_manager.write_channel == wch[$clog2(NUM_CHANNELS)-1:0])
        c_ctrl = cyc;
      if (rd_pend && rd_if.HREADY) rd_d = $sformatf("`%h`", rd_if.HRDATA);
      if (rd_if.HREADY) begin
        if (rd_if.HTRANS[1]) begin
          rd_n++;
          if (c_rd1 < 0) c_rd1 = cyc;
          rd_addr_q.push_back(rd_if.HADDR);
          rd_size_q.push_back(rd_if.HSIZE);
          rd_burst_q.push_back(rd_if.HBURST);
          rd_trans_q.push_back(rd_if.HTRANS);
        end
        rd_pend = rd_if.HTRANS[1];
      end
      if (rd_if.HTRANS != 2'b00)
        rd_a = $sformatf("%s %s `%h`", tr(rd_if.HTRANS), rd_if.HBURST == 3'b011 ? "INCR4" : "SINGLE",
                         rd_if.HADDR[15:0]);
      if (wr_pend && wr_if.HREADY) begin
        wr_d = $sformatf("`%h`", wr_if.HWDATA);
        wr_strb_q.push_back(wr_if.HWSTRB);
        wr_resp_q.push_back(wr_if.HRESP);
        c_wrN = cyc;
      end
      if (wr_if.HREADY) begin
        if (wr_if.HTRANS[1]) begin
          wr_n++;
          if (c_wr1 < 0) c_wr1 = cyc;
          wr_addr_q.push_back(wr_if.HADDR);
          wr_size_q.push_back(wr_if.HSIZE);
          wr_burst_q.push_back(wr_if.HBURST);
          wr_trans_q.push_back(wr_if.HTRANS);
        end
        wr_pend = wr_if.HTRANS[1];
      end
      if (wr_if.HTRANS != 2'b00)
        wr_a = $sformatf("%s %s `%h`", tr(wr_if.HTRANS), wr_if.HBURST == 3'b011 ? "INCR4" : "SINGLE",
                         wr_if.HADDR[15:0]);
      if (!done_seen && DUT.engine.channel_control[wch][27]) begin
        done_seen = 1;
        c_done = cyc;
      end
      if (!irq_seen && dma_interrupt) begin
        irq_seen = 1;
        c_irq = cyc;
      end
      if (col_check && DUT.engine.ch_manager.control_written &&
          (DUT.engine.ch_manager.pass_done[wch] || DUT.engine.ch_manager.oneshot_done[wch]) &&
          DUT.engine.ch_manager.write_channel == wch[$clog2(NUM_CHANNELS)-1:0]) begin
        collisions++;
        #1;
        if (!DUT.engine.channel_control[wch][27]) lost++;
      end
      if (tl_on) begin
        tl_cyc.push_back(cyc);
        tl_rows.push_back($sformatf("| %0d | %s | %s | %s | %s | %b | %b |",
                                    DUT.engine.channel_control[wch][7], rd_a == "" ? "" : rd_a,
                                    rd_d, wr_a, wr_d, DUT.engine.channel_control[wch][27],
                                    dma_interrupt));
      end
    end
    cyc++;
  end

  task automatic watch(input int ch);
    wch = ch;
    {rd_n, wr_n} = '0;
    {c_rd1, c_wr1, c_wrN, c_done, c_irq, c_ctrl} = {-1, -1, -1, -1, -1, -1};
    {done_seen, irq_seen} = '0;
    rd_addr_q.delete();
    wr_addr_q.delete();
    rd_size_q.delete();
    wr_size_q.delete();
    wr_strb_q.delete();
    wr_resp_q.delete();
    rd_burst_q.delete();
    wr_burst_q.delete();
    rd_trans_q.delete();
    wr_trans_q.delete();
  endtask

  task automatic bus(input bit write, input logic [31:0] off, input logic [31:0] wdata,
                     input logic [2:0] size, input logic [3:0] strb, output logic [31:0] rdata,
                     output bit err);
    @(negedge CLK);
    reg_if.HSEL = 1;
    reg_if.HWRITE = write;
    reg_if.HADDR = BASE + off;
    reg_if.HTRANS = 2'b10;
    reg_if.HSIZE = size;
    reg_if.HBURST = 3'b000;
    @(negedge CLK);
    reg_if.HTRANS = 2'b00;
    reg_if.HWRITE = 0;
    reg_if.HADDR = '0;
    reg_if.HWDATA = wdata;
    reg_if.HWSTRB = strb;
    err = 0;
    forever begin
      #1;
      if (reg_if.HRESP) err = 1;
      if (reg_if.HREADY) begin
        rdata = reg_if.HRDATA;
        break;
      end
      @(negedge CLK);
    end
    @(posedge CLK);
    #1;
  endtask

  task automatic chk(input string id, input bit ok, input string what);
    if (ok) $display("PASS %s  %s", id, what);
    else begin
      $display("FAIL %s  %s", id, what);
      fails++;
    end
  endtask

  task automatic wr(input logic [31:0] off, input logic [31:0] d);
    logic [31:0] r;
    bit e;
    bus(1, off, d, 3'b010, 4'hF, r, e);
    if (e) begin
      $display("FAIL bus  unexpected error writing %h", off);
      fails++;
    end
  endtask

  task automatic rd(input logic [31:0] off, output logic [31:0] d);
    bit e;
    bus(0, off, '0, 3'b010, 4'h0, d, e);
    if (e) begin
      $display("FAIL bus  unexpected error reading %h", off);
      fails++;
    end
  endtask

  function automatic logic [31:0] ctrl(input logic [2:0] mode, input logic [1:0] size = WORD,
                                       input int si = 4, input int di = 4, input bit en = 1);
    return {8'd0, 8'(di), 8'(si), en, mode, 2'b00, size};
  endfunction

  function automatic int C(input int ch, input int r);
    return 16 * ch + r;
  endfunction
  function automatic int S(input int ch, input int r);
    return STAT0 + 16 * ch + r;
  endfunction
  function automatic int TC(input int ch);
    return TRIG0 + 8 * ch;
  endfunction

  task automatic idle_wait(input int max = 4000);
    int c = 0;
    repeat (12) @(posedge CLK);
    while ((DUT.r_transfer_active || DUT.w_transfer_active || !DUT.raddr_fifo_empty ||
            !DUT.waddr_fifo_empty || !DUT.tdata_fifo_empty) && c < max) begin
      @(posedge CLK);
      c++;
    end
    repeat (4) @(posedge CLK);
    #1;
  endtask

  task automatic configure(input int ch, input logic [31:0] s, input logic [31:0] d, input int n,
                           input logic [31:0] cw);
    wr(C(ch, 0), s);
    wr(C(ch, 4), d);
    wr(C(ch, 12), n);
    wr(C(ch, 8), cw);
  endtask

  task automatic do_reset();
    nRST = 0;
    reg_if.HSEL = 1;
    reg_if.HTRANS = 2'b00;
    reg_if.HWRITE = 0;
    reg_if.HADDR = '0;
    reg_if.HWSTRB = 4'hF;
    reg_if.HWDATA = '0;
    repeat (3) @(posedge CLK);
    #2 nRST = 1;
    repeat (2) @(posedge CLK);
    for (int i = 0; i < MEM_NREGS; i++) begin
      src_mem.regs[i] = 32'hA0A0_0000 + 32'(i);
      dst_mem.regs[i] = 32'h5555_5555;
    end
  endtask

  task automatic t_reset();
    logic [31:0] v;
    bit ok = 1;
    int chans[2] = '{0, NUM_CHANNELS - 1};
    foreach (chans[k]) begin
      for (int r = 0; r < 16; r += 4) begin
        rd(C(chans[k], r), v);
        if (v !== 0) ok = 0;
        rd(S(chans[k], r), v);
        if (v !== 0) ok = 0;
      end
    end
    chk("REG-RESET-1", ok, "SOURCE/DESTINATION/CONTROL/DESIRED_TRANSFERS and all 4 status registers read 0 after reset");
    rd(TC(NUM_CHANNELS - 1), v);
    chk("REG-RESET-2", v === 32'h0001_0000, $sformatf("TRIGGER_CONFIG resets to 0x0001_0000 (got %h)", v));
    rd(TC(NUM_CHANNELS - 1) + 4, v);
    chk("REG-RESET-3", v === 0, "TRIGGER_STATUS resets to 0");
    chk("REG-RESET-4", dma_interrupt === 0, "dma_interrupt is 0 after reset");
  endtask

  task automatic t_regs();
    logic [31:0] v;
    bit e;
    wr(C(2, 0), 32'hDEAD_BEE1);
    rd(C(2, 0), v);
    chk("REG-RW-1", v === 32'hDEAD_BEE1, "SOURCE stores all 32 bits, unaligned values included");
    wr(C(2, 12), 32'hFFFF_FFFF);
    rd(C(2, 12), v);
    chk("REG-RW-2", v === 32'hFFFF_FFFF, "DESIRED_TRANSFERS stores all 32 bits");
    wr(C(2, 12), 0);
    wr(C(2, 8), 32'h0200_000C);
    rd(C(2, 8), v);
    chk("REG-CTRL-1", v === 32'h0200_000C, $sformatf("CONTROL bits 25 and 3:2 (documented unused) are stored and read back (got %h)", v));
    wr(C(2, 8), 32'h0800_0000);
    rd(C(2, 8), v);
    chk("REG-CTRL-2", v === 32'h0800_0000 && dma_interrupt === 1, "a software write of DONE=1 sets DONE and raises dma_interrupt");
    wr(C(2, 8), 32'h0400_0000);
    chk("REG-CTRL-3", dma_interrupt === 1, "a software write of ERROR=1 (DONE=0) keeps dma_interrupt high");
    wr(C(2, 8), 0);
    chk("REG-CTRL-4", dma_interrupt === 0, "writing CONTROL=0 clears DONE/ERROR and lowers dma_interrupt");
    bus(1, C(2, 0), 32'h0000_0011, 3'b000, 4'b0001, v, e);
    rd(C(2, 0), v);
    chk("REG-ERR-1", e && v === 32'hDEAD_BEE1, "byte store (HSIZE=byte, HWSTRB=0001) returns ERROR and changes nothing");
    bus(1, C(2, 0), 32'h0000_2222, 3'b001, 4'b0011, v, e);
    rd(C(2, 0), v);
    chk("REG-ERR-2", e && v === 32'hDEAD_BEE1, "halfword store returns ERROR and changes nothing");
    bus(1, C(2, 0), 32'h3333_3333, 3'b010, 4'b0111, v, e);
    rd(C(2, 0), v);
    chk("REG-ERR-3", e && v === 32'hDEAD_BEE1, "word store with HWSTRB != 1111 returns ERROR and changes nothing");
    bus(0, C(2, 0), '0, 3'b000, 4'h0, v, e);
    chk("REG-LD-1", !e && v === 32'hDEAD_BEE1, $sformatf("byte load at offset +0 is OKAY and returns the whole register (got %h)", v));
    bus(0, C(2, 0) + 1, '0, 3'b000, 4'h0, v, e);
    chk("REG-LD-2", e, "byte load at offset +1 returns ERROR (any address with bits 1:0 != 0)");
    bus(0, C(2, 0) + 2, '0, 3'b001, 4'h0, v, e);
    chk("REG-LD-3", e, "halfword load at offset +2 returns ERROR");
    bus(0, TRIG0 + 8 * NUM_CHANNELS, '0, 3'b010, 4'h0, v, e);
    chk("REG-MAP-1", e, $sformatf("read just past the trigger block (offset %h) returns ERROR", TRIG0 + 8 * NUM_CHANNELS));
    bus(1, 32'hFFC, 32'h1, 3'b010, 4'hF, v, e);
    chk("REG-MAP-2", e, "write to offset 0xFFC returns ERROR");
    bus(0, TC(NUM_CHANNELS - 1) + 4, '0, 3'b010, 4'h0, v, e);
    chk("REG-MAP-3", !e, "last trigger register responds OKAY");
    bus(1, S(2, 0), 32'h1234, 3'b010, 4'hF, v, e);
    rd(S(2, 0), v);
    chk("REG-STAT-1", !e && v === 0, "write to TRANSFERS_COMPLETED is OKAY and has no effect");
    wr(TC(2), 32'hFFFF_FF7F);
    rd(TC(2), v);
    chk("REG-TRIG-1", v === 32'hFFFF_FF7F, $sformatf("TRIGGER_CONFIG stores all 32 bits, undocumented ones included (got %h)", v));
    wr(TC(2), 32'h0001_0000);
    bus(1, TC(2) + 4, 32'hFFFF_FFFF, 3'b010, 4'hF, v, e);
    rd(TC(2) + 4, v);
    chk("REG-TRIG-2", !e && v === 0, "write to TRIGGER_STATUS is OKAY and leaves CREDIT unchanged");
  endtask

  task automatic timeline(input int n, input int sl, input int dl, input bit print_table);
    logic [31:0] v;
    src_lat = sl;
    dst_lat = dl;
    watch(0);
    wr(C(0, 0), 32'h100);
    wr(C(0, 4), 32'h900);
    wr(C(0, 12), n);
    tl_rows.delete();
    tl_cyc.delete();
    tl_on = print_table;
    wr(C(0, 8), ctrl(ONESHOT));
    idle_wait();
    repeat (2) @(posedge CLK);
    tl_on = 0;
    #1;
    rd(S(0, 0), v);
    $display("OBS TIMELINE n=%0d src_lat=%0d dst_lat=%0d: CONTROL write data phase = cycle 0; first read address phase +%0d; first write address phase +%0d; last write data phase +%0d; DONE visible +%0d; dma_interrupt high +%0d; reads=%0d writes=%0d; TRANSFERS_COMPLETED=%0d",
             n, sl, dl, c_rd1 - c_ctrl, c_wr1 - c_ctrl, c_wrN - c_ctrl, c_done - c_ctrl,
             c_irq - c_ctrl, rd_n, wr_n, v);
    chk($sformatf("TL-%0d-%0d%0d", n, sl, dl), c_done == c_irq && v == n && wr_n == n,
        "DONE and dma_interrupt rise in the same cycle; every item written once");
    if (print_table) begin
      $display("TABLE | Cycle | ENABLE | Read port address phase | Read data | Write port address phase | Write data | DONE | dma_interrupt |");
      foreach (tl_rows[i]) begin
        if (tl_cyc[i] - c_ctrl >= 0 && tl_cyc[i] - c_ctrl <= c_done - c_ctrl + 1)
          $display("TABLE | %0d %s", tl_cyc[i] - c_ctrl, tl_rows[i]);
      end
    end
    wr(C(0, 8), 0);
  endtask

  task automatic t_edge();
    logic [31:0] v, cw;
    watch(1);
    configure(1, 32'h100, 32'h900, 0, ctrl(ONESHOT));
    repeat (20) @(posedge CLK);
    #1;
    chk("EDGE-ZERO-1", DUT.engine.channel_control[1][27] && !DUT.engine.channel_control[1][7] && rd_n == 0,
        "one-shot with DESIRED_TRANSFERS=0: DONE sets, ENABLE clears, no bus traffic");
    wr(C(1, 8), 0);
    watch(2);
    configure(2, 32'h100, 32'h900, 4, ctrl(3'd3));
    repeat (20) @(posedge CLK);
    #1;
    chk("EDGE-MODE-1", DUT.engine.channel_control[2][27] && !DUT.engine.channel_control[2][7] && rd_n == 0,
        "MODE=3: DONE sets, ENABLE clears, no bus traffic");
    wr(C(2, 8), 0);
    watch(3);
    configure(3, 32'h200, 32'hA00, 0, ctrl(CONTINUOUS));
    repeat (20) @(posedge CLK);
    #1;
    chk("EDGE-ZERO-2", DUT.engine.channel_control[3][27] && !DUT.engine.channel_control[3][7] && rd_n == 0,
        "continuous with DESIRED_TRANSFERS=0: DONE sets, ENABLE clears, no bus traffic");
    wr(C(3, 8), 0);
    watch(4);
    wr(TC(4), 32'h0001_0080);
    configure(4, 32'h300, 32'hB00, 4, ctrl(ONESHOT));
    repeat (20) @(posedge CLK);
    #1;
    chk("EDGE-TRIG-1", !DUT.engine.channel_control[4][7] && !DUT.engine.channel_control[4][27] && rd_n == 0 &&
        !DUT.engine.ch_manager.run_active[4], "trigger armed + one-shot: the channel stops, DONE stays 0, nothing moves");
    wr(TC(4), 32'h0001_0000);
    wr(C(4, 8), ctrl(ONESHOT));
    idle_wait();
    chk("EDGE-TRIG-2", DUT.engine.channel_control[4][27] && rd_n == 4,
        "after disarming, ENABLE=1 starts the copy and it completes");
    wr(C(4, 8), 0);
    watch(5);
    configure(5, 32'h301, 32'hB02, 2, ctrl(ONESHOT, BYTE, 1, 1));
    idle_wait();
    $display("OBS BYTE-COPY read HADDR=%h,%h HSIZE=%0d,%0d | write HADDR=%h,%h HSIZE=%0d,%0d HWSTRB=%b,%b",
             rd_addr_q[0], rd_addr_q[1], rd_size_q[0], rd_size_q[1], wr_addr_q[0], wr_addr_q[1],
             wr_size_q[0], wr_size_q[1], wr_strb_q[0], wr_strb_q[1]);
    chk("AHB-SUB-1", rd_addr_q[0] == 32'h301 && rd_size_q[0] == 3'b000 && wr_addr_q[0] == 32'hB02 &&
        wr_size_q[0] == 3'b000 && wr_strb_q[0] == 4'b0100,
        "byte item at 0x301 -> 0xB02: HADDR is the item address, HSIZE=byte, HWSTRB=0100");
    wr(C(5, 8), 0);
    watch(6);
    configure(6, 32'h402, 32'hC00, 1, ctrl(ONESHOT));
    idle_wait();
    chk("AHB-SUB-2", rd_addr_q[0] == 32'h400 && dst_mem.regs[32'hC00 >> 2] == src_mem.regs[32'h400 >> 2],
        "word item at misaligned 0x402: the controller silently reads the aligned word at 0x400");
    wr(C(6, 8), 0);
    watch(6);
    configure(6, 32'h500, 32'hD00, 1, ctrl(ONESHOT, 2'd3));
    idle_wait();
    chk("AHB-SIZE3-1", DUT.engine.channel_control[6][27] && !DUT.engine.channel_control[6][7] && rd_n == 0,
        "SIZE=3: DONE sets, ENABLE clears, no bus traffic");
    wr(C(6, 8), 0);
    watch(7);
    configure(7, 32'h100, 32'h900, 200, ctrl(ONESHOT));
    repeat (10) @(posedge CLK);
    wr(C(7, 8), ctrl(ONESHOT, WORD, 4, 4, 0) | 32'h0100_0000);
    idle_wait();
    rd(S(7, 0), v);
    rd(C(7, 8), cw);
    $display("OBS ABORT after 10 cycles of a 200-item copy: TRANSFERS_COMPLETED=%0d CONTROL=%h", v, cw);
    chk("EDGE-ABORT-1", cw[24] == 0 && cw[7] == 0 && cw[27] == 0 && v > 0 && v < 200,
        "ABORT self-clears, ENABLE and DONE stay 0, and the copy stops part-way");
  endtask

  function automatic int bursts(input bit wside, output int crossing);
    int n = 0;
    crossing = 0;
    if (!wside) begin
      foreach (rd_addr_q[i])
        if (rd_trans_q[i] == 2'b10 && rd_burst_q[i] == 3'b011) begin
          n++;
          if ((rd_addr_q[i] & 32'h3FF) > 32'h3F0) crossing++;
        end
    end else begin
      foreach (wr_addr_q[i])
        if (wr_trans_q[i] == 2'b10 && wr_burst_q[i] == 3'b011) begin
          n++;
          if ((wr_addr_q[i] & 32'h3FF) > 32'h3F0) crossing++;
        end
    end
    return n;
  endfunction

  task automatic t_burst();
    int rb, wb, rx, wx;
    src_lat = 1;
    dst_lat = 3;
    watch(0);
    configure(0, 32'h100, 32'h900, 16, ctrl(ONESHOT));
    idle_wait();
    rb = bursts(0, rx);
    wb = bursts(1, wx);
    $display("OBS BURST 16 words, latency 1/3: %0d read INCR4 bursts, %0d write INCR4 bursts (of %0d reads, %0d writes)",
             rb, wb, rd_n, wr_n);
    chk("AHB-BURST-1", rb > 0, "with slow memory, consecutive word items go out as INCR4 bursts");
    wr(C(0, 8), 0);
    begin
      int trb = 0, twb = 0, trx = 0, twx = 0;
      for (int k = 0; k < 12; k++) begin
        watch(0);
        configure(0, 32'h3C0 + 4 * k, 32'h7C0 + 4 * k, 16, ctrl(ONESHOT));
        idle_wait();
        trb += bursts(0, rx);
        twb += bursts(1, wx);
        trx += rx;
        twx += wx;
        wr(C(0, 8), 0);
      end
      {rb, wb, rx, wx} = {trb, twb, trx, twx};
    end
    $display("OBS BURST-1KB 12 copies of 16 words starting 0x3C0..0x3EC: read bursts %0d (crossing 1 KB: %0d), write bursts %0d (crossing: %0d)",
             rb, rx, wb, wx);
    chk("AHB-BURST-2", rb + wb > 0 && rx + wx == 0, "no INCR4 burst crosses a 1 KB boundary");
    wr(C(0, 8), 0);
    src_lat = 0;
    dst_lat = 0;
  endtask

  task automatic t_werr();
    logic [31:0] v;
    string s = "";
    int zero_strobe = 0;
    watch(0);
    configure(0, 32'h100, 32'h3FF8, 8, ctrl(ONESHOT));
    idle_wait();
    foreach (wr_addr_q[i]) begin
      s = {s, $sformatf(" %h/%b", wr_addr_q[i], wr_strb_q[i])};
      if (wr_resp_q[i]) s = {s, "/ERR"};
      if (i < wr_strb_q.size() && wr_strb_q[i] == 4'b0000) zero_strobe++;
    end
    rd(S(0, 12), v);
    $display("OBS WERR write address/strobe sequence:%s ; ERROR_ADDRESS=%h ERROR=%0b", s, v,
             DUT.engine.channel_control[0][26]);
    chk("ERR-WR-1", v == 32'h4000 && DUT.engine.channel_control[0][26], "write error records ERROR_ADDRESS=0x4000 and sets ERROR");
    $display("OBS WERR address phases completed with HWSTRB=0000 (no byte written): %0d", zero_strobe);
    wr(C(0, 8), 0);
  endtask

  task automatic t_starve();
    logic [31:0] v1, v2;
    configure(1, 32'h100, 32'h900, 4, ctrl(CONTINUOUS));
    repeat (10) @(posedge CLK);
    configure(2, 32'h200, 32'hA00, 4, ctrl(ONESHOT));
    repeat (300) @(posedge CLK);
    rd(S(2, 0), v2);
    chk("ARB-CONT-1", v2 == 0 && DUT.engine.channel_control[1][7],
        "while a continuous channel runs, a one-shot on another channel moves nothing");
    wr(C(1, 8), ctrl(CONTINUOUS, WORD, 4, 4, 0));
    idle_wait();
    repeat (40) @(posedge CLK);
    rd(S(2, 0), v2);
    chk("ARB-CONT-2", v2 == 4 && DUT.engine.channel_control[2][27],
        "once the continuous channel is stopped (ENABLE=0), the waiting one-shot runs and completes");
    wr(C(1, 8), 0);
    wr(C(2, 8), 0);
  endtask

  task automatic t_race();
    logic [31:0] cw = ctrl(CONTINUOUS, WORD, 4, 4);
    int runs_lost = 0;
    logic [31:0] v;
    watch(NUM_CHANNELS - 1);
    collisions = 0;
    lost = 0;
    col_check = 1;
    configure(NUM_CHANNELS - 1, 32'h100, 32'h900, 2, cw);
    for (int k = 0; k < 60; k++) begin
      repeat (k % 7) @(posedge CLK);
      wr(C(NUM_CHANNELS - 1, 8), cw);
    end
    col_check = 0;
    wr(C(NUM_CHANNELS - 1, 8), ctrl(CONTINUOUS, WORD, 4, 4, 0));
    idle_wait();
    $display("OBS RACE continuous: %0d CONTROL writes landed in the same cycle as a pass end; DONE lost in %0d of them",
             collisions, lost);
    chk("RACE-1", collisions > 0 && lost == 0, "a CONTROL write in the cycle a pass ends keeps that pass's DONE");
    for (int k = 0; k < 40; k++) begin
      wr(C(NUM_CHANNELS - 1, 8), 0);
      configure(NUM_CHANNELS - 1, 32'h100, 32'h900, 4, ctrl(ONESHOT));
      repeat (k) @(posedge CLK);
      wr(C(NUM_CHANNELS - 1, 8), ctrl(ONESHOT));
      idle_wait();
      rd(S(NUM_CHANNELS - 1, 0), v);
      if (!DUT.engine.channel_control[NUM_CHANNELS-1][27] && !DUT.engine.channel_control[NUM_CHANNELS-1][7])
        runs_lost++;
    end
    chk("RACE-2", runs_lost == 0, "one-shot: a CONTROL write near completion never loses DONE");
    wr(C(NUM_CHANNELS - 1, 8), 0);
  endtask

  initial begin
    do_reset();
`ifdef PARAM
    t_reset();
    timeline(16, 0, 0, 0);
    timeline(16, 1, 3, 0);
    timeline(40, 3, 1, 0);
`else
    t_reset();
    t_regs();
    timeline(4, 0, 0, 1);
    timeline(1, 0, 0, 0);
    timeline(16, 0, 0, 0);
    timeline(4, 2, 2, 0);
    t_edge();
    t_burst();
    t_starve();
    t_werr();
    t_race();
`endif
    $display("DONE NCH=%0d FIFO_DEPTH=%0d fails=%0d", NUM_CHANNELS, `FDEPTH, fails);
    $finish;
  end

  initial begin
    #5ms;
    $display("FAIL TIMEOUT");
    $finish;
  end
endmodule
`default_nettype wire
