// File:        tb_top.sv
// Author:      Isaac Hagedorn
// Date:        2026-10-08
// Description: Top level: clock, interfaces, the DMA controller under test, assertions and run_test.

`timescale 1ns/1ps
module tb_top;
    import uvm_pkg::*;
    import dma_tb_pkg::*;

    logic CLK = 1'b0;
    always #(PERIOD_NS / 2) CLK = ~CLK;

    dma_sys_if #(NSRC) sys (CLK);

    ahb_if dut_cfg (.HCLK(CLK), .HRESETn(sys.nRST));
    ahb_if dut_rd  (.HCLK(CLK), .HRESETn(sys.nRST));
    ahb_if dut_wr  (.HCLK(CLK), .HRESETn(sys.nRST));

    ahb_mgr_tb_if cfg_if (CLK, sys.nRST);
    ahb_sub_tb_if rd_if  (CLK, sys.nRST);
    ahb_sub_tb_if wr_if  (CLK, sys.nRST);

    assign dut_cfg.HSEL      = cfg_if.HSEL;
    assign dut_cfg.HWRITE    = cfg_if.HWRITE;
    assign dut_cfg.HMASTLOCK = cfg_if.HMASTLOCK;
    assign dut_cfg.HTRANS    = cfg_if.HTRANS;
    assign dut_cfg.HBURST    = cfg_if.HBURST;
    assign dut_cfg.HSIZE     = cfg_if.HSIZE;
    assign dut_cfg.HADDR     = cfg_if.HADDR;
    assign dut_cfg.HWDATA    = cfg_if.HWDATA;
    assign dut_cfg.HWSTRB    = cfg_if.HWSTRB;
    assign cfg_if.HREADYOUT  = dut_cfg.HREADYOUT;
    assign cfg_if.HRESP      = dut_cfg.HRESP;
    assign cfg_if.HRDATA     = dut_cfg.HRDATA;

    assign rd_if.HSEL      = dut_rd.HSEL;
    assign rd_if.HWRITE    = dut_rd.HWRITE;
    assign rd_if.HMASTLOCK = dut_rd.HMASTLOCK;
    assign rd_if.HTRANS    = dut_rd.HTRANS;
    assign rd_if.HBURST    = dut_rd.HBURST;
    assign rd_if.HSIZE     = dut_rd.HSIZE;
    assign rd_if.HADDR     = dut_rd.HADDR;
    assign rd_if.HWDATA    = dut_rd.HWDATA;
    assign rd_if.HWSTRB    = dut_rd.HWSTRB;
    assign dut_rd.HREADYOUT = rd_if.HREADYOUT;
    assign dut_rd.HRESP     = rd_if.HRESP;
    assign dut_rd.HRDATA    = rd_if.HRDATA;

    assign wr_if.HSEL      = dut_wr.HSEL;
    assign wr_if.HWRITE    = dut_wr.HWRITE;
    assign wr_if.HMASTLOCK = dut_wr.HMASTLOCK;
    assign wr_if.HTRANS    = dut_wr.HTRANS;
    assign wr_if.HBURST    = dut_wr.HBURST;
    assign wr_if.HSIZE     = dut_wr.HSIZE;
    assign wr_if.HADDR     = dut_wr.HADDR;
    assign wr_if.HWDATA    = dut_wr.HWDATA;
    assign wr_if.HWSTRB    = dut_wr.HWSTRB;
    assign dut_wr.HREADYOUT = wr_if.HREADYOUT;
    assign dut_wr.HRESP     = wr_if.HRESP;
    assign dut_wr.HRDATA    = wr_if.HRDATA;

    dma_controller #(
        .NUM_CHANNELS (NCH),
        .NUM_SOURCES  (NSRC),
        .DATA_SIZE    (32),
        .FIFO_DEPTH   (FDEPTH)
    ) dut (
        .CLK              (CLK),
        .nRST             (sys.nRST),
        .ahb_sub_if       (dut_cfg),
        .read_manager_if  (dut_rd),
        .write_manager_if (dut_wr),
        .trigger_in       (sys.trigger_in),
        .dma_interrupt    (sys.dma_interrupt)
    );

    dma_mgr_sva #(.PORT("RD")) rd_sva (
        .CLK(CLK), .nRST(sys.nRST), .HSEL(rd_if.HSEL), .HWRITE(rd_if.HWRITE), .HREADY(rd_if.HREADY),
        .HRESP(rd_if.HRESP), .HTRANS(rd_if.HTRANS), .HBURST(rd_if.HBURST), .HSIZE(rd_if.HSIZE),
        .HADDR(rd_if.HADDR), .HWDATA(rd_if.HWDATA), .HWSTRB(rd_if.HWSTRB));
    dma_mgr_sva #(.PORT("WR")) wr_sva (
        .CLK(CLK), .nRST(sys.nRST), .HSEL(wr_if.HSEL), .HWRITE(wr_if.HWRITE), .HREADY(wr_if.HREADY),
        .HRESP(wr_if.HRESP), .HTRANS(wr_if.HTRANS), .HBURST(wr_if.HBURST), .HSIZE(wr_if.HSIZE),
        .HADDR(wr_if.HADDR), .HWDATA(wr_if.HWDATA), .HWSTRB(wr_if.HWSTRB));
    dma_sub_sva #(.NCH(NCH)) cfg_sva (
        .CLK(CLK), .nRST(sys.nRST), .HSEL(cfg_if.HSEL), .HWRITE(cfg_if.HWRITE), .HREADY(cfg_if.HREADY),
        .HRESP(cfg_if.HRESP), .HTRANS(cfg_if.HTRANS), .HADDR(cfg_if.HADDR), .HWSTRB(cfg_if.HWSTRB));

    bind dma_engine dma_irq_sva #(.NCH(NUM_CHANNELS)) u_irq_sva (
        .CLK(CLK), .nRST(nRST), .channel_control(channel_control), .dma_interrupt(dma_interrupt));

    longint tr_from = -1, tr_to = -1;
    initial begin
        string arg;
        if ($value$plusargs("BUS_TRACE=%s", arg)) void'($sscanf(arg, "%d,%d", tr_from, tr_to));
    end
    always @(posedge CLK) if (tr_from >= 0 && edge_now() >= tr_from && edge_now() <= tr_to)
        $display("[BUS] edge %0d  RD %0d/%0d %h rdy=%b resp=%b st=%0d | WR %0d/%0d %h strb=%b rdy=%b resp=%b st=%0d committed=%0d tdata=%0d",
                 edge_now(), rd_if.HTRANS, rd_if.HBURST, rd_if.HADDR, rd_if.HREADY, rd_if.HRESP, dut.read_manager.current_state,
                 wr_if.HTRANS, wr_if.HBURST, wr_if.HADDR, wr_if.HWSTRB, wr_if.HREADY, wr_if.HRESP, dut.write_manager.current_state,
                 dut.write_manager.committed, dut.write_manager.tdata_fifo_count);

`ifdef WAVES
    // make WAVES=1: FST on Verilator, VCD elsewhere
    initial begin
`ifdef VERILATOR
        $dumpfile("waves.fst");
`else
        $dumpfile("waves.vcd");
`endif
        $dumpvars(0, tb_top);
    end
`endif

    initial begin
        sys.nRST       = 1'b1;
        sys.trigger_in = '0;
        uvm_config_db #(ahb_mgr_vif)::set(null, "uvm_test_top.env.cfg.*", "vif", cfg_if);
        uvm_config_db #(ahb_sub_vif)::set(null, "uvm_test_top.env.rd.*", "vif", rd_if);
        uvm_config_db #(ahb_sub_vif)::set(null, "uvm_test_top.env.wr.*", "vif", wr_if);
        uvm_config_db #(sys_vif)::set(null, "uvm_test_top.env.sys.*", "vif", sys);
        uvm_config_db #(sys_vif)::set(null, "uvm_test_top.env.scb", "vif", sys);
        uvm_config_db #(sys_vif)::set(null, "uvm_test_top", "vif", sys);
        run_test();
    end
endmodule
