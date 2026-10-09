// File:        dma_ahb_if.sv
// Author:      Isaac Hagedorn
// Date:        2026-10-08
// Description: Bench-side interfaces for the three AHB ports and the system pins.

interface ahb_mgr_tb_if (input logic HCLK, input logic HRESETn);
    logic        HSEL, HWRITE, HMASTLOCK;
    logic [1:0]  HTRANS;
    logic [2:0]  HBURST, HSIZE;
    logic [31:0] HADDR, HWDATA;
    logic [3:0]  HWSTRB;
    logic        HREADYOUT, HRESP;   // from the DUT
    logic [31:0] HRDATA;   // from the DUT
    logic        HREADY;
    assign HREADY = HREADYOUT;

    clocking drv_cb @(posedge HCLK);
        default input #1step;
        input HREADY, HRESP, HRDATA, HRESETn;
    endclocking

    clocking mon_cb @(posedge HCLK);
        default input #1step;
        input HSEL, HWRITE, HMASTLOCK, HTRANS, HBURST, HSIZE, HADDR, HWDATA, HWSTRB,
              HREADY, HRESP, HRDATA, HRESETn;
    endclocking
endinterface

interface ahb_sub_tb_if (input logic HCLK, input logic HRESETn);
    logic        HSEL, HWRITE, HMASTLOCK;   // from the DUT
    logic [1:0]  HTRANS;
    logic [2:0]  HBURST, HSIZE;
    logic [31:0] HADDR, HWDATA;
    logic [3:0]  HWSTRB;
    logic        HREADYOUT, HRESP;   // from the bench
    logic [31:0] HRDATA;
    logic        HREADY;
    assign HREADY = HREADYOUT;

    clocking drv_cb @(posedge HCLK);
        default input #1step;
        input HSEL, HWRITE, HTRANS, HBURST, HSIZE, HADDR, HWDATA, HWSTRB, HREADY, HRESETn;
    endclocking

    clocking mon_cb @(posedge HCLK);
        default input #1step;
        input HSEL, HWRITE, HMASTLOCK, HTRANS, HBURST, HSIZE, HADDR, HWDATA, HWSTRB,
              HREADY, HRESP, HRDATA, HRESETn;
    endclocking
endinterface

interface dma_sys_if #(parameter int NSRC = 32) (input logic CLK);
    logic            nRST;
    logic [NSRC-1:0] trigger_in;
    logic            dma_interrupt;

    clocking mon_cb @(posedge CLK);
        default input #1step;
        input nRST, trigger_in, dma_interrupt;
    endclocking
endinterface
