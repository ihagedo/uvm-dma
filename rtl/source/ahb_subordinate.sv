// File:        ahb_subordinate.sv
// Author:      DMA-zing contributors
// Date:        2026-10-08
// Description: AHB subordinate front end of the register port.

module ahb_subordinate #(
    parameter int ADDR_WIDTH = 32,
    parameter int DATA_WIDTH = 32,
    parameter logic [ADDR_WIDTH-1:0] BASE_ADDR = 'h8000_0000,
    parameter int NWORDS = 4  // Number of words of address space to cover
) (
    ahb_if.subordinate ahb_if,
    bus_protocol_if.protocol bus_if
);

  localparam int WORD_LENGTH = ADDR_WIDTH / 8;
  localparam logic [ADDR_WIDTH-1:0] TOP_ADDR = BASE_ADDR + NWORDS * WORD_LENGTH;

  typedef enum logic [1:0] {
    IDLE,
    ACCESS,
    ERROR
  } ahb_state_t;

  ahb_state_t state, next_state;

  logic [ADDR_WIDTH-1:0] addr_d;  // Address, delayed to the data phase
  logic sel_d;
  logic [2:0] burst_d;
  logic write_d;
  logic [1:0] trans_d;
  logic [2:0] size_d;
  logic hreadyout_d;  // HREADYOUT, one cycle late


  // Address Decoding Logic
  logic [ADDR_WIDTH-1:0] decoded_addr;
  logic range_error;
  logic align_error;
  assign decoded_addr = addr_d - BASE_ADDR;
  assign range_error  = (addr_d < BASE_ADDR || addr_d >= TOP_ADDR);
  assign align_error  = ((addr_d & WORD_LENGTH - 1) != 'b0);

  logic addr_error;
  assign addr_error = sel_d && (range_error || align_error);

  always_ff @(posedge ahb_if.HCLK or negedge ahb_if.HRESETn) begin
    if (!ahb_if.HRESETn) begin
      state <= IDLE;
    end else begin
      state <= next_state;
    end
  end

  // Next state logic
  always_comb begin : NEXT_STATE
    case (state)
      IDLE: begin
        if (ahb_if.HSEL && (ahb_if.HTRANS != 2'b00)) begin
          next_state = ACCESS;
        end else begin
          next_state = IDLE;
        end
      end
      ACCESS: begin
        if ((addr_error && hreadyout_d != 0) || bus_if.error) begin
          next_state = ERROR;
        end else if (bus_if.request_stall == 1 || ahb_if.HSEL == 1 && ahb_if.HTRANS != 2'b00) begin
          next_state = ACCESS;
        end else begin
          next_state = IDLE;
        end
      end
      ERROR: begin
        if (ahb_if.HSEL && (ahb_if.HTRANS != 2'b00)) begin
          next_state = ACCESS;
        end else begin
          next_state = IDLE;
        end
      end
      default: next_state = IDLE;
    endcase
  end



  // Output logic to the bus interface
  always_comb begin
    case (state)
      IDLE: begin
        bus_if.addr = 'd0;
        bus_if.wdata = 'd0;
        bus_if.strobe = 'd0;
        bus_if.wen = 1'b0;
        bus_if.ren = 1'b0;
        bus_if.is_burst = 1'b0;
        bus_if.burst_type = 'd0;
        bus_if.burst_length = 'd0;
      end
      ACCESS: begin
        if (trans_d != 2'b01 && addr_error != 1'b1) begin
          bus_if.addr = addr_d - BASE_ADDR;
          bus_if.strobe = ahb_if.HWSTRB;
          bus_if.wen = write_d;
          bus_if.ren = !write_d;
          bus_if.wdata = ahb_if.HWDATA;
        end else begin
          bus_if.addr = 'd0;
          bus_if.strobe = 'd0;
          bus_if.wen = 1'b0;
          bus_if.ren = 1'b0;
          bus_if.wdata = 'd0;
        end

        if (burst_d != 'd0 && addr_error != 1'b1) begin
          bus_if.is_burst = 1'b1;
          if (burst_d == 3'b010 || burst_d == 3'b011) begin
            bus_if.burst_length = size_d << 2;
          end else if (burst_d == 3'b100 || burst_d == 3'b101) begin
            bus_if.burst_length = size_d << 3;
          end else if (burst_d == 3'b110 || burst_d == 3'b111) begin
            bus_if.burst_length = size_d << 4;
          end else if (burst_d == 3'b001) begin
            bus_if.burst_length = 'd0;
          end else begin
            bus_if.burst_length = 'd0;
          end
          if (burst_d == 3'b001 || burst_d == 3'b011 ||
                        burst_d == 3'b101 || burst_d == 3'b111) begin
            bus_if.burst_type = 2'b10;
          end else begin
            bus_if.burst_type = 2'b11;
          end
        end else begin
          bus_if.is_burst = 1'b0;
          bus_if.burst_type = 'd0;
          bus_if.burst_length = 'd0;
        end
      end
      ERROR: begin
        bus_if.addr = 'd0;
        bus_if.wdata = 'd0;
        bus_if.strobe = 'd0;
        bus_if.wen = 1'b0;
        bus_if.ren = 1'b0;
        bus_if.is_burst = 1'b0;
        bus_if.burst_type = 'd0;
        bus_if.burst_length = 'd0;
      end
      default: begin
        bus_if.addr = 'd0;
        bus_if.wdata = 'd0;
        bus_if.strobe = 'd0;
        bus_if.wen = 1'b0;
        bus_if.ren = 1'b0;
        bus_if.is_burst = 1'b0;
        bus_if.burst_type = 'd0;
        bus_if.burst_length = 'd0;
      end
    endcase
  end

  // Output signals to the ahb interface
  always_comb begin
    case (state)
      IDLE: begin
        ahb_if.HREADYOUT = 1'b1;
        ahb_if.HRESP = 1'b0;
        ahb_if.HRDATA = 'd0;
      end
      ACCESS: begin
        ahb_if.HRDATA = bus_if.rdata;
        if ((addr_error && hreadyout_d == 1) || (bus_if.error && trans_d != 2'b01)) begin
          ahb_if.HREADYOUT = 1'b0;
          ahb_if.HRESP = 1'b1;
        end else if (trans_d == 2'b01) begin
          ahb_if.HREADYOUT = 1'b1;
          ahb_if.HRESP = 1'b0;
        end else if (bus_if.request_stall == 1) begin
          ahb_if.HREADYOUT = 1'b0;
          ahb_if.HRESP = 1'b0;
        end else begin
          ahb_if.HREADYOUT = 1'b1;
          ahb_if.HRESP = 1'b0;
        end
      end
      ERROR: begin
        ahb_if.HRDATA = bus_if.rdata;
        ahb_if.HRESP = 1'b1;
        ahb_if.HREADYOUT = 1'b1;
      end
      default: begin
        ahb_if.HREADYOUT = 1'b1;
        ahb_if.HRESP = 1'b0;
        ahb_if.HRDATA = 'd0;
      end
    endcase
  end

  always_ff @(posedge ahb_if.HCLK or negedge ahb_if.HRESETn) begin
    if (!ahb_if.HRESETn) begin
      hreadyout_d <= 1'd0;
    end else begin
      hreadyout_d <= ahb_if.HREADYOUT;
    end
  end

  always_ff @(posedge ahb_if.HCLK or negedge ahb_if.HRESETn) begin
    if (!ahb_if.HRESETn) begin
      addr_d  <= 'd0;
      write_d <= 'd0;
      trans_d <= 'd0;
      burst_d <= 'd0;
      size_d  <= 'd0;
      sel_d   <= 'b0;
    end else begin
      if (!bus_if.request_stall) begin
        addr_d  <= ahb_if.HADDR;
        write_d <= ahb_if.HWRITE;
        trans_d <= ahb_if.HTRANS;
        burst_d <= ahb_if.HBURST;
        size_d  <= ahb_if.HSIZE;
        sel_d   <= ahb_if.HSEL;
      end
    end
  end


endmodule
