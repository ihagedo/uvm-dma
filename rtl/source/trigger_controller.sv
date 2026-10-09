// File:        trigger_controller.sv
// Author:      DMA-zing contributors
// Date:        2026-10-08
// Description: Trigger edge detection, credits and the trigger registers.

`timescale 1ns / 10ps

module trigger_controller #(
    parameter int NUM_CHANNELS = 8,
    parameter int NUM_SOURCES  = 32,
    parameter int DATA_SIZE    = 32,
    parameter int CREDIT_WIDTH = 12
) (
    input logic CLK,
    input logic nRST,

    input logic [NUM_SOURCES-1:0] trigger_in,

    input  logic                 wen,
    input  logic                 ren,
    input  logic [DATA_SIZE-1:0] addr,
    input  logic [DATA_SIZE-1:0] wdata,
    output logic [DATA_SIZE-1:0] rdata,
    output logic                 addr_hit,

    input logic                            consume_valid,
    input logic [$clog2(NUM_CHANNELS)-1:0] consume_channel,

    output logic [NUM_CHANNELS-1:0] armed,
    output logic [NUM_CHANNELS-1:0] credit_available
);

  localparam int SelWidth = $clog2(NUM_SOURCES);
  localparam int ChWidth = $clog2(NUM_CHANNELS);
  localparam int CountWidth = 8;
  localparam int CountLsb = 16;
  // Armed or not
  localparam int ArmBit = 7;
  localparam int OverrunBit = 16;

  localparam logic [DATA_SIZE-1:0] BlockBase = DATA_SIZE'(NUM_CHANNELS * 32);
  localparam logic [DATA_SIZE-1:0] BlockSize = DATA_SIZE'(NUM_CHANNELS * 8);
  localparam logic [DATA_SIZE-1:0] CfgReset = DATA_SIZE'(1) << CountLsb;
  localparam logic [CREDIT_WIDTH-1:0] CreditMax = '1;

  logic [NUM_SOURCES-1:0] trigger_q;
  logic [NUM_SOURCES-1:0] trigger_edge;

  logic [NUM_CHANNELS-1:0][DATA_SIZE-1:0] cfg, next_cfg;
  // Items still owed
  logic [NUM_CHANNELS-1:0][CREDIT_WIDTH-1:0] credit, next_credit;
  logic [NUM_CHANNELS-1:0] overrun, next_overrun;

  // Which wire
  logic [NUM_CHANNELS-1:0][    SelWidth-1:0] source_sel;
  // Items per trigger
  logic [NUM_CHANNELS-1:0][  CountWidth-1:0] count_n;
  logic [NUM_CHANNELS-1:0][CREDIT_WIDTH-1:0] grant_amount;
  logic [NUM_CHANNELS-1:0][  CREDIT_WIDTH:0] credit_sum;
  logic [NUM_CHANNELS-1:0][CREDIT_WIDTH-1:0] credit_base;
  logic [NUM_CHANNELS-1:0] fired, take, saturated;

  logic in_range;
  logic reg_is_status;
  logic [ChWidth-1:0] reg_channel;
  logic cfg_write, status_write;
  logic wdata_arm;

  assign in_range = (addr >= BlockBase) && (addr < (BlockBase + BlockSize));
  assign addr_hit = in_range;
  assign reg_channel = addr[ChWidth+2:3];
  assign reg_is_status = addr[2];
  assign cfg_write = wen && in_range && !reg_is_status;
  assign status_write = wen && in_range && reg_is_status;
  assign wdata_arm = wdata[ArmBit];

  always_ff @(posedge CLK, negedge nRST) begin
    if (!nRST) trigger_q <= '0;
    else trigger_q <= trigger_in;
  end

  assign trigger_edge = trigger_in & ~trigger_q;

  generate
    genvar gi;
    for (gi = 0; gi < NUM_CHANNELS; gi++) begin : g_channel
      assign source_sel[gi] = cfg[gi][SelWidth-1:0];
      assign armed[gi] = cfg[gi][ArmBit];
      assign count_n[gi] = cfg[gi][CountLsb+CountWidth-1:CountLsb];

      assign fired[gi] = armed[gi] && trigger_edge[source_sel[gi]];
      assign take[gi] = consume_valid && (consume_channel == ChWidth'(gi)) && (credit[gi] != '0);
      assign grant_amount[gi] = fired[gi] ? CREDIT_WIDTH'(count_n[gi]) : '0;

      assign credit_sum[gi] = {1'b0, credit[gi]} + {1'b0, grant_amount[gi]} -
          (CREDIT_WIDTH + 1)'(take[gi]);
      assign saturated[gi] = credit_sum[gi][CREDIT_WIDTH];
      assign credit_base[gi] = saturated[gi] ? CreditMax : credit_sum[gi][CREDIT_WIDTH-1:0];

      assign credit_available[gi] = (next_credit[gi] != '0);
    end
  endgenerate

  always_comb begin
    for (int i = 0; i < NUM_CHANNELS; i++) begin
      next_cfg[i] = cfg[i];
      next_credit[i] = credit_base[i];
      next_overrun[i] = overrun[i] || saturated[i];
    end

    // Fresh overrun wins
    if (status_write && !saturated[reg_channel]) next_overrun[reg_channel] = 1'b0;

    if (cfg_write) begin
      next_cfg[reg_channel] = wdata;
      if (!wdata_arm) next_credit[reg_channel] = '0;
    end
  end

  always_ff @(posedge CLK, negedge nRST) begin
    if (!nRST) begin
      cfg <= {NUM_CHANNELS{CfgReset}};
      credit <= '0;
      overrun <= '0;
    end else begin
      cfg <= next_cfg;
      credit <= next_credit;
      overrun <= next_overrun;
    end
  end

  always_comb begin
    rdata = '0;
    if (ren && in_range) begin
      if (reg_is_status) begin
        rdata[CREDIT_WIDTH-1:0] = credit[reg_channel];
        rdata[OverrunBit] = overrun[reg_channel];
      end else begin
        rdata = cfg[reg_channel];
      end
    end
  end

endmodule
