// File:        channel_manager.sv
// Author:      DMA-zing contributors
// Date:        2026-10-08
// Description: Register map, run control, DONE, ERROR and status for every channel. With the spec 1.2 fixes.

`timescale 1ns / 10ps

/*verilator lint_off CASEINCOMPLETE */
/* verilator lint_off UNUSEDSIGNAL */

module channel_manager #(
    parameter int NUM_CHANNELS = 8,
    parameter int DATA_SIZE = 32
) (
    input logic CLK,
    nRST,
    input logic wen,
    ren,
    input logic [31:0] addr,
    input logic [31:0] wdata,

    input logic [$clog2(NUM_CHANNELS)-1:0] ch_sel,
    input logic arb_enabled,
    input logic [NUM_CHANNELS-1:0] ch_finished,
    input logic transfer_completed,
    input logic [$clog2(NUM_CHANNELS)-1:0] completed_channel,

    input logic [31:0] write_error_addr,
    input logic [31:0] read_error_addr,

    input logic write_error_flag,
    input logic read_error_flag,

    input logic [$clog2(NUM_CHANNELS)-1:0] write_error_channel,
    input logic [$clog2(NUM_CHANNELS)-1:0] read_error_channel,
    input logic halt_generation,
    input logic abort_h,

    input logic [NUM_CHANNELS-1:0] trigger_armed,
    input logic [NUM_CHANNELS-1:0] trigger_credit,

    output logic [31:0] rdata,
    output logic [NUM_CHANNELS-1:0] channel_request,
    output logic [NUM_CHANNELS-1:0] start_kill,  // Drop a restarted channel's old items

    output logic [NUM_CHANNELS-1:0][DATA_SIZE-1:0] source_address,
    output logic [NUM_CHANNELS-1:0][DATA_SIZE-1:0] destination_address,
    output logic [NUM_CHANNELS-1:0][DATA_SIZE-1:0] control,
    output logic [NUM_CHANNELS-1:0][DATA_SIZE-1:0] transfer_amount,

    output logic invalid_address
);
  // Register offsets
  localparam logic [3:0] SOURCE = 4'h0;
  localparam logic [3:0] DESTINATION = 4'h4;
  localparam logic [3:0] CONTROL = 4'h8;
  localparam logic [3:0] DESIRED_TRANSFERS = 4'hC;

  localparam logic [2:0] ONESHOT = 3'd0;
  localparam logic [2:0] CONTINUOUS = 3'd1;
  localparam logic [2:0] RINGBUFFER = 3'd2;

  localparam logic [3:0] TRANSFERS_COMPLETED = 4'h0;
  localparam logic [3:0] TRANSFERS_REMAINING = 4'h4;
  localparam logic [3:0] CURRENT_CHANNEL_ACTIVE = 4'h8;
  localparam logic [3:0] ERROR_ADDRESS = 4'hC;

  // Register next values
  logic [NUM_CHANNELS-1:0][DATA_SIZE-1:0] next_source_address;
  logic [NUM_CHANNELS-1:0][DATA_SIZE-1:0] next_destination_address;
  logic [NUM_CHANNELS-1:0][DATA_SIZE-1:0] next_control;
  logic [NUM_CHANNELS-1:0][DATA_SIZE-1:0] next_transfer_amount;
  logic [NUM_CHANNELS-1:0][DATA_SIZE-1:0] next_transfers_completed;
  logic [NUM_CHANNELS-1:0][DATA_SIZE-1:0] next_transfers_remaining;
  logic [NUM_CHANNELS-1:0][DATA_SIZE-1:0] next_current_channel_active;
  logic [NUM_CHANNELS-1:0][DATA_SIZE-1:0] next_error_address;

  logic [NUM_CHANNELS-1:0][DATA_SIZE-1:0] transfers_completed;
  logic [NUM_CHANNELS-1:0][DATA_SIZE-1:0] transfers_remaining;
  logic [NUM_CHANNELS-1:0][DATA_SIZE-1:0] current_channel_active;
  logic [NUM_CHANNELS-1:0][DATA_SIZE-1:0] error_address;

  // Open runs
  logic [NUM_CHANNELS-1:0] run_active, next_run_active;
  logic [NUM_CHANNELS-1:0] run_start, run_stop;
  logic [NUM_CHANNELS-1:0] oneshot_done;
  logic [NUM_CHANNELS-1:0] pass_done;
  logic [NUM_CHANNELS-1:0] trigger_block;
  logic [NUM_CHANNELS-1:0] bad_cfg;

  // Items per pass
  function automatic logic [DATA_SIZE-1:0] pass_length(input logic [DATA_SIZE-1:0] ctrl,
                                                       input logic [DATA_SIZE-1:0] amount);
    return (ctrl[6:4] == RINGBUFFER) ? DATA_SIZE'(1) << ctrl[30:28] : amount;
  endfunction

  always_comb begin : TRIGGER_BLOCK
    for (int i = 0; i < NUM_CHANNELS; i++) begin
      trigger_block[i] = trigger_armed[i] && (control[i][6:4] != RINGBUFFER);
    end
  end

  logic [$clog2(NUM_CHANNELS)-1:0] write_channel;
  logic control_written;
  always_comb begin : RUN_EDGES
    for (int i = 0; i < NUM_CHANNELS; i++) begin
      run_start[i] = control_written && (write_channel == i[$clog2(NUM_CHANNELS)-1:0]) &&
          wdata[7] && !run_active[i];
      run_stop[i] = (control_written && (write_channel == i[$clog2(NUM_CHANNELS)-1:0]) && !wdata[7])
          || control[i][24] || (abort_h && (ch_sel == i[$clog2(NUM_CHANNELS)-1:0]));
    end
  end

  // Errors on items dropped by a restart are ignored
  logic wr_err, rd_err;
  assign wr_err = write_error_flag && !run_start[write_error_channel] &&
      !start_kill[write_error_channel];
  assign rd_err = read_error_flag && !run_start[read_error_channel] &&
      !start_kill[read_error_channel];

  // Invalid configuration
  always_comb begin : BAD_CONFIG
    for (int i = 0; i < NUM_CHANNELS; i++) begin
      bad_cfg[i] = run_active[i] &&
          ((control[i][6:4] > RINGBUFFER) || (control[i][1:0] == 2'b11) ||
           (control[i][6:4] != RINGBUFFER && transfer_amount[i] == '0));
    end
  end

  always_comb begin : ONESHOT_DONE
    for (int i = 0; i < NUM_CHANNELS; i++) begin
      oneshot_done[i] = run_active[i] && !control[i][7] && (control[i][6:4] == ONESHOT) &&
          (transfers_completed[i] == transfer_amount[i]);
    end
  end

  // Pass fully landed
  always_comb begin : PASS_DONE
    for (int i = 0; i < NUM_CHANNELS; i++) begin
      pass_done[i] = run_active[i] && transfer_completed &&
          (completed_channel == i[$clog2(NUM_CHANNELS)-1:0]) &&
          (control[i][6:4] == CONTINUOUS || control[i][6:4] == RINGBUFFER) &&
          (transfers_remaining[i] <= 1);
    end
  end

  always_ff @(posedge CLK, negedge nRST) begin
    if (!nRST) begin
      run_active <= '0;
      start_kill <= '0;
    end else begin
      run_active <= next_run_active;
      start_kill <= run_start;
    end
  end

  logic [$clog2(NUM_CHANNELS)-1:0] read_channel;
  logic [DATA_SIZE-1:0] normalized_control;
  logic [DATA_SIZE-1:0] normalized_status;
  logic control_range;
  logic status_range;
  logic [11:0] window_addr;
  logic [3:0] control_feature;
  logic [3:0] status_feature;
  logic mapped_address;

  always_comb begin : ADDRESS_DECODE
    // Status block follows control
    normalized_control = addr;
    normalized_status = addr + (NUM_CHANNELS << 4);

    write_channel = normalized_control[(4-1)+$clog2(NUM_CHANNELS):4];
    read_channel = normalized_status[(4-1)+$clog2(NUM_CHANNELS):4];
    control_feature = normalized_control[3:0];
    status_feature = normalized_status[3:0];

    window_addr = addr[11:0];
    control_range = (window_addr < 12'(NUM_CHANNELS * 16));
    status_range = (window_addr >= 12'(NUM_CHANNELS * 16)) &&
        (window_addr < 12'(NUM_CHANNELS * 32));

    control_written = wen && control_range && (control_feature == CONTROL);
  end

  always_comb begin : UNMAPPED_CHECK
    mapped_address = 0;
    if (control_range) begin
      case (control_feature)
        SOURCE, DESTINATION, CONTROL, DESIRED_TRANSFERS: mapped_address = 1;
        default: ;
      endcase
    end else if (status_range) begin
      case (status_feature)
        TRANSFERS_COMPLETED, TRANSFERS_REMAINING, CURRENT_CHANNEL_ACTIVE, ERROR_ADDRESS:
        mapped_address = 1;
        default: ;
      endcase
    end

    invalid_address = !mapped_address && (ren | wen);
  end

  always_comb begin : READ_DATA
    rdata = 32'hDEADBEEF;

    if (ren && control_range) begin
      case (control_feature)
        SOURCE: rdata = source_address[read_channel];
        DESTINATION: rdata = destination_address[read_channel];
        CONTROL: rdata = control[read_channel];
        DESIRED_TRANSFERS: rdata = transfer_amount[read_channel];
        default: ;
      endcase
    end
    if (ren && status_range) begin
      case (status_feature)
        TRANSFERS_COMPLETED: rdata = transfers_completed[read_channel];
        TRANSFERS_REMAINING: rdata = transfers_remaining[read_channel];
        CURRENT_CHANNEL_ACTIVE: rdata = current_channel_active[read_channel];
        ERROR_ADDRESS: rdata = error_address[read_channel];
        default: ;
      endcase
    end
  end

  always_comb begin : CONFIG_WRITE
    next_source_address = source_address;
    next_destination_address = destination_address;
    next_transfer_amount = transfer_amount;

    if (wen && control_range) begin
      case (control_feature)
        SOURCE: next_source_address[write_channel] = wdata;
        DESTINATION: next_destination_address[write_channel] = wdata;
        DESIRED_TRANSFERS: next_transfer_amount[write_channel] = wdata;
        default: ;
      endcase
    end
  end

  always_comb begin : CONTROL_NEXT
    next_control = control;
    if (control_written) next_control[write_channel] = wdata;
    // Running keeps enable
    if (control_written && wdata[7] && run_active[write_channel])
      next_control[write_channel][7] = control[write_channel][7];

    // A starting write wins
    if ((halt_generation != 0 || abort_h) && !run_start[ch_sel]) next_control[ch_sel][7] = 0;
    for (int i = 0; i < NUM_CHANNELS; i++) begin
      if ((trigger_block[i] || control[i][24] || bad_cfg[i]) && !run_start[i]) next_control[i][7] = 0;
    end
    if (wr_err) next_control[write_error_channel][7] = 0;
    if (rd_err) next_control[read_error_channel][7] = 0;

    // Error bit
    if (wr_err) next_control[write_error_channel][26] = 1;
    if (rd_err) next_control[read_error_channel][26] = 1;

    // Abort clears once disabled
    for (int i = 0; i < NUM_CHANNELS; i++) begin
      if (control[i][24] && !control[i][7]) begin
        if (!(control_written && write_channel == i[$clog2(NUM_CHANNELS)-1:0]))
          next_control[i][24] = 0;
      end
    end

    // Done bit, hardware wins
    for (int i = 0; i < NUM_CHANNELS; i++) begin
      if (oneshot_done[i] || pass_done[i] || bad_cfg[i]) next_control[i][27] = 1;
    end
  end

  always_comb begin : RUN_TRACKING
    next_run_active = run_active;
    for (int i = 0; i < NUM_CHANNELS; i++) begin
      if (run_stop[i] || oneshot_done[i] || bad_cfg[i] || trigger_block[i]) next_run_active[i] = 0;
    end
    if (wr_err) next_run_active[write_error_channel] = 0;
    if (rd_err) next_run_active[read_error_channel] = 0;
    for (int i = 0; i < NUM_CHANNELS; i++) begin
      if (run_start[i]) next_run_active[i] = 1;
    end
  end

  always_comb begin : STATUS_NEXT
    next_transfers_completed = transfers_completed;
    next_transfers_remaining = transfers_remaining;
    next_current_channel_active = current_channel_active;
    next_error_address = error_address;

    next_current_channel_active[ch_sel] = DATA_SIZE'(arb_enabled) << ch_sel;
    if (ch_finished != '0) next_current_channel_active[ch_sel] = '0;
    if (transfer_completed) begin
      next_transfers_completed[completed_channel] = transfers_completed[completed_channel] + 1;
      if (control[completed_channel][6:4] != CONTINUOUS &&
          control[completed_channel][6:4] != RINGBUFFER)
        next_transfers_remaining[completed_channel] =
            transfer_amount[completed_channel] - (transfers_completed[completed_channel] + 1);
      else if (transfers_remaining[completed_channel] <= 1)
        next_transfers_remaining[completed_channel] = pass_length(
          control[completed_channel], transfer_amount[completed_channel]
        );
      else next_transfers_remaining[completed_channel] = transfers_remaining[completed_channel] - 1;
    end

    if (wr_err) next_error_address[write_error_channel] = write_error_addr;
    if (rd_err) next_error_address[read_error_channel] = read_error_addr;

    // New run
    if (run_start[write_channel]) begin
      next_transfers_completed[write_channel] = '0;
      next_transfers_remaining[write_channel] = pass_length(wdata, transfer_amount[write_channel]);
      next_error_address[write_channel] = '0;
    end
  end

  // Instantiate the registers for each channel
  generate
    genvar gi;
    for (gi = 0; gi < NUM_CHANNELS; gi++) begin : g_channel_registers
      channel_csr #(
          .DATA_SIZE(DATA_SIZE)
      ) ch (
          .CLK(CLK),
          .nRST(nRST),
          .next_source_address(next_source_address[gi]),
          .next_destination_address(next_destination_address[gi]),
          .next_control(next_control[gi]),
          .next_transfer_amount(next_transfer_amount[gi]),
          .next_transfers_completed(next_transfers_completed[gi]),
          .next_transfers_remaining(next_transfers_remaining[gi]),
          .next_current_channel_active(next_current_channel_active[gi]),
          .next_error_address(next_error_address[gi]),
          .source_address(source_address[gi]),
          .destination_address(destination_address[gi]),
          .control(control[gi]),
          .transfer_amount(transfer_amount[gi]),
          .transfers_completed(transfers_completed[gi]),
          .transfers_remaining(transfers_remaining[gi]),
          .current_channel_active(current_channel_active[gi]),
          .error_address(error_address[gi])
      );
    end
  endgenerate

  always_comb begin : CHANNEL_REQUEST
    for (integer i = 0; i < NUM_CHANNELS; i++) begin
      channel_request[i] = control[i][7] && !ch_finished[i] && !trigger_block[i] && !bad_cfg[i] &&
          (!trigger_armed[i] || trigger_credit[i]);
    end
  end

endmodule
