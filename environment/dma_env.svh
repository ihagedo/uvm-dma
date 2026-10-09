// File:        dma_env.svh
// Author:      Isaac Hagedorn
// Date:        2026-10-08
// Description: DMA environment: agents, register model, memory, scoreboard and coverage.

class dma_env extends uvm_env;
    `uvm_component_utils(dma_env)

    cfg_agent         cfg;
    resp_agent        rd, wr;
    sys_agent         sys;
    dma_mem           mem;
    dma_resp_cfg      rd_cfg, wr_cfg;
    dma_reg_block     regs;
    dma_reg_adapter   adapter;
    dma_reg_predictor predictor;
    dma_scoreboard    scb;
    dma_coverage      cov;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        cfg = cfg_agent::type_id::create("cfg", this);
        rd  = resp_agent::type_id::create("rd", this);
        wr  = resp_agent::type_id::create("wr", this);
        rd.port = ahb_item::RD;
        wr.port = ahb_item::WR;
        sys = sys_agent::type_id::create("sys", this);
        mem    = dma_mem::type_id::create("mem");
        rd_cfg = dma_resp_cfg::type_id::create("rd_cfg");
        wr_cfg = dma_resp_cfg::type_id::create("wr_cfg");
        regs = dma_reg_block::type_id::create("regs");
        regs.build();
        adapter   = dma_reg_adapter::type_id::create("adapter");
        predictor = dma_reg_predictor::type_id::create("predictor", this);
        scb = dma_scoreboard::type_id::create("scb", this);
        cov = dma_coverage::type_id::create("cov", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        regs.default_map.set_sequencer(cfg.sqr, adapter);
        regs.default_map.set_auto_predict(0);
        predictor.map     = regs.default_map;
        predictor.adapter = adapter;
        cfg.mon.ap.connect(predictor.bus_in);

        rd.drv.mem = mem; rd.drv.cfg = rd_cfg;
        wr.drv.mem = mem; wr.drv.cfg = wr_cfg;

        scb.mem = mem;
        scb.cov = cov;
        cfg.mon.ap.connect(scb.cfg_imp);
        rd.mon.ap.connect(scb.rd_imp);
        wr.mon.ap.connect(scb.wr_imp);
        sys.mon.ap.connect(scb.sys_imp);
    endfunction

    task wait_quiet(int unsigned n = 50);
        longint t0 = edge_now();
        forever begin
            longint last = (rd.mon.last_activity > wr.mon.last_activity) ? rd.mon.last_activity : wr.mon.last_activity;
            if (last < t0) last = t0;
            if (edge_now() - last >= n) return;
            @(posedge sys.drv.vif.CLK);
        end
    endtask
endclass
