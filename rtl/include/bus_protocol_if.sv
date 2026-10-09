// File:        bus_protocol_if.sv
// Author:      DMA-zing contributors
// Date:        2026-10-08
// Description: Register bus between the AHB subordinate and the register file.

interface bus_protocol_if #(
    parameter int ADDR_WIDTH = 32,
    parameter int DATA_WIDTH = 32
) (
);

  // Vital signals
  logic wen;  // data write request
  logic ren;  // data read request
  logic request_stall;  // insert wait states
  logic [ADDR_WIDTH-1 : 0] addr;  // offset address of the request
  logic error;  // error response
  logic [(DATA_WIDTH/8)-1 : 0] strobe;  // byte enable for writes
  logic [DATA_WIDTH-1 : 0]
      wdata,
      rdata;

  // Hint signals
  logic is_burst;
  logic [1:0] burst_type;  // WRAP, INCR
  logic [7:0] burst_length;  // beats
  logic secure_transfer;


  modport peripheral_vital(input wen, ren, addr, wdata, strobe, output rdata, error, request_stall);

  modport peripheral_hint(input is_burst, burst_type, burst_length, secure_transfer);

  modport protocol(
      input rdata, error, request_stall,
      output wen, ren, addr, wdata, strobe,  // vital signals
      is_burst, burst_type, burst_length, secure_transfer
  );

endinterface
