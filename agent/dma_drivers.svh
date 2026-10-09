// File:        dma_drivers.svh
// Author:      Isaac Hagedorn
// Date:        2026-10-08
// Description: Register-port AHB manager, memory responders for the read and write ports, and the trigger/reset driver.

class ahb_mgr_driver extends uvm_driver #(ahb_item);
    `uvm_component_utils(ahb_mgr_driver)

    ahb_mgr_vif vif;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(ahb_mgr_vif)::get(this, "", "vif", vif))
            `uvm_fatal("NOVIF", "ahb_mgr_driver: no virtual interface")
    endfunction

    function void drive_idle();
        vif.HSEL      <= 1'b0;
        vif.HTRANS    <= 2'b00;
        vif.HBURST    <= 3'b000;
        vif.HMASTLOCK <= 1'b0;
    endfunction

    function void drive_addr(ahb_item it);
        vif.HSEL      <= 1'b1;
        vif.HTRANS    <= it.trans;
        vif.HADDR     <= it.addr;
        vif.HWRITE    <= it.write;
        vif.HSIZE     <= it.size;
        vif.HBURST    <= it.burst;
        vif.HMASTLOCK <= 1'b0;
    endfunction

    task run_phase(uvm_phase phase);
        ahb_item     ap, dp;   // address phase / data phase in progress
        int unsigned idle_left;
        bit          cancel, cancel_next, ap_driven;

        vif.HSEL = 0; vif.HTRANS = 0; vif.HWRITE = 0; vif.HMASTLOCK = 0; vif.HBURST = 0;
        vif.HSIZE = 3'd2; vif.HADDR = 0; vif.HWDATA = 0; vif.HWSTRB = 0;
        @(vif.drv_cb);
        forever begin
            if (ap == null && dp == null) begin
                drive_idle();
                seq_item_port.get_next_item(ap);
                idle_left = ap.idle_before;
                @(vif.drv_cb);
            end else if (ap == null) begin
                seq_item_port.try_next_item(ap);
                if (ap != null) idle_left = ap.idle_before;
            end

            ap_driven = ap != null && idle_left == 0 && !cancel && vif.HRESETn;
            if (ap_driven) drive_addr(ap);
            else           drive_idle();
            if (dp != null && dp.write && dp.trans != 2'b01) begin
                vif.HWDATA    <= dp.wdata;
                vif.HWSTRB    <= dp.strobe;
            end else begin
                vif.HWSTRB    <= 4'h0;
            end

            @(vif.drv_cb);
            cancel_next = 0;
            if (!vif.drv_cb.HRESETn) begin
                if (dp != null) begin
                    dp.aborted = 1;
                    seq_item_port.put_response(dp);
                    dp = null;
                end
                cancel = 0;
                continue;
            end
            if (dp != null) begin
                if (vif.drv_cb.HREADY) begin
                    dp.rdata = vif.drv_cb.HRDATA;
                    dp.resp  = vif.drv_cb.HRESP;
                    dp.cyc  = edge_now();
                    seq_item_port.put_response(dp);
                    dp = null;
                end else if (vif.drv_cb.HRESP && ap != null && ap.cancel_on_error) begin
                    cancel_next = 1;
                end
            end
            if (ap != null) begin
                if (idle_left > 0) idle_left--;
                else if (ap_driven && vif.drv_cb.HREADY) begin
                    ap.aedge = edge_now();
                    seq_item_port.item_done();
                    dp = ap;
                    ap = null;
                end
            end
            cancel = cancel_next;
        end
    endtask
endclass

class ahb_resp_driver extends uvm_component;
    `uvm_component_utils(ahb_resp_driver)

    ahb_sub_vif  vif;
    dma_mem      mem;
    dma_resp_cfg cfg;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(ahb_sub_vif)::get(this, "", "vif", vif))
            `uvm_fatal("NOVIF", "ahb_resp_driver: no virtual interface")
    endfunction

    task run_phase(uvm_phase phase);
        bit          active, d_write, d_err, d_busy, err2, prev_err2;
        bit [31:0]   d_addr;
        int unsigned waits;
        int          err_stage;

        vif.HREADYOUT = 1'b1; vif.HRESP = 1'b0; vif.HRDATA = '0;
        forever begin
            @(vif.drv_cb);
            if (!vif.drv_cb.HRESETn) begin
                active = 0; prev_err2 = 0;
                vif.HREADYOUT <= 1'b1;
                vif.HRESP     <= 1'b0;
                continue;
            end
            err2 = 0;
            if (active && vif.drv_cb.HREADY) begin
                if (d_err) err2 = 1;
                else if (d_write && !d_busy)
                    mem.bus_write(d_addr, vif.drv_cb.HWDATA, vif.drv_cb.HWSTRB);
                active = 0;
            end
            if (vif.drv_cb.HSEL && vif.drv_cb.HTRANS != 2'b00 && vif.drv_cb.HREADY) begin
                active    = 1;
                d_addr    = vif.drv_cb.HADDR;
                d_write   = vif.drv_cb.HWRITE;
                d_busy    = vif.drv_cb.HTRANS == 2'b01;
                waits     = d_busy ? 0 : cfg.pick_waits();
                d_err     = !d_busy && !err2 && cfg.pick_error(d_addr);
                err_stage = 0;
            end
            if (active && waits > 0) begin
                waits--;
                vif.HREADYOUT <= 1'b0;
                vif.HRESP     <= 1'b0;
            end else if (active && d_err) begin
                vif.HREADYOUT <= (err_stage == 1);
                vif.HRESP     <= 1'b1;
                err_stage++;
            end else begin
                vif.HREADYOUT <= 1'b1;
                vif.HRESP     <= 1'b0;
                vif.HRDATA    <= (active && !d_write) ? mem.read_word(d_addr) : 32'h0;
            end
        end
    endtask
endclass

class sys_driver extends uvm_driver #(sys_item);
    `uvm_component_utils(sys_driver)

    sys_vif vif;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(sys_vif)::get(this, "", "vif", vif))
            `uvm_fatal("NOVIF", "sys_driver: no virtual interface")
    endfunction

    task run_phase(uvm_phase phase);
        forever begin
            seq_item_port.get_next_item(req);
            if (req.kind == sys_item::PULSE) begin
                @(posedge vif.CLK);
                vif.trigger_in <= vif.trigger_in | req.lines;
                repeat (req.high) @(posedge vif.CLK);
                vif.trigger_in <= vif.trigger_in & ~req.lines;
                repeat (req.low > 0 ? req.low - 1 : 0) @(posedge vif.CLK);
            end else begin
                @(posedge vif.CLK);
                #(PERIOD_NS * req.rst_pct / 100 * 1ns);
                vif.nRST       <= 1'b0;
                vif.trigger_in <= '0;
                repeat (req.rst_edges) @(posedge vif.CLK);
                @(negedge vif.CLK);
                vif.nRST <= 1'b1;
            end
            seq_item_port.item_done();
        end
    endtask
endclass
