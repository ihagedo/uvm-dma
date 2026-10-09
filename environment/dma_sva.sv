// File:        dma_sva.sv
// Author:      Isaac Hagedorn
// Date:        2026-10-08
// Description: Protocol and interrupt assertions for the DMA ports.

`include "uvm_macros.svh"

module dma_mgr_sva
    import uvm_pkg::*;
#(
    parameter string PORT = "RD"
)(
    input logic        CLK, nRST,
    input logic        HSEL, HWRITE, HREADY, HRESP,
    input logic [1:0]  HTRANS,
    input logic [2:0]  HBURST, HSIZE,
    input logic [31:0] HADDR, HWDATA,
    input logic [3:0]  HWSTRB
);
    localparam logic [1:0] IDLE = 2'b00, BUSY = 2'b01, NONSEQ = 2'b10, SEQ = 2'b11;
    localparam logic [2:0] INCR4 = 3'b011;

    function automatic void fail(string id, string msg);
        `uvm_error(id, msg)
    endfunction

    logic        p_ok;
    logic [31:0] p_addr;
    logic [2:0]  p_size, p_burst;
    int          p_beat;
    logic        w_valid, w_errcyc;
    logic [1:0]  w_trans;
    logic [2:0]  w_burst, w_size;
    logic [31:0] w_addr;
    logic        w_write;
    int          burst_left;
    logic        burst_err;
    logic        d_valid, d_write, d_waited;
    logic [31:0] d_addr, d_wdata;
    logic [2:0]  d_size;
    logic [3:0]  d_strb;

    function automatic logic [3:0] ahb_lanes(logic [31:0] a, logic [2:0] sz);
        case (sz)
            3'd0:    return 4'b0001 << a[1:0];
            3'd1:    return a[1] ? 4'b1100 : 4'b0011;
            default: return 4'b1111;
        endcase
    endfunction

    always @(posedge CLK or negedge nRST) begin
        if (!nRST) begin
            p_ok <= 0; w_valid <= 0; d_valid <= 0; burst_left <= 0; burst_err <= 0;
        end else begin
            automatic bit acc = HSEL && HTRANS != IDLE && HREADY;

            if (w_valid && !(w_errcyc && HTRANS == IDLE))
                if (HTRANS != w_trans || HADDR != w_addr || HBURST != w_burst || HSIZE != w_size || HWRITE != w_write)
                    fail("SVA02", $sformatf("%s port: address phase changed while waited: %h/%0d -> %h/%0d",
                                                PORT, w_addr, w_trans, HADDR, HTRANS));
            if (d_valid && d_write && d_waited && (HWDATA != d_wdata || HWSTRB != d_strb))
                fail("SVA11", $sformatf("%s port: HWDATA/HWSTRB changed while the data phase was waited (%h/%b -> %h/%b)  [P8]",
                                                         PORT, d_wdata, d_strb, HWDATA, HWSTRB));
            if (HSEL && HTRANS inside {NONSEQ, SEQ} && HSIZE > 3'd2)
                fail("SVA03", $sformatf("%s port: HSIZE=%0d on a 32-bit bus at %h  [P6]", PORT, HSIZE, HADDR));

            if (acc && HTRANS == SEQ) begin
                if (!p_ok || p_burst != INCR4 || HBURST != INCR4 || HADDR != p_addr + (32'd1 << HSIZE) ||
                    HSIZE != p_size || p_beat >= 3)
                    fail("SVA01", $sformatf("%s port: SEQ to %h does not continue an INCR4 (previous %h burst %0d beat %0d)",
                                                PORT, HADDR, p_addr, p_burst, p_beat));
            end
            if (acc && HTRANS == BUSY) begin
                if (!p_ok || p_burst != INCR4 || HBURST != INCR4 || p_beat >= 3)
                    fail("SVA06", $sformatf("%s port: BUSY outside an INCR4 burst", PORT));
            end
            if (acc && HTRANS == NONSEQ && HBURST == INCR4) begin
                if ({22'd0, HADDR[9:0]} + 3 * (32'd1 << HSIZE) > 32'h3FF)
                    fail("SVA04", $sformatf("%s port: INCR4 at %h crosses a 1 KB boundary  [P7]", PORT, HADDR));
            end
            if (HREADY && burst_left > 0 && !burst_err && !(HSEL && HTRANS inside {SEQ, BUSY}))
                fail("SVA12", $sformatf("%s port: INCR4 ended after %0d of 4 beats (HTRANS=%0d at %h) with no ERROR on this port  [P7]",
                                                       PORT, 4 - burst_left, HTRANS, HADDR));
            if (HRESP) burst_err <= 1;
            if (acc && HTRANS == NONSEQ) begin
                burst_left <= (HBURST == INCR4) ? 3 : 0;
                burst_err  <= HRESP;
            end else if (acc && HTRANS == SEQ && burst_left > 0) burst_left <= burst_left - 1;
            else if (HREADY && burst_left > 0 && !(HSEL && HTRANS inside {SEQ, BUSY})) burst_left <= 0;

            if (acc && HTRANS != BUSY) begin
                p_ok    <= 1;
                p_addr  <= HADDR;
                p_size  <= HSIZE;
                p_burst <= HBURST;
                p_beat  <= (HTRANS == NONSEQ) ? 0 : p_beat + 1;
            end

            if (d_valid && d_write && HREADY && !HRESP && HWSTRB != 0 && (HWSTRB & ~ahb_lanes(d_addr, d_size)) != 0)
                fail("SVA05", $sformatf("%s port: HWSTRB=%b outside the lanes of HADDR=%h HSIZE=%0d  [P6]",
                                            PORT, HWSTRB, d_addr, d_size));

            w_valid  <= HSEL && HTRANS != IDLE && !HREADY;
            w_errcyc <= HRESP && !HREADY;
            w_trans  <= HTRANS; w_addr <= HADDR; w_burst <= HBURST; w_size <= HSIZE; w_write <= HWRITE;
            if (d_valid && HREADY) d_valid <= 0;
            if (acc && HTRANS != BUSY) begin
                d_valid <= 1; d_write <= HWRITE; d_addr <= HADDR; d_size <= HSIZE; d_waited <= 0;
            end else if (d_valid && !HREADY) begin
                d_waited <= 1; d_wdata <= HWDATA; d_strb <= HWSTRB;
            end
        end
    end
endmodule

module dma_sub_sva
    import uvm_pkg::*;
#(
    parameter int NCH = 8
)(
    input logic        CLK, nRST,
    input logic        HSEL, HWRITE, HREADY, HRESP,
    input logic [1:0]  HTRANS,
    input logic [31:0] HADDR,
    input logic [3:0]  HWSTRB
);
    logic        d_first, d_write, d_mapped;
    logic [31:0] d_addr;
    logic        prev_err1;

    function automatic logic mapped(logic [31:0] a);
        logic [31:0] off = a - 32'h9000_1000;
        return a >= 32'h9000_1000 && off < 32'h1000 && a[1:0] == 0 && off < 40 * NCH;
    endfunction

    always @(posedge CLK or negedge nRST) begin
        if (!nRST) begin
            d_first <= 0; prev_err1 <= 0;
        end else begin
            if (d_first) begin
                automatic bit ok = d_mapped && !(d_write && HWSTRB != 4'hF);
                if (ok && !(HREADY && !HRESP))
                    `uvm_error("SVA07", $sformatf("register access to mapped %h got HREADY=%b HRESP=%b in its first data cycle  [P3]", d_addr, HREADY, HRESP))
                if (!ok && !(!HREADY && HRESP))
                    `uvm_error("SVA07", $sformatf("register access to %h (unmapped, unaligned or partial write) got HREADY=%b HRESP=%b in its first data cycle  [P4]", d_addr, HREADY, HRESP))
            end
            if (prev_err1 && !(HREADY && HRESP))
                `uvm_error("SVA08", "first ERROR cycle not followed by HREADY=1 HRESP=1")
            if (HREADY && HRESP && !prev_err1)
                `uvm_error("SVA08", "HREADY=1 HRESP=1 without a first ERROR cycle before it")
            prev_err1 <= !HREADY && HRESP;
            if (HSEL && HTRANS != 2'b00 && HREADY) begin
                d_first  <= 1;
                d_write  <= HWRITE;
                d_mapped <= mapped(HADDR);
                d_addr   <= HADDR;
            end else begin
                d_first  <= 0;
            end
        end
    end
endmodule

module dma_irq_sva
    import uvm_pkg::*;
#(
    parameter int NCH = 8
)(
    input logic                     CLK, nRST,
    input logic [NCH-1:0][31:0]     channel_control,
    input logic                     dma_interrupt
);
    always @(posedge CLK) if (nRST) begin
        automatic logic any = 0;
        for (int i = 0; i < NCH; i++) any |= channel_control[i][27] | channel_control[i][26];
        if (dma_interrupt != any)
            `uvm_error("SVA09", $sformatf("dma_interrupt=%b but the OR of DONE|ERROR is %b  [R12]", dma_interrupt, any))
    end
endmodule
