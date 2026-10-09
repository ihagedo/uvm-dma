// File:        channel_csr.sv
// Author:      DMA-zing contributors
// Date:        2026-10-08
// Description: Registers of one DMA channel.

`timescale 1ns / 10ps

module channel_csr #(
    parameter int DATA_SIZE = 32
) (
    // Clock and Reset
    input logic CLK,
    input logic nRST,

    input logic [DATA_SIZE-1:0] next_source_address,
    input logic [DATA_SIZE-1:0] next_destination_address,
    input logic [DATA_SIZE-1:0] next_control,
    input logic [DATA_SIZE-1:0] next_transfer_amount,

    input logic [DATA_SIZE-1:0] next_transfers_completed,
    input logic [DATA_SIZE-1:0] next_transfers_remaining,
    input logic [DATA_SIZE-1:0] next_current_channel_active,
    input logic [DATA_SIZE-1:0] next_error_address,


    output logic [DATA_SIZE-1:0] source_address,
    output logic [DATA_SIZE-1:0] destination_address,
    output logic [DATA_SIZE-1:0] control,
    output logic [DATA_SIZE-1:0] transfer_amount,

    output logic [DATA_SIZE-1:0] transfers_completed,
    output logic [DATA_SIZE-1:0] transfers_remaining,
    output logic [DATA_SIZE-1:0] current_channel_active,
    output logic [DATA_SIZE-1:0] error_address
);

  always_ff @(posedge CLK, negedge nRST) begin
    if (!nRST) begin
      source_address <= '0;
      destination_address <= '0;
      control <= '0;
      transfer_amount <= '0;

      transfers_completed <= '0;
      transfers_remaining <= '0;
      current_channel_active <= '0;
      error_address <= '0;
    end else begin
      source_address <= next_source_address;
      destination_address <= next_destination_address;
      control <= next_control;
      transfer_amount <= next_transfer_amount;
      transfers_completed <= next_transfers_completed;
      transfers_remaining <= next_transfers_remaining;
      current_channel_active <= next_current_channel_active;
      error_address <= next_error_address;
    end
  end

endmodule
