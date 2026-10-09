// File:        ahb_write_manager.sv
// Author:      DMA-zing contributors
// Date:        2026-10-08
// Description: AHB manager that writes queued items to their destinations, with INCR4 bursts. With the spec 1.2 fixes.

`timescale 1ns / 10ps

module ahb_write_manager #(
    parameter int DATA_SIZE  = 32,
    parameter int FIFO_DEPTH = 16,
    parameter int TAG_WIDTH  = 3
) (
    input logic clk,
    input logic n_rst,
    ahb_if.manager ahb_m,

    input logic [DATA_SIZE+1+TAG_WIDTH:0] waddr_fifo_rdata,
    input logic waddr_fifo_empty,
    input logic [$clog2(FIFO_DEPTH):0] waddr_fifo_count,  // For burst check
    output logic waddr_fifo_ren,
    input logic [DATA_SIZE+1+TAG_WIDTH:0] waddr_fifo_peek1,
    input logic [DATA_SIZE+1+TAG_WIDTH:0] waddr_fifo_peek2,
    input logic [DATA_SIZE+1+TAG_WIDTH:0] waddr_fifo_peek3,

    // Transfer Data FIFO
    input logic tdata_fifo_empty,
    input logic [$clog2(FIFO_DEPTH):0] tdata_fifo_count,
    input logic [DATA_SIZE-1:0] tdata_fifo_rdata,
    output logic tdata_fifo_ren,

    // Killed channels
    input logic [(1<<TAG_WIDTH)-1:0] kill_mask,

    // Status
    output logic error_flag,  // One-cycle pulse on AHB error
    output logic [DATA_SIZE-1:0] write_error_addr,  // Latched address that caused error
    output logic [TAG_WIDTH-1:0] write_error_tag,  // Channel that owned the faulting address
    output logic transfer_active,
    output logic transfer_completed,
    output logic [TAG_WIDTH-1:0] completed_tag  // Channel of the write retiring this cycle
);
  // AHB constants
  localparam logic [1:0] IDLE = 2'b00;
  localparam logic [1:0] BUSY = 2'b01;
  localparam logic [1:0] NONSEQ = 2'b10;
  localparam logic [1:0] SEQ = 2'b11;
  localparam logic [2:0] SINGLE = 3'b000;
  localparam logic [2:0] INCR4 = 3'b011;
  localparam logic [2:0] WORD = 3'b010;

  typedef enum logic [2:0] {
    WR_IDLE,  // No activity
    WR_FIRST_ADDR,  // First address phase of a new transaction
    WR_PIPE,  // Presenting address N+1 while collecting data for address N
    WR_LAST_DATA,  // Collecting data for the last accepted address
    WR_FIFO_PULL,  // transfer data FIFO is empty
    WR_ERROR  // One cycle error
  } state_t;

  state_t current_state, next_state;

  logic [DATA_SIZE-1:0] current_addr, next_addr;
  logic [1:0] current_size, next_size;
  logic [TAG_WIDTH-1:0] current_tag, next_tag;
  logic [1:0] beat_count, next_beat_count;
  logic is_burst, next_is_burst;
  logic [DATA_SIZE-1:0] dphase_addr, next_dphase_addr;  // Addr whose data phase is active
  logic [1:0] dphase_size, next_dphase_size;  // Size for HWSTRB computation
  logic [TAG_WIDTH-1:0] dphase_tag, next_dphase_tag;  // Channel owning the active data phase
  logic [DATA_SIZE-1:0] error_addr_reg, next_error_addr_reg;
  logic [TAG_WIDTH-1:0] error_tag_reg, next_error_tag_reg;
  logic current_dead, next_current_dead;
  logic dphase_dead, next_dphase_dead;
  logic dphase_null, next_dphase_null;  // Item was dead when its data phase began
  logic error_dead, next_error_dead;  // ERROR hit an item that was already dropped
  logic err_pulsed;  // error_flag already raised for this ERROR
  logic hold_valid;  // Data phase is waited, outputs held
  logic [DATA_SIZE-1:0] hold_wdata;
  logic [3:0] hold_wstrb;
  logic pipe_live, next_pipe_live;
  logic load_dphase;

  logic [$clog2(FIFO_DEPTH)+1:0] committed, next_committed;
  logic accepting;
  logic [$clog2(FIFO_DEPTH)+1:0] commit_after;
  logic [$clog2(FIFO_DEPTH)+1:0] tdata_avail;
  logic can_accept, burst_data_ok;

  logic [TAG_WIDTH-1:0] waddr_fifo_tag;
  assign waddr_fifo_tag = waddr_fifo_rdata[DATA_SIZE+1+TAG_WIDTH:DATA_SIZE+2];

  // Queue head is not being dropped this cycle
  logic waddr_avail;
  assign waddr_avail = !waddr_fifo_empty && !kill_mask[waddr_fifo_tag];

  assign accepting = ahb_m.HREADY &&
      ((current_state == WR_FIRST_ADDR) || (current_state == WR_PIPE));
  assign tdata_avail = {1'b0, tdata_fifo_count};
  assign commit_after = committed + {{($clog2(FIFO_DEPTH) + 1) {1'b0}}, accepting};
  assign can_accept = tdata_avail > commit_after;
  assign burst_data_ok = tdata_avail >= (commit_after + {{($clog2(FIFO_DEPTH) - 1) {1'b0}}, 3'd4});

  logic dphase_gone, current_gone;
  assign dphase_gone  = dphase_dead || kill_mask[dphase_tag];
  assign current_gone = current_dead || kill_mask[current_tag];

  // Item address aligned to its size
  function automatic logic [DATA_SIZE-1:0] size_align(input logic [DATA_SIZE-1:0] a,
                                                      input logic [1:0] size);
    case (size)
      2'b00:   return a;
      2'b01:   return {a[DATA_SIZE-1:1], 1'b0};
      default: return {a[DATA_SIZE-1:2], 2'b00};
    endcase
  endfunction

  function automatic logic [DATA_SIZE-1:0] lane_place(
      input logic [DATA_SIZE-1:0] word, input logic [1:0] size, input logic [1:0] lane);
    case (size)
      2'b00:   return word << (8 * lane);
      2'b01:   return word << (16 * lane[1]);
      default: return word;
    endcase
  endfunction

  // Burst eligibility check
  logic [DATA_SIZE-1:0] head_addr;
  assign head_addr = waddr_fifo_rdata[DATA_SIZE-1:0];
  logic consecutive_words;
  assign consecutive_words = (waddr_fifo_peek1[DATA_SIZE-1:0] == head_addr + 32'd4) &&
      (waddr_fifo_peek2[DATA_SIZE-1:0] == head_addr + 32'd8) &&
      (waddr_fifo_peek3[DATA_SIZE-1:0] == head_addr + 32'd12) &&
      (waddr_fifo_peek1[DATA_SIZE+1+TAG_WIDTH:DATA_SIZE] ==
       waddr_fifo_rdata[DATA_SIZE+1+TAG_WIDTH:DATA_SIZE]) &&
      (waddr_fifo_peek2[DATA_SIZE+1+TAG_WIDTH:DATA_SIZE] ==
       waddr_fifo_rdata[DATA_SIZE+1+TAG_WIDTH:DATA_SIZE]) &&
      (waddr_fifo_peek3[DATA_SIZE+1+TAG_WIDTH:DATA_SIZE] ==
       waddr_fifo_rdata[DATA_SIZE+1+TAG_WIDTH:DATA_SIZE]);
  logic burst_mode;
  assign burst_mode = (waddr_fifo_count >= 4) &&
                      burst_data_ok && (head_addr[9:2] <= 8'hFC) &&
                      (waddr_fifo_rdata[DATA_SIZE+1:DATA_SIZE] == 2'b10) && consecutive_words;

  // End-of-transaction flag
  logic end_of_transaction;
  assign end_of_transaction = !is_burst || (beat_count == 2'd3);

  logic beat_dead, beat_live;
  assign beat_dead = !end_of_transaction && current_gone;
  assign beat_live = !end_of_transaction && !current_gone && waddr_avail && can_accept;

  // Next beat's address: the queue head, or the next word of a dropped burst
  logic [DATA_SIZE-1:0] beat_addr;
  assign beat_addr = current_gone ? current_addr + 32'd4 : waddr_fifo_rdata[DATA_SIZE-1:0];

  // Pipeline check
  logic can_pipe_first;
  assign can_pipe_first = waddr_avail && can_accept;

  logic can_pipe_cont;
  assign can_pipe_cont = waddr_avail && can_accept;

  always_ff @(posedge clk, negedge n_rst) begin : AHB_FF
    if (!n_rst) begin
      current_state <= WR_IDLE;
      committed <= '0;
      current_addr <= '0;
      current_size <= '0;
      current_tag <= '0;
      beat_count <= '0;
      is_burst <= '0;
      dphase_addr <= '0;
      dphase_size <= '0;
      dphase_tag <= '0;
      current_dead <= '0;
      dphase_dead <= '0;
      dphase_null <= '0;
      error_dead <= '0;
      err_pulsed <= '0;
      hold_valid <= '0;
      hold_wdata <= '0;
      hold_wstrb <= '0;
      pipe_live <= '0;
      error_addr_reg <= '0;
      error_tag_reg <= '0;
    end else begin
      current_state <= next_state;
      committed <= next_committed;
      current_addr <= next_addr;
      current_size <= next_size;
      current_tag <= next_tag;
      beat_count <= next_beat_count;
      is_burst <= next_is_burst;
      dphase_addr <= next_dphase_addr;
      dphase_size <= next_dphase_size;
      dphase_tag <= next_dphase_tag;
      current_dead <= next_current_dead;
      dphase_dead <= next_dphase_dead;
      dphase_null <= next_dphase_null;
      error_dead <= next_error_dead;
      err_pulsed <= (current_state == WR_ERROR);
      if (ahb_m.HREADY) hold_valid <= 1'b0;
      else if (!hold_valid && (current_state == WR_PIPE || current_state == WR_LAST_DATA)) begin
        hold_valid <= 1'b1;
        hold_wdata <= ahb_m.HWDATA;
        hold_wstrb <= ahb_m.HWSTRB;
      end
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
    next_dphase_addr = dphase_addr;
    next_dphase_size = dphase_size;
    next_dphase_tag = dphase_tag;
    next_pipe_live = pipe_live;
    load_dphase = 1'b0;
    next_error_addr_reg = error_addr_reg;
    next_error_tag_reg = error_tag_reg;
    next_error_dead = error_dead;

    case (current_state)
      WR_IDLE: begin
        if (waddr_avail && !tdata_fifo_empty) begin
          next_addr = waddr_fifo_rdata[DATA_SIZE-1:0];
          next_size = waddr_fifo_rdata[DATA_SIZE+1:DATA_SIZE];
          next_tag = waddr_fifo_rdata[DATA_SIZE+1+TAG_WIDTH:DATA_SIZE+2];
          next_beat_count = 2'd0;
          next_is_burst = burst_mode;
          next_state = WR_FIRST_ADDR;
        end
      end

      WR_FIRST_ADDR: begin
        if (ahb_m.HREADY) begin
          next_dphase_addr = current_addr;
          next_dphase_size = current_size;
          next_dphase_tag  = current_tag;
          load_dphase      = 1'b1;
          if (beat_dead || beat_live) begin
            next_beat_count = beat_count + 2'd1;
            next_addr = beat_addr;
            next_state = WR_PIPE;
          end else if (end_of_transaction && can_pipe_first) begin
            next_addr = waddr_fifo_rdata[DATA_SIZE-1:0];
            next_size = waddr_fifo_rdata[DATA_SIZE+1:DATA_SIZE];
            next_tag = waddr_fifo_rdata[DATA_SIZE+1+TAG_WIDTH:DATA_SIZE+2];
            next_beat_count = 2'd0;
            next_is_burst = burst_mode;
            next_state = WR_PIPE;
          end else begin
            next_state = WR_LAST_DATA;
          end
        end
      end

      WR_PIPE: begin
        if (!ahb_m.HREADY) begin
        end else if (ahb_m.HRESP) begin
          next_error_addr_reg = dphase_addr;
          next_error_tag_reg = dphase_tag;
          next_error_dead = dphase_gone;
          next_pipe_live = 1'b1;
          next_state = WR_ERROR;
        end else begin
          next_dphase_addr = current_addr;
          next_dphase_size = current_size;
          next_dphase_tag  = current_tag;
          load_dphase      = 1'b1;
          if (beat_dead || beat_live) begin
            next_beat_count = beat_count + 2'd1;
            next_addr = beat_addr;
            next_state = WR_PIPE;
          end else if (end_of_transaction && can_pipe_cont) begin
            next_addr = waddr_fifo_rdata[DATA_SIZE-1:0];
            next_size = waddr_fifo_rdata[DATA_SIZE+1:DATA_SIZE];
            next_tag = waddr_fifo_rdata[DATA_SIZE+1+TAG_WIDTH:DATA_SIZE+2];
            next_beat_count = 2'd0;
            next_is_burst = burst_mode;
            next_state = WR_PIPE;
          end else begin
            next_state = WR_LAST_DATA;
          end
        end
      end

      WR_LAST_DATA: begin
        if (!ahb_m.HREADY) begin
        end else if (ahb_m.HRESP) begin
          next_error_addr_reg = dphase_addr;
          next_error_tag_reg = dphase_tag;
          next_error_dead = dphase_gone;
          next_pipe_live = 1'b0;
          next_state = WR_ERROR;
        end else if (tdata_fifo_empty && !dphase_gone) begin
          next_state = WR_FIFO_PULL;
        end else begin
          if (waddr_avail && can_accept) begin
            next_addr = waddr_fifo_rdata[DATA_SIZE-1:0];
            next_size = waddr_fifo_rdata[DATA_SIZE+1:DATA_SIZE];
            next_tag = waddr_fifo_rdata[DATA_SIZE+1+TAG_WIDTH:DATA_SIZE+2];
            next_beat_count = 2'd0;
            next_is_burst = burst_mode;
            next_state = WR_FIRST_ADDR;
          end else begin
            next_state = WR_IDLE;
          end
        end
      end

      WR_FIFO_PULL: begin
        if (!tdata_fifo_empty) begin
          next_state = WR_IDLE;
        end
      end

      WR_ERROR: begin
        next_beat_count = 2'd0;
        next_is_burst   = 1'b0;
        if (ahb_m.HREADY) begin
          next_pipe_live = 1'b0;
          if (pipe_live && !current_gone) next_state = WR_FIRST_ADDR;
          else next_state = WR_IDLE;
        end
      end

      default: next_state = WR_IDLE;
    endcase

    // Live items in a data phase whose data is still queued
    next_committed = committed;
    if (load_dphase && !current_gone) next_committed = next_committed + 1'b1;
    if (tdata_fifo_ren || (committed != '0 && kill_mask[dphase_tag] && !dphase_dead))
      next_committed = next_committed - 1'b1;

    next_current_dead = waddr_fifo_ren ? kill_mask[waddr_fifo_tag] : current_gone;
    next_dphase_dead  = load_dphase ? current_gone : dphase_gone;
    next_dphase_null  = load_dphase ? current_gone : dphase_null;
  end

  always_comb begin : AHB_OUTPUT
    ahb_m.HSEL = 1'b0;
    ahb_m.HTRANS = IDLE;
    ahb_m.HADDR = '0;
    ahb_m.HBURST = SINGLE;
    ahb_m.HSIZE = WORD;
    ahb_m.HWRITE = 1'b1;
    ahb_m.HWDATA = '0;
    ahb_m.HWSTRB = 4'h0;
    ahb_m.HMASTLOCK = 1'b0;

    case (current_state)
      WR_FIRST_ADDR: begin
        ahb_m.HSEL   = 1'b1;
        ahb_m.HTRANS = NONSEQ;
        ahb_m.HADDR  = size_align(current_addr, current_size);
        ahb_m.HSIZE  = {1'b0, current_size};
        ahb_m.HBURST = is_burst ? INCR4 : SINGLE;
      end

      WR_PIPE: begin
        ahb_m.HSEL   = 1'b1;
        ahb_m.HTRANS = (beat_count == 2'd0) ? NONSEQ : SEQ;
        ahb_m.HADDR  = size_align(current_addr, current_size);
        ahb_m.HSIZE  = {1'b0, current_size};
        ahb_m.HBURST = is_burst ? INCR4 : SINGLE;

        ahb_m.HWDATA = lane_place(tdata_fifo_rdata, dphase_size, dphase_addr[1:0]);
        case (dphase_size)
          2'b00:   ahb_m.HWSTRB = 4'b0001 << dphase_addr[1:0];
          2'b01:   ahb_m.HWSTRB = dphase_addr[1] ? 4'b1100 : 4'b0011;
          2'b10:   ahb_m.HWSTRB = 4'b1111;
          default: ahb_m.HWSTRB = 4'b1111;
        endcase
      end

      WR_LAST_DATA: begin
        if (!tdata_fifo_empty) begin
          ahb_m.HWDATA = lane_place(tdata_fifo_rdata, dphase_size, dphase_addr[1:0]);
          case (dphase_size)
            2'b00:   ahb_m.HWSTRB = 4'b0001 << dphase_addr[1:0];
            2'b01:   ahb_m.HWSTRB = dphase_addr[1] ? 4'b1100 : 4'b0011;
            2'b10:   ahb_m.HWSTRB = 4'b1111;
            default: ahb_m.HWSTRB = 4'b1111;
          endcase
        end
      end

      WR_FIFO_PULL: begin
        if (is_burst && beat_count < 2'd3) begin
          ahb_m.HSEL   = 1'b1;
          ahb_m.HTRANS = BUSY;
          ahb_m.HBURST = INCR4;
          ahb_m.HSIZE  = {1'b0, current_size};
          ahb_m.HADDR  = {current_addr[DATA_SIZE-1:2], 2'b00};
        end
        if (!tdata_fifo_empty) begin
          ahb_m.HWDATA = lane_place(tdata_fifo_rdata, dphase_size, dphase_addr[1:0]);
        end
      end

      default: ;
    endcase

    if (dphase_null) ahb_m.HWSTRB = 4'h0;
    if (hold_valid) begin
      ahb_m.HWDATA = hold_wdata;
      ahb_m.HWSTRB = hold_wstrb;
    end
  end

`ifndef SYNTHESIS
  a_dphase_has_data :
  assert property (@(posedge clk) disable iff (!n_rst)
      ((current_state == WR_LAST_DATA) && ahb_m.HREADY && !ahb_m.HRESP && !dphase_gone)
      |-> !tdata_fifo_empty);
`endif

  always_comb begin : FIFO_OUTPUT
    waddr_fifo_ren = 1'b0;
    tdata_fifo_ren = 1'b0;
    transfer_completed = 1'b0;
    completed_tag = dphase_tag;
    transfer_active = 1'b0;
    error_flag = 1'b0;
    write_error_addr = error_addr_reg;
    write_error_tag = error_tag_reg;

    case (current_state)
      WR_IDLE: begin
        if (waddr_avail && !tdata_fifo_empty) begin
          waddr_fifo_ren  = 1'b1;
          transfer_active = 1'b1;
        end
      end

      WR_FIRST_ADDR: begin
        transfer_active = 1'b1;
        if (ahb_m.HREADY) begin
          if (beat_live) begin
            waddr_fifo_ren = 1'b1;
          end else if (end_of_transaction && can_pipe_first) begin
            waddr_fifo_ren = 1'b1;
          end
        end
      end

      WR_PIPE: begin
        transfer_active = 1'b1;
        if (ahb_m.HREADY && !ahb_m.HRESP) begin
          tdata_fifo_ren = !dphase_gone;
          transfer_completed = !dphase_gone;
          if (beat_live) begin
            waddr_fifo_ren = 1'b1;
          end else if (end_of_transaction && can_pipe_cont) begin
            waddr_fifo_ren = 1'b1;
          end
        end
      end

      WR_LAST_DATA: begin
        transfer_active = 1'b1;
        if (ahb_m.HREADY && !ahb_m.HRESP && !tdata_fifo_empty) begin
          tdata_fifo_ren = !dphase_gone;
          transfer_completed = !dphase_gone;
          if (waddr_avail && can_accept) begin
            waddr_fifo_ren = 1'b1;
          end
        end
      end

      WR_FIFO_PULL: begin
        transfer_active = 1'b1;
      end

      WR_ERROR: begin
        transfer_active = 1'b1;
        error_flag = !err_pulsed && !error_dead;
      end

      default: ;
    endcase
  end

endmodule
