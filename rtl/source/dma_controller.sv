// File:        dma_controller.sv
// Author:      DMA-zing contributors
// Date:        2026-10-08
// Description: AHB DMA controller: engine, three queues and the two AHB managers. With the spec 1.2 fixes.

module dma_controller #(
    parameter int NUM_CHANNELS = 8,
    parameter int NUM_SOURCES = 32,
    parameter int DATA_SIZE = 32,
    parameter int FIFO_DEPTH = 16
) (
    // Clock and Reset
    input logic CLK,
    input logic nRST,

    // AHB Subordinate Interface
    ahb_if.subordinate ahb_sub_if,
    ahb_if.manager     read_manager_if,
    ahb_if.manager     write_manager_if,

    input logic [NUM_SOURCES-1:0] trigger_in,

    output logic dma_interrupt

);
  // Parameter checks
  if (NUM_CHANNELS < 2 || NUM_CHANNELS > 32 || (NUM_CHANNELS & (NUM_CHANNELS - 1)) != 0)
  begin : g_bad_channels
    $error("dma_controller: NUM_CHANNELS must be a power of 2 from 2 to 32 (got %0d)", NUM_CHANNELS);
  end
  if (NUM_SOURCES < 2 || NUM_SOURCES > 128 || (NUM_SOURCES & (NUM_SOURCES - 1)) != 0)
  begin : g_bad_sources
    $error("dma_controller: NUM_SOURCES must be a power of 2 from 2 to 128 (got %0d)", NUM_SOURCES);
  end
  if (FIFO_DEPTH < 4 || (FIFO_DEPTH & (FIFO_DEPTH - 1)) != 0) begin : g_bad_depth
    $error("dma_controller: FIFO_DEPTH must be a power of 2 >= 4 (got %0d)", FIFO_DEPTH);
  end
  if (DATA_SIZE != 32) begin : g_bad_data
    $error("dma_controller: DATA_SIZE must be 32 (got %0d)", DATA_SIZE);
  end

  // DMA Engine Signals
  logic                                      full_r;
  logic                                      full_w;

  logic                                      transfer_completed;
  logic [                     DATA_SIZE-1:0] write_error_addr;
  logic [                     DATA_SIZE-1:0] read_error_addr;

  logic [          $clog2(NUM_CHANNELS)-1:0] completed_channel;
  logic [          $clog2(NUM_CHANNELS)-1:0] write_error_channel;
  logic [          $clog2(NUM_CHANNELS)-1:0] read_error_channel;

  logic [DATA_SIZE+1+$clog2(NUM_CHANNELS):0] read_address_data_in;
  logic [DATA_SIZE+1+$clog2(NUM_CHANNELS):0] write_address_data_in;
  logic [DATA_SIZE+1+$clog2(NUM_CHANNELS):0] read_address_data_out;
  logic [DATA_SIZE+1+$clog2(NUM_CHANNELS):0] write_address_data_out;

  logic                                      wen_r;
  logic                                      wen_w;

  // Write Manager & Transfer/Write FIFO Signals

  logic                                      waddr_fifo_empty;
  logic [              $clog2(FIFO_DEPTH):0] waddr_fifo_count;
  logic                                      waddr_fifo_ren;
  logic [DATA_SIZE+1+$clog2(NUM_CHANNELS):0] waddr_fifo_peek1;
  logic [DATA_SIZE+1+$clog2(NUM_CHANNELS):0] waddr_fifo_peek2;
  logic [DATA_SIZE+1+$clog2(NUM_CHANNELS):0] waddr_fifo_peek3;

  logic                                      tdata_fifo_empty;
  logic [              $clog2(FIFO_DEPTH):0] tdata_fifo_count;
  logic [                     DATA_SIZE-1:0] tdata_fifo_rdata;
  logic                                      tdata_fifo_ren;

  logic                                      write_error_flag;
  logic                                      w_transfer_active;

  // Read Manager & Transfer/Read FIFO Signals

  logic [DATA_SIZE+1+$clog2(NUM_CHANNELS):0] raddr_fifo_rdata;
  logic                                      raddr_fifo_empty;
  logic [              $clog2(FIFO_DEPTH):0] raddr_fifo_count;
  logic                                      raddr_fifo_ren;
  logic [DATA_SIZE+1+$clog2(NUM_CHANNELS):0] raddr_fifo_peek1;
  logic [DATA_SIZE+1+$clog2(NUM_CHANNELS):0] raddr_fifo_peek2;
  logic [DATA_SIZE+1+$clog2(NUM_CHANNELS):0] raddr_fifo_peek3;

  logic                                      tdata_fifo_full;
  logic [                     DATA_SIZE-1:0] tdata_fifo_wdata;
  logic [          $clog2(NUM_CHANNELS)-1:0] tdata_fifo_wtag;
  logic                                      tdata_fifo_wen;

  logic [DATA_SIZE+$clog2(NUM_CHANNELS)-1:0] tdata_fifo_wentry;
  logic [DATA_SIZE+$clog2(NUM_CHANNELS)-1:0] tdata_fifo_rentry;

  logic [                  NUM_CHANNELS-1:0] kill_mask;
  logic [                  NUM_CHANNELS-1:0] start_kill;

  logic                                      read_error_flag;
  logic                                      r_transfer_active;

  assign tdata_fifo_wentry = {tdata_fifo_wtag, tdata_fifo_wdata};
  assign tdata_fifo_rdata = tdata_fifo_rentry[DATA_SIZE-1:0];

  assign kill_mask = (NUM_CHANNELS'(read_error_flag) << read_error_channel) |
      (NUM_CHANNELS'(write_error_flag) << write_error_channel) | start_kill;

  dma_engine #(
      .NUM_CHANNELS(NUM_CHANNELS),
      .NUM_SOURCES(NUM_SOURCES),
      .DATA_SIZE(DATA_SIZE)
  ) engine (
      .CLK (CLK),
      .nRST(nRST),

      .ahb_if(ahb_sub_if),

      .trigger_in(trigger_in),

      .full_r(full_r),
      .full_w(full_w),

      .transfer_completed(transfer_completed),
      .completed_channel (completed_channel),

      .write_error_addr(write_error_addr),
      .read_error_addr (read_error_addr),

      .write_error_flag(write_error_flag),
      .read_error_flag (read_error_flag),

      .write_error_channel(write_error_channel),
      .read_error_channel (read_error_channel),

      .read_address_data_in(read_address_data_in),
      .write_address_data_in(write_address_data_in),
      .wen_r(wen_r),
      .wen_w(wen_w),
      .start_kill(start_kill),
      .dma_interrupt(dma_interrupt)
  );

  dma_fifo #(
      .DATA_WIDTH(DATA_SIZE + 2 + $clog2(NUM_CHANNELS)),
      .DEPTH(FIFO_DEPTH),
      .TAG_WIDTH($clog2(NUM_CHANNELS))
  ) read_fifo (
      .clk(CLK),
      .n_rst(nRST),
      .kill_mask(kill_mask),
      .wen(wen_r),
      .ren(raddr_fifo_ren),
      .data_in(read_address_data_in),
      .data_out(read_address_data_out),
      .full(full_r),
      .empty(raddr_fifo_empty),
      .count(raddr_fifo_count),
      .peek1(raddr_fifo_peek1),
      .peek2(raddr_fifo_peek2),
      .peek3(raddr_fifo_peek3)
  );

  dma_fifo #(
      .DATA_WIDTH(DATA_SIZE + 2 + $clog2(NUM_CHANNELS)),
      .DEPTH(FIFO_DEPTH),
      .TAG_WIDTH($clog2(NUM_CHANNELS))
  ) write_fifo (
      .clk(CLK),
      .n_rst(nRST),
      .kill_mask(kill_mask),
      .wen(wen_w),
      .ren(waddr_fifo_ren),
      .data_in(write_address_data_in),
      .data_out(write_address_data_out),
      .full(full_w),
      .empty(waddr_fifo_empty),
      .count(waddr_fifo_count),
      .peek1(waddr_fifo_peek1),
      .peek2(waddr_fifo_peek2),
      .peek3(waddr_fifo_peek3)
  );

  ahb_write_manager #(
      .DATA_SIZE (DATA_SIZE),
      .FIFO_DEPTH(FIFO_DEPTH),
      .TAG_WIDTH ($clog2(NUM_CHANNELS))
  ) write_manager (
      .clk  (CLK),
      .n_rst(nRST),
      .ahb_m(write_manager_if),

      .waddr_fifo_rdata(write_address_data_out),
      .waddr_fifo_empty(waddr_fifo_empty),
      .waddr_fifo_count(waddr_fifo_count),
      .waddr_fifo_ren  (waddr_fifo_ren),
      .waddr_fifo_peek1(waddr_fifo_peek1),
      .waddr_fifo_peek2(waddr_fifo_peek2),
      .waddr_fifo_peek3(waddr_fifo_peek3),

      .tdata_fifo_empty(tdata_fifo_empty),
      .tdata_fifo_count(tdata_fifo_count),
      .tdata_fifo_rdata(tdata_fifo_rdata),
      .tdata_fifo_ren  (tdata_fifo_ren),

      .kill_mask(kill_mask),

      .error_flag(write_error_flag),
      .write_error_addr(write_error_addr),
      .write_error_tag(write_error_channel),
      .transfer_active(w_transfer_active),
      .transfer_completed(transfer_completed),
      .completed_tag(completed_channel)
  );

  ahb_read_manager #(
      .DATA_SIZE (DATA_SIZE),
      .FIFO_DEPTH(FIFO_DEPTH),
      .TAG_WIDTH ($clog2(NUM_CHANNELS))
  ) read_manager (
      .clk  (CLK),
      .n_rst(nRST),
      .ahb_m(read_manager_if),

      .raddr_fifo_rdata(read_address_data_out),
      .raddr_fifo_empty(raddr_fifo_empty),
      .raddr_fifo_count(raddr_fifo_count),
      .raddr_fifo_ren  (raddr_fifo_ren),
      .raddr_fifo_peek1(raddr_fifo_peek1),
      .raddr_fifo_peek2(raddr_fifo_peek2),
      .raddr_fifo_peek3(raddr_fifo_peek3),

      .tdata_fifo_full (tdata_fifo_full),
      .tdata_fifo_count(tdata_fifo_count),
      .tdata_fifo_wdata(tdata_fifo_wdata),
      .tdata_fifo_wtag (tdata_fifo_wtag),
      .tdata_fifo_wen  (tdata_fifo_wen),

      .kill_mask(kill_mask),

      .error_flag(read_error_flag),
      .read_error_addr(read_error_addr),
      .read_error_tag(read_error_channel),
      .transfer_active(r_transfer_active)
  );

  dma_fifo #(
      .DATA_WIDTH(DATA_SIZE + $clog2(NUM_CHANNELS)),
      .DEPTH(FIFO_DEPTH),
      .TAG_WIDTH($clog2(NUM_CHANNELS))
  ) transfer_data_fifo (
      .clk(CLK),
      .n_rst(nRST),
      .kill_mask(kill_mask),
      .wen(tdata_fifo_wen),
      .ren(tdata_fifo_ren),
      .data_in(tdata_fifo_wentry),
      .data_out(tdata_fifo_rentry),
      .full(tdata_fifo_full),
      .empty(tdata_fifo_empty),
      .count(tdata_fifo_count),
      .peek1(),
      .peek2(),
      .peek3()
  );

endmodule
