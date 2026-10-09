// File:        dma_monitors.svh
// Author:      Isaac Hagedorn
// Date:        2026-10-08
// Description: AHB monitor for each port and the system-pin monitor.

class ahb_monitor extends uvm_monitor;
    `uvm_component_utils(ahb_monitor)

    uvm_analysis_port #(ahb_item) ap;
    ahb_item::port_e port;
    ahb_mgr_vif mvif;   // register port
    ahb_sub_vif svif;   // memory ports

    int unsigned n_xfers, n_errors, n_shadow, n_busy, n_incr4;
    longint      last_activity;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (port == ahb_item::CFG) begin
            if (!uvm_config_db #(ahb_mgr_vif)::get(this, "", "vif", mvif))
                `uvm_fatal("NOVIF", "ahb_monitor: no virtual interface")
        end else if (!uvm_config_db #(ahb_sub_vif)::get(this, "", "vif", svif))
            `uvm_fatal("NOVIF", "ahb_monitor: no virtual interface")
    endfunction

    typedef struct {
        bit rstn, sel, write, ready, resp;
        bit [1:0] trans; bit [2:0] burst, size; bit [31:0] addr, wdata, rdata; bit [3:0] strb;
    } smp_t;

    task sample(output smp_t s);
        if (port == ahb_item::CFG) begin
            @(mvif.mon_cb);
            s.rstn = mvif.mon_cb.HRESETn; s.sel = mvif.mon_cb.HSEL; s.write = mvif.mon_cb.HWRITE;
            s.ready = mvif.mon_cb.HREADY; s.resp = mvif.mon_cb.HRESP; s.trans = mvif.mon_cb.HTRANS;
            s.burst = mvif.mon_cb.HBURST; s.size = mvif.mon_cb.HSIZE; s.addr = mvif.mon_cb.HADDR;
            s.wdata = mvif.mon_cb.HWDATA; s.rdata = mvif.mon_cb.HRDATA; s.strb = mvif.mon_cb.HWSTRB;
        end else begin
            @(svif.mon_cb);
            s.rstn = svif.mon_cb.HRESETn; s.sel = svif.mon_cb.HSEL; s.write = svif.mon_cb.HWRITE;
            s.ready = svif.mon_cb.HREADY; s.resp = svif.mon_cb.HRESP; s.trans = svif.mon_cb.HTRANS;
            s.burst = svif.mon_cb.HBURST; s.size = svif.mon_cb.HSIZE; s.addr = svif.mon_cb.HADDR;
            s.wdata = svif.mon_cb.HWDATA; s.rdata = svif.mon_cb.HRDATA; s.strb = svif.mon_cb.HWSTRB;
        end
    endtask

    task run_phase(uvm_phase phase);
        smp_t        s;
        ahb_item     dp;
        int unsigned beat;
        forever begin
            bit err2;
            sample(s);
            if (!s.rstn) begin
                dp = null;
                continue;
            end
            err2 = 0;
            if (dp != null) begin
                if (!s.ready) dp.waits++;
                else begin
                    dp.cyc  = edge_now();
                    dp.resp  = s.resp;
                    dp.rdata = s.rdata;
                    if (dp.write) begin
                        dp.wdata  = s.wdata;
                        dp.strobe = s.strb;
                    end
                    err2 = s.resp;
                    n_xfers++;
                    if (dp.resp)                n_errors++;
                    if (dp.shadow)              n_shadow++;
                    if (dp.trans == 2'b01)      n_busy++;
                    last_activity = dp.cyc;
                    ap.write(dp);
                    dp = null;
                end
            end
            if (s.sel && s.trans != 2'b00 && s.ready) begin
                dp = ahb_item::type_id::create("obs");
                dp.port   = port;
                dp.write  = s.write;
                dp.addr   = s.addr;
                dp.size   = s.size;
                dp.burst  = s.burst;
                dp.trans  = s.trans;
                dp.shadow = err2;
                dp.aedge  = edge_now();
                if (s.trans == 2'b10) beat = 0;
                else if (s.trans == 2'b11) beat++;
                dp.beat = beat;
                if (s.trans == 2'b10 && s.burst == 3'b011) n_incr4++;
                last_activity = dp.aedge;
                if (err2 && port != ahb_item::CFG) begin
                    ahb_item note = ahb_item::type_id::create("shadow_aphase");
                    note.port = port; note.addr = dp.addr; note.aedge = dp.aedge; note.cyc = dp.aedge;
                    note.shadow = 1; note.aphase_only = 1;
                    ap.write(note);
                end
            end
        end
    endtask

    function void report_phase(uvm_phase phase);
        `uvm_info("MON", $sformatf("%s port: %0d transfers, %0d ERROR, %0d shadow, %0d BUSY, %0d INCR4 bursts",
                                   port.name(), n_xfers, n_errors, n_shadow, n_busy, n_incr4), UVM_LOW)
    endfunction
endclass

class sys_monitor extends uvm_monitor;
    `uvm_component_utils(sys_monitor)

    uvm_analysis_port #(sys_obs) ap;
    sys_vif vif;
    int unsigned n_resets, n_rises;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(sys_vif)::get(this, "", "vif", vif))
            `uvm_fatal("NOVIF", "sys_monitor: no virtual interface")
    endfunction

    task run_phase(uvm_phase phase);
        fork
            watch_edges();
            watch_reset();
        join
    endtask

    task watch_edges();
        bit [NSRC-1:0] prev;
        forever begin
            sys_obs o;
            @(vif.mon_cb);
            o = sys_obs::type_id::create("o");
            o.kind = sys_obs::EDGE;
            o.cyc = edge_now();
            o.nRST = vif.mon_cb.nRST;
            o.trig = vif.mon_cb.trigger_in;
            o.irq  = vif.mon_cb.dma_interrupt;
            o.rise = o.nRST ? (o.trig & ~prev) : '0;
            prev   = o.nRST ? o.trig : '0;
            n_rises += $countones(o.rise);
            ap.write(o);
        end
    endtask

    task watch_reset();
        forever begin
            sys_obs o;
            @(negedge vif.nRST);
            n_resets++;
            o = sys_obs::type_id::create("o");
            o.kind = sys_obs::RESET;
            o.cyc = edge_now();
            ap.write(o);
        end
    endtask
endclass
