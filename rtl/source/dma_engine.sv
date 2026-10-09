// File:        dma_engine.sv
// Author:      DMA-zing contributors
// Date:        2026-10-08
// Description: Registers, triggers, arbiter and address generator of the DMA. With the spec 1.2 fixes.

`timescale 1ns / 10ps

module dma_engine #(
    parameter int NUM_CHANNELS = 8,
    parameter int NUM_SOURCES = 32,
    parameter int DATA_SIZE = 32
) (
    // Clock and Reset
    input logic CLK,
    input logic nRST,

    // AHB Subordinate Interface
    ahb_if.subordinate ahb_if,

    input logic [NUM_SOURCES-1:0] trigger_in,

    // FIFOS --> Address Generator
    input logic full_r,
    input logic full_w,

    // AHB Managers --> Channel Manager
    input logic transfer_completed,
    input logic [$clog2(NUM_CHANNELS)-1:0] completed_channel,

    input logic [DATA_SIZE-1:0] write_error_addr,
    input logic [DATA_SIZE-1:0] read_error_addr,

    input logic write_error_flag,
    input logic read_error_flag,

    input logic [$clog2(NUM_CHANNELS)-1:0] write_error_channel,
    input logic [$clog2(NUM_CHANNELS)-1:0] read_error_channel,

    // Address Generator --> FIFOs
    output logic [DATA_SIZE+1+$clog2(NUM_CHANNELS):0] read_address_data_in,
    output logic [DATA_SIZE+1+$clog2(NUM_CHANNELS):0] write_address_data_in,
    output logic                                      wen_r,
    output logic                                      wen_w,

    // Channels restarted last cycle
    output logic [NUM_CHANNELS-1:0] start_kill,

    // Done OR
    output logic dma_interrupt

);
  // Address Generator Signals

  logic [$clog2(NUM_CHANNELS)-1:0]                control;
  logic                                           arb_strobe;

  logic [        NUM_CHANNELS-1:0][DATA_SIZE-1:0] source_address;
  logic [        NUM_CHANNELS-1:0][DATA_SIZE-1:0] dest_address;
  logic [        NUM_CHANNELS-1:0][DATA_SIZE-1:0] channel_control;
  logic [        NUM_CHANNELS-1:0][DATA_SIZE-1:0] transfer_amount;

  logic [        NUM_CHANNELS-1:0]                channel_finished;
  logic                                           halt_generation;
  logic                                           abort_h;

  // Arbiter Signals

  logic [$clog2(NUM_CHANNELS)-1:0]                channel_select;
  logic [        NUM_CHANNELS-1:0]                channel_request;
  logic [        NUM_CHANNELS-1:0]                channel_finish;
  logic                                           enabled;

  // AHB Subordinate Signals

  bus_protocol_if bus_if ();

  logic wen, ren;
  logic [DATA_SIZE-1:0] wdata, rdata;
  logic [           DATA_SIZE-1:0] addr;

  // Channel Manager Signals

  logic [$clog2(NUM_CHANNELS)-1:0] ch_sel;
  logic [        NUM_CHANNELS-1:0] ch_finished;

  logic [        NUM_CHANNELS-1:0] trigger_armed;
  logic [        NUM_CHANNELS-1:0] trigger_credit;
  logic [           DATA_SIZE-1:0] trigger_rdata;
  logic                            trigger_hit;
  logic                            invalid_address;

  assign ch_sel = channel_select;
  assign control = channel_select;
  assign arb_strobe = enabled;
  assign ch_finished = channel_finished;

  address_generator #(
      .NUM_CHANNELS(NUM_CHANNELS),
      .DATA_SIZE(DATA_SIZE)
  ) addr_gen (
      .CLK (CLK),
      .nRST(nRST),

      .control   (control),
      .arb_strobe(arb_strobe),

      .source_address(source_address),
      .dest_address(dest_address),
      .channel_control(channel_control),
      .transfer_amount(transfer_amount),

      .full_w(full_w),
      .full_r(full_r),

      .write_address_data_in(write_address_data_in),
      .read_address_data_in(read_address_data_in),
      .wen_w(wen_w),
      .wen_r(wen_r),

      .channel_finished(channel_finished),
      .halt_generation(halt_generation),
      .abort_h(abort_h)
  );

  assign channel_finish = channel_finished;

  dma_arbiter #(
      .NUM_CHANNELS(NUM_CHANNELS)
  ) arb (
      .CLK (CLK),
      .nRST(nRST),

      .channel_request(channel_request),
      .channel_finish (channel_finish),

      .enabled(enabled),
      .channel_select(channel_select)

  );

  ahb_subordinate #(
      .ADDR_WIDTH(32),
      .DATA_WIDTH(32),
      .BASE_ADDR(32'h9000_1000),
      .NWORDS(1024)
  ) ahb_sub (
      .ahb_if(ahb_if),
      .bus_if(bus_if.protocol)
  );

  // Whole words only
  logic word_write;
  assign word_write = bus_if.wen && (bus_if.strobe == '1);

  assign wen = word_write;
  assign ren = bus_if.ren;
  assign wdata = bus_if.wdata;
  assign addr = bus_if.addr;

  channel_manager #(
      .NUM_CHANNELS(NUM_CHANNELS),
      .DATA_SIZE(DATA_SIZE)
  ) ch_manager (
      .CLK (CLK),
      .nRST(nRST),

      .wen(wen),
      .ren(ren),
      .addr(addr),
      .wdata(wdata),
      .arb_enabled(arb_strobe),

      .ch_sel(ch_sel),
      .ch_finished(ch_finished),
      .transfer_completed(transfer_completed),
      .completed_channel(completed_channel),
      .write_error_channel(write_error_channel),
      .read_error_channel(read_error_channel),
      .write_error_addr(write_error_addr),
      .write_error_flag(write_error_flag),
      .read_error_addr(read_error_addr),
      .read_error_flag(read_error_flag),
      .halt_generation(halt_generation),
      .abort_h(abort_h),

      .trigger_armed (trigger_armed),
      .trigger_credit(trigger_credit),

      .source_address(source_address),
      .destination_address(dest_address),
      .control(channel_control),
      .transfer_amount(transfer_amount),

      .rdata(rdata),

      .channel_request(channel_request),
      .start_kill(start_kill),
      .invalid_address(invalid_address)
  );

  trigger_controller #(
      .NUM_CHANNELS(NUM_CHANNELS),
      .NUM_SOURCES(NUM_SOURCES),
      .DATA_SIZE(DATA_SIZE)
  ) trig (
      .CLK (CLK),
      .nRST(nRST),

      .trigger_in(trigger_in),

      .wen(wen),
      .ren(ren),
      .addr(addr),
      .wdata(wdata),
      .rdata(trigger_rdata),
      .addr_hit(trigger_hit),

      .consume_valid  (wen_w),
      .consume_channel(channel_select),

      .armed(trigger_armed),
      .credit_available(trigger_credit)
  );

  assign bus_if.rdata = trigger_hit ? trigger_rdata : rdata;
  assign bus_if.error = (invalid_address & !trigger_hit) | (bus_if.wen & !word_write);
  assign bus_if.request_stall = 1'b0;

  always_comb begin
    dma_interrupt = 1'b0;
    for (int i = 0; i < NUM_CHANNELS; i++) begin
      if (channel_control[i][27] || channel_control[i][26]) dma_interrupt = 1'b1;
    end
  end

endmodule
