// File:        dma_agents.svh
// Author:      Isaac Hagedorn
// Date:        2026-10-08
// Description: Agents for the register port, the two memory ports and the system pins.

class cfg_agent extends uvm_agent;
    `uvm_component_utils(cfg_agent)
    uvm_sequencer #(ahb_item) sqr;
    ahb_mgr_driver            drv;
    ahb_monitor               mon;
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        sqr = uvm_sequencer #(ahb_item)::type_id::create("sqr", this);
        drv = ahb_mgr_driver::type_id::create("drv", this);
        mon = ahb_monitor::type_id::create("mon", this);
        mon.port = ahb_item::CFG;
    endfunction
    function void connect_phase(uvm_phase phase);
        drv.seq_item_port.connect(sqr.seq_item_export);
    endfunction
endclass

class resp_agent extends uvm_agent;
    `uvm_component_utils(resp_agent)
    ahb_resp_driver  drv;
    ahb_monitor      mon;
    ahb_item::port_e port;
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        drv = ahb_resp_driver::type_id::create("drv", this);
        mon = ahb_monitor::type_id::create("mon", this);
        mon.port = port;
    endfunction
endclass

class sys_agent extends uvm_agent;
    `uvm_component_utils(sys_agent)
    uvm_sequencer #(sys_item) sqr;
    sys_driver                drv;
    sys_monitor               mon;
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        sqr = uvm_sequencer #(sys_item)::type_id::create("sqr", this);
        drv = sys_driver::type_id::create("drv", this);
        mon = sys_monitor::type_id::create("mon", this);
    endfunction
    function void connect_phase(uvm_phase phase);
        drv.seq_item_port.connect(sqr.seq_item_export);
    endfunction
endclass
