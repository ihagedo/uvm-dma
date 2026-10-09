// File:        dma_arbiter.sv
// Author:      DMA-zing contributors
// Date:        2026-10-08
// Description: Round-robin arbiter over the requesting channels.

`timescale 1ns / 10ps

module dma_arbiter #(
    parameter int NUM_CHANNELS = 8
) (
    input logic CLK,
    input logic nRST,
    input logic [NUM_CHANNELS-1:0] channel_request,
    input logic [NUM_CHANNELS-1:0] channel_finish,
    output logic enabled,
    output logic [$clog2(NUM_CHANNELS)-1:0] channel_select  // granted channel
);


  logic [$clog2(NUM_CHANNELS)-1:0] next_select_candidate;

  logic [$clog2(NUM_CHANNELS)-1:0] next_select;

  localparam int IDX_WIDTH = $clog2(NUM_CHANNELS);
  logic [IDX_WIDTH-1:0] grant_idx;

  logic next_enabled;


  always_ff @(posedge CLK, negedge nRST) begin
    if (~nRST) begin
      channel_select <= '0;
      enabled <= 0;
    end else begin
      channel_select <= next_select;
      enabled <= next_enabled;
    end
  end



  always_comb begin
    next_select = channel_select;

    if (!enabled || !channel_request[channel_select] || (channel_finish == (1 << channel_select))) begin
      next_select = next_select_candidate;
    end
  end



  always_comb begin
    next_select_candidate = '0;
    next_enabled = 1'b0;

    for (int i = 0; i < NUM_CHANNELS; i += 1) begin
      grant_idx = IDX_WIDTH'(i) + channel_select;

      if (!next_enabled && channel_request[grant_idx]) begin
        next_select_candidate = grant_idx;
        next_enabled = 1'b1;
      end
    end
  end

endmodule
