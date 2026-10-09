// File:        address_generator.sv
// Author:      DMA-zing contributors
// Date:        2026-10-08
// Description: Generates the granted channel's source and destination addresses into the read and write queues. With the spec 1.2 fixes.

`timescale 1ns / 10ps

module address_generator #(
    parameter int NUM_CHANNELS = 8,
    parameter int DATA_SIZE = 32
) (
    // Clock and Reset
    input logic CLK,
    input logic nRST,

    // Arbiter --> Address Generator
    input logic [$clog2(NUM_CHANNELS)-1:0] control,
    input logic arb_strobe,

    // Channel Registers --> Address Generator
    input logic [NUM_CHANNELS-1:0][DATA_SIZE-1:0] source_address,
    input logic [NUM_CHANNELS-1:0][DATA_SIZE-1:0] dest_address,
    input logic [NUM_CHANNELS-1:0][DATA_SIZE-1:0] channel_control,
    input logic [NUM_CHANNELS-1:0][DATA_SIZE-1:0] transfer_amount,

    // FIFOs --> Address Generator
    input logic full_r,
    input logic full_w,

    // Address Generator --> FIFOs
    output logic [DATA_SIZE+1+$clog2(NUM_CHANNELS):0] write_address_data_in,
    output logic [DATA_SIZE+1+$clog2(NUM_CHANNELS):0] read_address_data_in,
    output logic wen_w,
    output logic wen_r,

    // Address Generator --> Arbiter
    output logic [NUM_CHANNELS-1:0] channel_finished,

    // Address Generator --> Channel Manager
    output logic halt_generation,
    output logic abort_h
);

  // Modes
  localparam logic [2:0] ONESHOT = 3'd0;
  localparam logic [2:0] CONTINUOUS = 3'd1;
  localparam logic [2:0] RINGBUFFER = 3'd2;

  // Selected channel data from the Mux
  logic [DATA_SIZE-1:0] sel_source_address;
  logic [DATA_SIZE-1:0] sel_dest_address;
  logic [DATA_SIZE-1:0] sel_channel_control;
  logic [DATA_SIZE-1:0] sel_transfer_amount;

  always_comb begin
    integer i;

    sel_source_address = source_address[0];
    sel_dest_address = dest_address[0];
    sel_channel_control = channel_control[0];
    sel_transfer_amount = transfer_amount[0];

    for (i = 0; i < NUM_CHANNELS; i += 1) begin
      if (control == i[$clog2(NUM_CHANNELS)-1:0]) begin
        sel_source_address = source_address[i];
        sel_dest_address = dest_address[i];
        sel_channel_control = channel_control[i];
        sel_transfer_amount = transfer_amount[i];
      end
    end

  end

  logic [2:0] mode;
  logic [1:0] data_size;
  logic [DATA_SIZE-1:0] source_incr;
  logic [DATA_SIZE-1:0] dest_incr;
  // Which side steps
  logic buffer_sel;

  assign abort_h = sel_channel_control[24];
  assign mode[2:0] = sel_channel_control[6:4];
  assign source_incr[DATA_SIZE-1:0] = {24'd0, sel_channel_control[15:8]};
  assign dest_incr[DATA_SIZE-1:0] = {24'd0, sel_channel_control[23:16]};
  assign data_size[1:0] = sel_channel_control[1:0];
  assign buffer_sel = sel_channel_control[31];

  // Invalid configuration
  logic bad_config;
  assign bad_config = arb_strobe && ((mode > RINGBUFFER) || (data_size == 2'b11) ||
                                     (mode != RINGBUFFER && sel_transfer_amount == '0));

  // Counter outputs
  logic [DATA_SIZE-1:0] count_out_32;
  logic [DATA_SIZE-1:0] overflow_val_32;
  logic count_enable;
  logic clear;

  // Live against this channel
  logic at_last;
  assign at_last = arb_strobe && (count_out_32 == sel_transfer_amount);

  logic [NUM_CHANNELS-1:0] count_enable_ring;
  logic [NUM_CHANNELS-1:0][7:0] overflow_val_ring;
  logic [NUM_CHANNELS-1:0][7:0] count_out_ring;
  logic [NUM_CHANNELS-1:0] overflow_flag_ring;

  logic [NUM_CHANNELS-1:0][DATA_SIZE-1:0] recent_ring_address;
  logic [NUM_CHANNELS-1:0][DATA_SIZE-1:0] next_recent_ring_address;

  // Last push latch
  logic last_pushed;
  logic gen_done;
  logic [$clog2(NUM_CHANNELS)-1:0] control_q;
  logic grant_moved;
  assign last_pushed = (mode == ONESHOT) && at_last && wen_w;
  assign grant_moved = (control != control_q);

  // Finished this grant
  logic oneshot_finished;
  assign oneshot_finished = last_pushed || (gen_done && !grant_moved);

  always_ff @(posedge CLK, negedge nRST) begin
    if (!nRST) begin
      gen_done  <= 1'b0;
      control_q <= '0;
    end else begin
      control_q <= control;
      if (clear || grant_moved) gen_done <= 1'b0;
      else if (last_pushed) gen_done <= 1'b1;
    end
  end

  logic [DATA_SIZE-1:0] next_recent_source;
  logic [DATA_SIZE-1:0] next_recent_dest;
  logic [DATA_SIZE-1:0] recent_source;
  logic [DATA_SIZE-1:0] recent_dest;

  logic [NUM_CHANNELS-1:0] clear_ring;
  always_comb begin
    wen_r = 0;
    read_address_data_in = '0;
    next_recent_source = recent_source;
    count_enable = 0;

    wen_w = 0;
    write_address_data_in = '0;
    next_recent_dest = recent_dest;
    count_enable = 0;

    next_recent_ring_address = recent_ring_address;
    count_enable_ring = 0;
    if (mode == CONTINUOUS || mode == ONESHOT) begin
      if (full_r || full_w || !arb_strobe || abort_h || bad_config || !sel_channel_control[7] ||
          (gen_done && !grant_moved)) begin
        wen_r = 0;
        read_address_data_in = '0;
        next_recent_source = recent_source;
        count_enable = 0;

        wen_w = 0;
        write_address_data_in = '0;
        next_recent_dest = recent_dest;
        count_enable = 0;

        next_recent_ring_address = recent_ring_address;
        count_enable_ring = 0;
      end else if (count_out_32 == 0) begin
        wen_r = 0;
        read_address_data_in = '0;
        next_recent_source = recent_source;
        count_enable = 1;

        wen_w = 0;
        write_address_data_in = '0;
        next_recent_dest = recent_dest;
        count_enable = 1;

        next_recent_ring_address = recent_ring_address;
        count_enable_ring = 0;
      end else if (count_out_32 == 1) begin
        wen_r = 1;
        read_address_data_in = {control, data_size, sel_source_address};
        next_recent_source = sel_source_address;
        count_enable = 1;

        wen_w = 1;
        write_address_data_in = {control, data_size, sel_dest_address};
        next_recent_dest = sel_dest_address;
        count_enable = 1;

        next_recent_ring_address = recent_ring_address;
        count_enable_ring = 0;
      end else begin
        wen_r = 1;
        read_address_data_in = {control, data_size, recent_source + source_incr};
        next_recent_source = recent_source + source_incr;
        count_enable = 1;

        wen_w = 1;
        write_address_data_in = {control, data_size, recent_dest + dest_incr};
        next_recent_dest = recent_dest + dest_incr;
        count_enable = 1;

        next_recent_ring_address = recent_ring_address;
        count_enable_ring = 0;
      end
    end else if (mode == RINGBUFFER) begin
      if (full_r || full_w || !arb_strobe || abort_h || bad_config || !sel_channel_control[7]) begin
        wen_r = 0;
        wen_w = 0;
        read_address_data_in = '0;
        write_address_data_in = '0;
        next_recent_ring_address[control] = recent_ring_address[control];
        count_enable_ring = '0;

        next_recent_source = recent_source;
        next_recent_dest = recent_dest;
        count_enable = '0;
      end else if (count_out_ring[control] == 0) begin
        wen_r = 0;
        read_address_data_in = '0;
        next_recent_source = recent_source;
        count_enable = 0;

        wen_w = 0;
        write_address_data_in = '0;
        next_recent_dest = recent_dest;
        count_enable = 0;

        next_recent_ring_address[control] = recent_ring_address[control];
        count_enable_ring[control] = 1;
      end else if (count_out_ring[control] == 1) begin
        wen_r = 1;
        wen_w = 1;
        read_address_data_in = {control, data_size, sel_source_address};
        write_address_data_in = {control, data_size, sel_dest_address};
        next_recent_ring_address[control] = buffer_sel ? sel_dest_address : sel_source_address;
        count_enable_ring[control] = 1;

        next_recent_source = recent_source;
        next_recent_dest = recent_dest;
        count_enable = 0;
      end else if (buffer_sel == 0) begin
        wen_r = 1;
        wen_w = 1;
        read_address_data_in = {control, data_size, recent_ring_address[control] + source_incr};
        write_address_data_in = {control, data_size, sel_dest_address};
        next_recent_ring_address[control] = recent_ring_address[control] + source_incr;
        count_enable_ring[control] = 1;

        next_recent_source = recent_source;
        next_recent_dest = recent_dest;
        count_enable = 0;
      end else begin
        wen_r = 1;
        wen_w = 1;
        read_address_data_in = {control, data_size, sel_source_address};
        write_address_data_in = {control, data_size, recent_ring_address[control] + dest_incr};
        next_recent_ring_address[control] = recent_ring_address[control] + dest_incr;
        count_enable_ring[control] = 1;

        next_recent_source = recent_source;
        next_recent_dest = recent_dest;
        count_enable = 0;
      end
    end

    for (int i = 0; i < NUM_CHANNELS; i++) begin
      if (clear_ring[i]) next_recent_ring_address[i] = '0;
    end
  end

  always_ff @(posedge CLK, negedge nRST) begin
    if (!nRST) begin
      recent_source <= 32'd0;
      recent_dest   <= 32'd0;
    end else begin
      recent_source <= next_recent_source;
      recent_dest   <= next_recent_dest;
    end
  end

  assign overflow_val_32[DATA_SIZE-1:0] =
      (arb_strobe && mode != RINGBUFFER) ? sel_transfer_amount[DATA_SIZE-1:0] : '1;
  assign clear = ~arb_strobe || abort_h || !sel_channel_control[7];

  socetlib_counter #(
      .NBITS(32)
  ) counter_32bit (
      .CLK(CLK),
      .nRST(nRST),
      .clear(clear),
      .count_enable(count_enable),
      .overflow_val(overflow_val_32),
      .count_out(count_out_32),
      .overflow_flag()
  );

  always_comb begin
    halt_generation = 0;
    if (bad_config) begin
      halt_generation = 1;
    end else if ((mode == ONESHOT) && oneshot_finished) begin
      halt_generation = 1;
    end else if (mode == CONTINUOUS) begin
      halt_generation = abort_h;
    end else if (mode == RINGBUFFER) begin
      halt_generation = abort_h;
    end
  end

  // Ring buffer


  // Stopped rings restart
  always_comb begin
    for (integer i = 0; i < NUM_CHANNELS; i++) begin
      clear_ring[i] = channel_control[i][24] || !channel_control[i][7];
      overflow_val_ring[i] = 8'd1 << channel_control[i][30:28];
    end
  end

  // Per channel counters
  generate
    genvar gi;
    for (gi = 0; gi < NUM_CHANNELS; gi++) begin : g_ring_counters
      socetlib_counter #(
          .NBITS(8)
      ) ringcounter (
          .CLK(CLK),
          .nRST(nRST),
          .clear(clear_ring[gi]),
          .count_enable(count_enable_ring[gi]),
          .overflow_val(overflow_val_ring[gi]),
          .count_out(count_out_ring[gi]),
          .overflow_flag(overflow_flag_ring[gi])
      );
    end
  endgenerate

  always_ff @(posedge CLK, negedge nRST) begin
    if (!nRST) begin
      recent_ring_address <= '0;
    end else begin
      recent_ring_address <= next_recent_ring_address;
    end
  end

  logic ring_pass_done;
  assign ring_pass_done = (mode == RINGBUFFER) && wen_w && overflow_flag_ring[control];


  always_comb begin
    if (bad_config) begin
      channel_finished[NUM_CHANNELS-1:0] = NUM_CHANNELS'(1) << control;
    end else if (mode == ONESHOT) begin
      if (oneshot_finished) begin
        channel_finished[NUM_CHANNELS-1:0] = NUM_CHANNELS'(1) << control;
      end else begin
        channel_finished[NUM_CHANNELS-1:0] = 0;
      end
    end else if (mode == CONTINUOUS) begin
      if (abort_h) begin
        channel_finished[NUM_CHANNELS-1:0] = NUM_CHANNELS'(1) << control;
      end else begin
        channel_finished[NUM_CHANNELS-1:0] = 0;
      end
    end else if (mode == RINGBUFFER) begin
      if (ring_pass_done || abort_h) begin
        channel_finished[NUM_CHANNELS-1:0] = NUM_CHANNELS'(1) << control;
      end else begin
        channel_finished[NUM_CHANNELS-1:0] = 0;
      end
    end else begin
      channel_finished[NUM_CHANNELS-1:0] = NUM_CHANNELS'(arb_strobe) << control;
    end
  end

endmodule
