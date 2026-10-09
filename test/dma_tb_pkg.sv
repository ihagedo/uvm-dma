// File:        dma_tb_pkg.sv
// Author:      Isaac Hagedorn
// Date:        2026-10-08
// Description: Package holding every DMA bench class. DMA_NCH and DMA_FDEPTH select the configuration.

`ifndef DMA_NCH
    `define DMA_NCH 8
`endif
`ifndef DMA_FDEPTH
    `define DMA_FDEPTH 16
`endif
`ifndef DMA_NSRC
    `define DMA_NSRC 32
`endif

`include "uvm_macros.svh"
package dma_tb_pkg;
    import uvm_pkg::*;
    timeunit 1ns;
    timeprecision 1ps;

    localparam int NCH    = `DMA_NCH;   // NUM_CHANNELS
    localparam int FDEPTH = `DMA_FDEPTH;   // FIFO_DEPTH
    localparam int NSRC   = `DMA_NSRC;   // NUM_SOURCES
    localparam int PERIOD_NS = 10;   // rising edges at 5, 15, 25 ... ns

    localparam bit [31:0] REG_BASE  = 32'h9000_1000;   // register base address
    localparam bit [31:0] SRC_AREA  = 32'h1000_0000;
    localparam bit [31:0] DST_AREA  = 32'h2000_0000;
    localparam bit [31:0] AREA_SIZE = 32'h0010_0000;   // 1 MB per channel

    typedef virtual ahb_mgr_tb_if     ahb_mgr_vif;
    typedef virtual ahb_sub_tb_if     ahb_sub_vif;
    typedef virtual dma_sys_if #(NSRC) sys_vif;

    function automatic longint edge_now();
        return ($time + 5) / 10;
    endfunction

    `include "dma_item.svh"
    `include "dma_mem.svh"
    `include "dma_drivers.svh"
    `include "dma_monitors.svh"
    `include "dma_agents.svh"
    `include "dma_regs.svh"
    `include "dma_model.svh"
    `include "dma_coverage.svh"
    `include "dma_scoreboard.svh"
    `include "dma_env.svh"
    `include "dma_seqs.svh"
    `include "dma_tests.svh"
endpackage
