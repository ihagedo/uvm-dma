// File:        dma_item.svh
// Author:      Isaac Hagedorn
// Date:        2026-10-08
// Description: Transactions: AHB transfers, trigger/reset requests and system-pin observations.

class ahb_item extends uvm_sequence_item;
    `uvm_object_utils(ahb_item)

    typedef enum {CFG, RD, WR} port_e;

    rand bit        write;
    rand bit [31:0] addr;
    rand bit [2:0]  size   = 3'd2;   // HSIZE
    rand bit [3:0]  strobe = 4'hF;   // HWSTRB
    rand bit [31:0] wdata;

    int unsigned idle_before;   // IDLE cycles before the address phase
    bit          cancel_on_error = 1;   // drop this transfer after an ERROR before it
    bit [31:0]   rdata;
    bit          resp;   // 1 = ERROR
    bit          aborted;   // nRST hit the data phase
    port_e       port;
    bit [1:0]    trans = 2'b10;   // HTRANS
    bit [2:0]    burst;   // HBURST
    int unsigned beat;   // 0..3 inside an INCR4
    int unsigned waits;   // wait states in the data phase
    bit          shadow;   // accepted in an ERROR's second cycle
    bit          aphase_only;   // early notice of a shadow
    longint      aedge;   // edge at which the address phase was accepted
    longint      cyc;   // edge at which the data phase completed

    function new(string name = "ahb_item");
        super.new(name);
    endfunction

    function string convert2string();
        string s;
        s = $sformatf("%s %s %h size=%0d", port.name(), write ? "W" : "R", addr, size);
        if (write) s = {s, $sformatf(" strb=%b data=%h", strobe, wdata)};
        else       s = {s, $sformatf(" data=%h", rdata)};
        if (port != CFG) s = {s, $sformatf(" %s%s beat%0d", burst == 3'b011 ? "INCR4" : "SINGLE",
                                           trans == 2'b01 ? "/BUSY" : "", beat)};
        if (waits)  s = {s, $sformatf(" waits=%0d", waits)};
        if (resp)   s = {s, " ERROR"};
        if (shadow) s = {s, " shadow"};
        return {s, $sformatf(" @%0d", cyc)};
    endfunction
endclass

class sys_item extends uvm_sequence_item;
    `uvm_object_utils(sys_item)
    typedef enum {PULSE, RESET} kind_e;
    kind_e           kind;
    bit [NSRC-1:0]   lines;   // PULSE: lines that go high together
    int unsigned     high = 1;   // PULSE: cycles high
    int unsigned     low  = 1;   // PULSE: cycles low afterwards
    int unsigned     rst_edges = 2;   // RESET: rising edges with nRST low
    int unsigned     rst_pct = 40;   // RESET: nRST falls this far into a cycle
    function new(string name = "sys_item");
        super.new(name);
    endfunction
endclass

class sys_obs extends uvm_object;
    `uvm_object_utils(sys_obs)
    typedef enum {EDGE, RESET} kind_e;
    kind_e         kind;
    longint        cyc; 
    bit            nRST;
    bit [NSRC-1:0] trig;   // trigger_in sampled at this edge
    bit [NSRC-1:0] rise;   // lines sampled 1 here and 0 at the previous edge
    bit            irq;
    function new(string name = "sys_obs");
        super.new(name);
    endfunction
endclass
