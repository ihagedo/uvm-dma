// File:        dma_fifo.sv
// Author:      DMA-zing contributors
// Date:        2026-10-08
// Description: Queue with three-entry lookahead. Drops the entries of killed channels in one cycle.

module dma_fifo #(
    parameter int DATA_WIDTH = 32,
    parameter int DEPTH = 8,
    parameter int TAG_WIDTH = 1
) (
    input logic clk,
    input logic n_rst,
    // Bit per tag
    input logic [(1<<TAG_WIDTH)-1:0] kill_mask,
    input logic wen,
    input logic ren,
    input logic [DATA_WIDTH-1:0] data_in,
    output logic [DATA_WIDTH-1:0] data_out,
    output logic full,
    output logic empty,
    output logic [$clog2(DEPTH):0] count,

    // Burst lookahead
    output logic [DATA_WIDTH-1:0] peek1,
    output logic [DATA_WIDTH-1:0] peek2,
    output logic [DATA_WIDTH-1:0] peek3
);

  localparam int PTR_WIDTH = $clog2(DEPTH);
  localparam int CNT_WIDTH = PTR_WIDTH + 1;

  logic [PTR_WIDTH:0] wptr, rptr;
  logic [DATA_WIDTH-1:0] memory[DEPTH];

  logic [DATA_WIDTH-1:0] kept_memory[DEPTH];
  logic [PTR_WIDTH:0] kept_wptr;
  logic killing;

  assign killing = (kill_mask != '0);

  function automatic logic dead(input logic [DATA_WIDTH-1:0] entry);
    return kill_mask[entry[DATA_WIDTH-1-:TAG_WIDTH]];
  endfunction

  // Repack the survivors
  always_comb begin : COMPACT
    automatic int keep = 0;
    automatic logic [PTR_WIDTH:0] first = rptr + CNT_WIDTH'((ren && !empty) ? 1 : 0);
    automatic logic [PTR_WIDTH:0] live = wptr - first;
    automatic logic [PTR_WIDTH:0] slot = '0;
    kept_memory = memory;
    for (int i = 0; i < DEPTH; i++) begin
      slot = first + CNT_WIDTH'(i);
      if ((i < int'(live)) && !dead(memory[slot[PTR_WIDTH-1:0]])) begin
        kept_memory[keep] = memory[slot[PTR_WIDTH-1:0]];
        keep++;
      end
    end
    if (wen && !full && !dead(data_in)) begin
      kept_memory[keep] = data_in;
      keep++;
    end
    kept_wptr = CNT_WIDTH'(keep);
  end

  always_ff @(posedge clk or negedge n_rst) begin
    if (!n_rst) begin
      wptr <= '0;
      rptr <= '0;
      for (int i = 0; i < DEPTH; i++) memory[i] <= '0;
    end else if (killing) begin
      memory <= kept_memory;
      wptr   <= kept_wptr;
      rptr   <= '0;
    end else begin
      if (wen && !full) begin
        memory[wptr[PTR_WIDTH-1:0]] <= data_in;
        wptr <= wptr + CNT_WIDTH'(1);
      end
      if (ren && !empty) begin
        rptr <= rptr + CNT_WIDTH'(1);
      end
    end
  end

  assign data_out = memory[rptr[PTR_WIDTH-1:0]];
  assign full =
      (wptr[PTR_WIDTH] != rptr[PTR_WIDTH]) && (wptr[PTR_WIDTH-1:0] == rptr[PTR_WIDTH-1:0]);
  assign empty = (wptr == rptr);
  assign count = wptr - rptr;

  logic [PTR_WIDTH:0] rptr_p1, rptr_p2, rptr_p3;
  assign rptr_p1 = rptr + CNT_WIDTH'(1);
  assign rptr_p2 = rptr + CNT_WIDTH'(2);
  assign rptr_p3 = rptr + CNT_WIDTH'(3);

  assign peek1   = memory[rptr_p1[PTR_WIDTH-1:0]];
  assign peek2   = memory[rptr_p2[PTR_WIDTH-1:0]];
  assign peek3   = memory[rptr_p3[PTR_WIDTH-1:0]];

endmodule
