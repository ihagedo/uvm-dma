// File:        ahb_read_manager.sv
// Author:      DMA-zing contributors
// Date:        2026-10-08
// Description: AHB manager that reads source items into the transfer queue, with INCR4 bursts. With the spec 1.2 fixes.

`timescale 1ns / 10ps

module ahb_read_manager #(
    parameter int DATA_SIZE  = 32,
    parameter int FIFO_DEPTH = 16,
    parameter int TAG_WIDTH  = 3
) (
    input logic clk,
    input logic n_rst,
    ahb_if.manager ahb_m,

    input logic [DATA_SIZE+1+TAG_WIDTH:0] raddr_fifo_rdata,
    input logic raddr_fifo_empty,
    input logic [$clog2(FIFO_DEPTH):0] raddr_fifo_count,  // For burst check
    output logic raddr_fifo_ren,
    input logic [DATA_SIZE+1+TAG_WIDTH:0] raddr_fifo_peek1,
    input logic [DATA_SIZE+1+TAG_WIDTH:0] raddr_fifo_peek2,
    input logic [DATA_SIZE+1+TAG_WIDTH:0] raddr_fifo_peek3,

    // Transfer Data FIFO
    input logic tdata_fifo_full,
    input logic [$clog2(FIFO_DEPTH):0] tdata_fifo_count,
    output logic [DATA_SIZE-1:0] tdata_fifo_wdata,
    output logic [TAG_WIDTH-1:0] tdata_fifo_wtag,
    output logic tdata_fifo_wen,

    // Killed channels
    input logic [(1<<TAG_WIDTH)-1:0] kill_mask,

    // Status
    output logic error_flag,  // One-cycle pulse on AHB error
    output logic [DATA_SIZE-1:0] read_error_addr,  // Latched address that caused error
    output logic [TAG_WIDTH-1:0] read_error_tag,  // Channel that owned the faulting address
    output logic transfer_active
);
  // AHB constants
  localparam logic [1:0] IDLE = 2'b00;
  localparam logic [1:0] NONSEQ = 2'b10;
  localparam logic [1:0] SEQ = 2'b11;
  localparam logic [2:0] SINGLE = 3'b000;
  localparam logic [2:0] INCR4 = 3'b011;
  localparam logic [2:0] WORD = 3'b010;

  typedef enum logic [2:0] {
    RD_IDLE,  // No activity
    RD_FIRST_ADDR,  // First address phase of a new transaction
    RD_PIPE,  // Presenting address N+1 while collecting data for address N
    RD_LAST_DATA,  // Collecting data for the last accepted address
    RD_FIFO_PUSH,  // transfer data FIFO is full
    RD_ERROR  // One cycle error
  } state_t;

  state_t current_state, next_state;

  logic [DATA_SIZE-1:0] current_addr, next_addr;
  logic [1:0] current_size, next_size;
  logic [TAG_WIDTH-1:0] current_tag, next_tag;
  logic [1:0] beat_count, next_beat_count;
  logic [DATA_SIZE-1:0] captured_data, next_captured_data;
  logic [DATA_SIZE-1:0] dphase_addr, next_dphase_addr;  // Addr whose data phase is active
  logic [1:0] dphase_size, next_dphase_size;  // Size of the active data phase
  logic [TAG_WIDTH-1:0] captured_tag, next_captured_tag;
  logic current_dead, next_current_dead;
  logic dphase_dead, next_dphase_dead;
  logic captured_dead, next_captured_dead;
  logic error_dead, next_error_dead;  // ERROR hit an item that was already dropped
  logic pipe_live, next_pipe_live;
  logic load_dphase, load_captured;
  logic [TAG_WIDTH-1:0] dphase_tag, next_dphase_tag;  // Channel owning the active data phase

  // Item address aligned to its size
  function automatic logic [DATA_SIZE-1:0] size_align(input logic [DATA_SIZE-1:0] a,
                                                      input logic [1:0] size);
    case (size)
      2'b00:   return a;
      2'b01:   return {a[DATA_SIZE-1:1], 1'b0};
      default: return {a[DATA_SIZE-1:2], 2'b00};
    endcase
  endfunction

  function automatic logic [DATA_SIZE-1:0] lane_extract(
      input logic [DATA_SIZE-1:0] word, input logic [1:0] size, input logic [1:0] lane);
    case (size)
      2'b00:   return {24'd0, word[8*lane+:8]};
      2'b01:   return {16'd0, word[16*lane[1]+:16]};
      default: return word;
    endcase
  endfunction
  logic [DATA_SIZE-1:0] error_addr_reg, next_error_addr_reg;
  logic [TAG_WIDTH-1:0] error_tag_reg, next_error_tag_reg;
  logic is_burst, next_is_burst;

  // Burst eligibility check
  logic [DATA_SIZE-1:0] head_addr;
  assign head_addr = raddr_fifo_rdata[DATA_SIZE-1:0];
  logic consecutive_words;
  assign consecutive_words = (raddr_fifo_peek1[DATA_SIZE-1:0] == head_addr + 32'd4) &&
      (raddr_fifo_peek2[DATA_SIZE-1:0] == head_addr + 32'd8) &&
      (raddr_fifo_peek3[DATA_SIZE-1:0] == head_addr + 32'd12) &&
      (raddr_fifo_peek1[DATA_SIZE+1+TAG_WIDTH:DATA_SIZE] ==
       raddr_fifo_rdata[DATA_SIZE+1+TAG_WIDTH:DATA_SIZE]) &&
      (raddr_fifo_peek2[DATA_SIZE+1+TAG_WIDTH:DATA_SIZE] ==
       raddr_fifo_rdata[DATA_SIZE+1+TAG_WIDTH:DATA_SIZE]) &&
      (raddr_fifo_peek3[DATA_SIZE+1+TAG_WIDTH:DATA_SIZE] ==
       raddr_fifo_rdata[DATA_SIZE+1+TAG_WIDTH:DATA_SIZE]);
  // Room for four beats
  logic room_for_burst;
  assign room_for_burst = (int'(tdata_fifo_count) + 6 <= FIFO_DEPTH);
  logic burst_mode;
  assign burst_mode = (raddr_fifo_count >= 4) && room_for_burst && (head_addr[9:2] <= 8'hFC) &&
      (raddr_fifo_rdata[DATA_SIZE+1:DATA_SIZE] == 2'b10) && consecutive_words;

  logic [TAG_WIDTH-1:0] raddr_fifo_tag;
  assign raddr_fifo_tag = raddr_fifo_rdata[DATA_SIZE+1+TAG_WIDTH:DATA_SIZE+2];

  // Queue head is not being dropped this cycle
  logic raddr_avail;
  assign raddr_avail = !raddr_fifo_empty && !kill_mask[raddr_fifo_tag];

  logic dphase_gone, captured_gone, current_gone;
  assign dphase_gone   = dphase_dead || kill_mask[dphase_tag];
  assign captured_gone = captured_dead || kill_mask[captured_tag];
  assign current_gone  = current_dead || kill_mask[current_tag];

  // The last beat of the current transaction
  logic end_of_transaction;
  assign end_of_transaction = !is_burst || (beat_count == 2'd3);

  // Remaining beats of a burst whose channel was dropped
  logic beat_dead;
  assign beat_dead = !end_of_transaction && current_gone;

  // Next beat's address: the queue head, or the next word of a dropped burst
  logic [DATA_SIZE-1:0] beat_addr;
  assign beat_addr = current_gone ? current_addr + 32'd4 : raddr_fifo_rdata[DATA_SIZE-1:0];

  // Transfer FIFO room
  logic room_for_one, room_for_two;
  localparam int CNT_W = $clog2(FIFO_DEPTH) + 1;
  assign room_for_one = (tdata_fifo_count <= CNT_W'(FIFO_DEPTH - 2));
  assign room_for_two = (tdata_fifo_count <= CNT_W'(FIFO_DEPTH - 3));

  always_ff @(posedge clk, negedge n_rst) begin : AHB_FF
    if (!n_rst) begin
      current_state <= RD_IDLE;
      current_addr <= '0;
      current_size <= '0;
      current_tag <= '0;
      beat_count <= '0;
      is_burst <= '0;
      captured_data <= '0;
      dphase_addr <= '0;
      dphase_size <= '0;
      dphase_tag <= '0;
      captured_tag <= '0;
      current_dead <= '0;
      dphase_dead <= '0;
      captured_dead <= '0;
      error_dead <= '0;
      pipe_live <= '0;
      error_addr_reg <= '0;
      error_tag_reg <= '0;
    end else begin
      current_state <= next_state;
      current_addr <= next_addr;
      current_size <= next_size;
      current_tag <= next_tag;
      beat_count <= next_beat_count;
      is_burst <= next_is_burst;
      captured_data <= next_captured_data;
      dphase_addr <= next_dphase_addr;
      dphase_size <= next_dphase_size;
      dphase_tag <= next_dphase_tag;
      captured_tag <= next_captured_tag;
      current_dead <= next_current_dead;
      dphase_dead <= next_dphase_dead;
      captured_dead <= next_captured_dead;
      error_dead <= next_error_dead;
      pipe_live <= next_pipe_live;
      error_addr_reg <= next_error_addr_reg;
      error_tag_reg <= next_error_tag_reg;
    end
  end

  always_comb begin : NEXT_STATE
    next_state = current_state;
    next_addr = current_addr;
    next_size = current_size;
    next_tag = current_tag;
    next_beat_count = beat_count;
    next_is_burst = is_burst;
    next_captured_data = captured_data;
    next_dphase_addr = dphase_addr;
    next_dphase_size = dphase_size;
    next_dphase_tag = dphase_tag;
    next_captured_tag = captured_tag;
    next_pipe_live = pipe_live;
    load_dphase = 1'b0;
    load_captured = 1'b0;
    next_error_addr_reg = error_addr_reg;
    next_error_tag_reg = error_tag_reg;
    next_error_dead = error_dead;

    case (current_state)
      RD_IDLE: begin
        if (raddr_avail && !tdata_fifo_full) begin
          next_addr = raddr_fifo_rdata[DATA_SIZE-1:0];
          next_size = raddr_fifo_rdata[DATA_SIZE+1:DATA_SIZE];
          next_tag = raddr_fifo_rdata[DATA_SIZE+1+TAG_WIDTH:DATA_SIZE+2];
          next_beat_count = 2'd0;
          next_is_burst = burst_mode;
          next_state = RD_FIRST_ADDR;
        end
      end

      RD_FIRST_ADDR: begin
        if (ahb_m.HREADY) begin
          next_dphase_addr = current_addr;
          next_dphase_size = current_size;
          next_dphase_tag  = current_tag;
          load_dphase      = 1'b1;
          if (beat_dead || (!end_of_transaction && raddr_avail && room_for_one)) begin
            next_beat_count = beat_count + 2'd1;
            next_addr = beat_addr;
            next_state = RD_PIPE;
          end else if (end_of_transaction && raddr_avail && room_for_one) begin
            next_addr = raddr_fifo_rdata[DATA_SIZE-1:0];
            next_size = raddr_fifo_rdata[DATA_SIZE+1:DATA_SIZE];
            next_tag = raddr_fifo_rdata[DATA_SIZE+1+TAG_WIDTH:DATA_SIZE+2];
            next_beat_count = 2'd0;
            next_is_burst = burst_mode;
            next_state = RD_PIPE;
          end else begin
            next_state = RD_LAST_DATA;
          end
        end
      end

      RD_PIPE: begin
        if (!ahb_m.HREADY) begin
        end else if (ahb_m.HRESP) begin
          next_error_addr_reg = dphase_addr;
          next_error_tag_reg = dphase_tag;
          next_error_dead = dphase_gone;
          next_pipe_live = 1'b1;
          next_state = RD_ERROR;
        end else if (tdata_fifo_full) begin
          next_captured_data = lane_extract(ahb_m.HRDATA, dphase_size, dphase_addr[1:0]);
          load_captured = 1'b1;
          next_dphase_addr = current_addr;
          next_dphase_size = current_size;
          next_dphase_tag = current_tag;
          load_dphase = 1'b1;
          next_state = RD_FIFO_PUSH;
        end else begin
          next_dphase_addr = current_addr;
          next_dphase_size = current_size;
          next_dphase_tag  = current_tag;
          load_dphase      = 1'b1;
          if (beat_dead || (!end_of_transaction && raddr_avail && room_for_two)) begin
            next_beat_count = beat_count + 2'd1;
            next_addr = beat_addr;
            next_state = RD_PIPE;
          end else if (end_of_transaction && raddr_avail && room_for_two) begin
            next_addr = raddr_fifo_rdata[DATA_SIZE-1:0];
            next_size = raddr_fifo_rdata[DATA_SIZE+1:DATA_SIZE];
            next_tag = raddr_fifo_rdata[DATA_SIZE+1+TAG_WIDTH:DATA_SIZE+2];
            next_beat_count = 2'd0;
            next_is_burst = burst_mode;
            next_state = RD_PIPE;
          end else begin
            next_state = RD_LAST_DATA;
          end
        end
      end

      RD_LAST_DATA: begin
        if (!ahb_m.HREADY) begin
        end else if (ahb_m.HRESP) begin
          next_error_addr_reg = dphase_addr;
          next_error_tag_reg = dphase_tag;
          next_error_dead = dphase_gone;
          next_pipe_live = 1'b0;
          next_state = RD_ERROR;
        end else if (tdata_fifo_full) begin
          next_captured_data = lane_extract(ahb_m.HRDATA, dphase_size, dphase_addr[1:0]);
          load_captured = 1'b1;
          next_state = RD_FIFO_PUSH;
        end else begin
          if (raddr_avail && room_for_one) begin
            next_addr = raddr_fifo_rdata[DATA_SIZE-1:0];
            next_size = raddr_fifo_rdata[DATA_SIZE+1:DATA_SIZE];
            next_tag = raddr_fifo_rdata[DATA_SIZE+1+TAG_WIDTH:DATA_SIZE+2];
            next_beat_count = 2'd0;
            next_is_burst = burst_mode;
            next_state = RD_FIRST_ADDR;
          end else begin
            next_state = RD_IDLE;
          end
        end
      end

      RD_FIFO_PUSH: begin
        if (!tdata_fifo_full) begin
          if (raddr_avail) begin
            next_addr = raddr_fifo_rdata[DATA_SIZE-1:0];
            next_size = raddr_fifo_rdata[DATA_SIZE+1:DATA_SIZE];
            next_tag = raddr_fifo_rdata[DATA_SIZE+1+TAG_WIDTH:DATA_SIZE+2];
            next_beat_count = 2'd0;
            next_is_burst = burst_mode;
            next_state = RD_FIRST_ADDR;
          end else begin
            next_state = RD_IDLE;
          end
        end
      end

      RD_ERROR: begin
        next_beat_count = 2'd0;
        next_is_burst   = 1'b0;
        next_pipe_live  = 1'b0;
        if (pipe_live && !current_gone) next_state = RD_FIRST_ADDR;
        else next_state = RD_IDLE;
      end

      default: next_state = RD_IDLE;
    endcase

    next_current_dead  = raddr_fifo_ren ? kill_mask[raddr_fifo_tag] : current_gone;
    next_dphase_dead   = load_dphase ? current_gone : dphase_gone;
    next_captured_dead = load_captured ? dphase_gone : captured_gone;
    if (load_captured) next_captured_tag = dphase_tag;
  end

  always_comb begin : AHB_OUTPUT
    ahb_m.HSEL = 1'b0;
    ahb_m.HTRANS = IDLE;
    ahb_m.HADDR = '0;
    ahb_m.HBURST = SINGLE;
    ahb_m.HSIZE = WORD;
    ahb_m.HWRITE = 1'b0;
    ahb_m.HWDATA = '0;
    ahb_m.HWSTRB = 4'h0;
    ahb_m.HMASTLOCK = 1'b0;

    case (current_state)
      RD_FIRST_ADDR: begin
        ahb_m.HSEL   = 1'b1;
        ahb_m.HTRANS = NONSEQ;
        ahb_m.HADDR  = size_align(current_addr, current_size);
        ahb_m.HSIZE  = {1'b0, current_size};
        ahb_m.HBURST = is_burst ? INCR4 : SINGLE;
      end

      RD_PIPE: begin
        ahb_m.HSEL   = 1'b1;
        ahb_m.HTRANS = (beat_count == 2'd0) ? NONSEQ : SEQ;
        ahb_m.HADDR  = size_align(current_addr, current_size);
        ahb_m.HSIZE  = {1'b0, current_size};
        ahb_m.HBURST = is_burst ? INCR4 : SINGLE;
      end

      default: ;
    endcase
  end

  always_comb begin : FIFO_OUTPUT
    raddr_fifo_ren = 1'b0;
    tdata_fifo_wen = 1'b0;
    tdata_fifo_wdata = '0;
    tdata_fifo_wtag = dphase_tag;
    transfer_active = 1'b0;
    error_flag = 1'b0;
    read_error_addr = error_addr_reg;
    read_error_tag = error_tag_reg;

    case (current_state)
      RD_IDLE: begin
        if (raddr_avail && !tdata_fifo_full) begin
          raddr_fifo_ren  = 1'b1;  // Pop first address
          transfer_active = 1'b1;
        end
      end

      RD_FIRST_ADDR: begin
        transfer_active = 1'b1;
        if (ahb_m.HREADY) begin
          if (!beat_dead && raddr_avail && room_for_one) begin
            raddr_fifo_ren = 1'b1;
          end
        end
      end

      RD_PIPE: begin
        transfer_active = 1'b1;
        if (ahb_m.HREADY && !ahb_m.HRESP && !tdata_fifo_full) begin
          tdata_fifo_wen   = !dphase_gone;
          tdata_fifo_wdata = lane_extract(ahb_m.HRDATA, dphase_size, dphase_addr[1:0]);

          if (!beat_dead && raddr_avail && room_for_two) begin
            raddr_fifo_ren = 1'b1;
          end
        end
      end

      RD_LAST_DATA: begin
        transfer_active = 1'b1;
        if (ahb_m.HREADY && !ahb_m.HRESP && !tdata_fifo_full) begin
          tdata_fifo_wen   = !dphase_gone;
          tdata_fifo_wdata = lane_extract(ahb_m.HRDATA, dphase_size, dphase_addr[1:0]);
          if (raddr_avail && room_for_one) begin
            raddr_fifo_ren = 1'b1;
          end
        end
      end

      RD_FIFO_PUSH: begin
        transfer_active = 1'b1;
        if (!tdata_fifo_full) begin
          tdata_fifo_wen   = !captured_gone;
          tdata_fifo_wdata = captured_data;
          tdata_fifo_wtag  = captured_tag;
          if (raddr_avail) begin
            raddr_fifo_ren = 1'b1;
          end
        end
      end

      RD_ERROR: begin
        transfer_active = 1'b1;
        error_flag = !error_dead;
      end

      default: ;
    endcase
  end

endmodule
