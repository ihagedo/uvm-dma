// File:        dma_tests.svh
// Author:      Isaac Hagedorn
// Date:        2026-10-08
// Description: DMA tests: reset, virtual sequences, register sweep, then a PASSED or FAILED banner.

class dma_base_test extends uvm_test;
    `uvm_component_utils(dma_base_test)

    dma_env env;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        env = dma_env::type_id::create("env", this);
        uvm_top.set_report_max_quit_count(20);
    endfunction

    virtual task body();
    endtask

    task run_vseq(dma_base_vseq s);
        `uvm_info("TEST", $sformatf("running %s", s.get_type_name()), UVM_LOW)
        s.env  = env;
        s.regs = env.regs;
        s.start(null);
    endtask

    task run_phase(uvm_phase phase);
        dma_base_vseq fin = dma_base_vseq::type_id::create("final_sweep");
        phase.raise_objection(this);
        fin.env = env; fin.regs = env.regs;
        fin.reset_dut(3);
        fin.cycles(3);
        body();
        env.wait_quiet(100);
        env.scb.settle();
        fin.sweep();
        fin.cycles(5);
        phase.drop_objection(this);
    endtask

    function void report_phase(uvm_phase phase);
        uvm_report_server rs = uvm_report_server::get_server();
        int errs = rs.get_severity_count(UVM_ERROR) + rs.get_severity_count(UVM_FATAL);
        `uvm_info("TEST", $sformatf("config NUM_CHANNELS=%0d FIFO_DEPTH=%0d NUM_SOURCES=%0d", NCH, FDEPTH, NSRC), UVM_NONE)
        if (errs == 0) `uvm_info("TEST", "*** TEST PASSED ***", UVM_NONE)
        else           `uvm_info("TEST", $sformatf("*** TEST FAILED *** (%0d errors)", errs), UVM_NONE)
    endfunction
endclass

class dma_smoke_test extends dma_base_test;
    `uvm_component_utils(dma_smoke_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task body();
        run_vseq(smoke_vseq::type_id::create("smoke"));
    endtask
endclass

class dma_reg_test extends dma_base_test;
    `uvm_component_utils(dma_reg_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task body();
        run_vseq(reg_reset_vseq::type_id::create("t01"));
        run_vseq(reg_bitbash_vseq::type_id::create("t02"));
        run_vseq(reg_ro_vseq::type_id::create("t03"));
        run_vseq(reg_partial_vseq::type_id::create("t04"));
        run_vseq(reg_map_vseq::type_id::create("t05"));
        run_vseq(reg_b2b_vseq::type_id::create("t06"));
        run_vseq(reg_burst_vseq::type_id::create("t06_bursts"));
    endtask
endclass

class dma_copy_test extends dma_base_test;
    `uvm_component_utils(dma_copy_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task body();
        run_vseq(oneshot_len_vseq::type_id::create("t08"));
        run_vseq(size_step_vseq::type_id::create("t09"));
        run_vseq(pattern_vseq::type_id::create("t10"));
        run_vseq(irq_vseq::type_id::create("t12"));
    endtask
endclass

class dma_channels_test extends dma_base_test;
    `uvm_component_utils(dma_channels_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task body();
        run_vseq(all_channels_vseq::type_id::create("t11"));
        run_vseq(arb_mix_vseq::type_id::create("t15"));
    endtask
endclass

class dma_modes_test extends dma_base_test;
    `uvm_component_utils(dma_modes_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task body();
        run_vseq(continuous_vseq::type_id::create("t13"));
        run_vseq(ring_vseq::type_id::create("t14"));
    endtask
endclass

class dma_bus_test extends dma_base_test;
    `uvm_component_utils(dma_bus_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task body();
        run_vseq(burst_vseq::type_id::create("t16"));
        run_vseq(stall_vseq::type_id::create("t17"));
        run_vseq(kb_cross_vseq::type_id::create("t18"));
    endtask
endclass

class dma_error_test extends dma_base_test;
    `uvm_component_utils(dma_error_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task body();
        bus_err_vseq rd = bus_err_vseq::type_id::create("t21");
        bus_err_vseq wr = bus_err_vseq::type_id::create("t22");
        wr.on_write = 1;
        run_vseq(rd);
        run_vseq(wr);
        run_vseq(err_isolation_vseq::type_id::create("t23"));
    endtask
endclass

class dma_stop_test extends dma_base_test;
    `uvm_component_utils(dma_stop_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task body();
        stop_vseq ab = stop_vseq::type_id::create("t25");
        stop_vseq di = stop_vseq::type_id::create("t26");
        di.do_abort = 0;
        run_vseq(ab);
        run_vseq(di);
        run_vseq(rewrite_vseq::type_id::create("t27"));
        run_vseq(reset_mid_vseq::type_id::create("t29"));
    endtask
endclass

class dma_bad_cfg_test extends dma_base_test;
    `uvm_component_utils(dma_bad_cfg_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task body();
        run_vseq(bad_cfg_vseq::type_id::create("t30"));
    endtask
endclass

class dma_trigger_test extends dma_base_test;
    `uvm_component_utils(dma_trigger_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task body();
        run_vseq(armed_nonring_vseq::type_id::create("t32"));
        run_vseq(trig_pace_vseq::type_id::create("t33"));
        run_vseq(trig_credit_vseq::type_id::create("t34_t35"));
        run_vseq(trig_burst_vseq::type_id::create("t36"));
    endtask
endclass

class dma_corner_test extends dma_base_test;
    `uvm_component_utils(dma_corner_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task body();
        run_vseq(corner_vseq::type_id::create("corner"));
    endtask
endclass

class dma_rand_test extends dma_base_test;
    `uvm_component_utils(dma_rand_test)
    bit errs, stops, regs_traffic;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task body();
        rand_vseq r = rand_vseq::type_id::create("rand");
        r.with_errors = errs; r.with_stops = stops; r.with_regs = regs_traffic;
        run_vseq(r);
    endtask
endclass

class dma_rand_err_test extends dma_rand_test;
    `uvm_component_utils(dma_rand_err_test)
    function new(string name, uvm_component parent); super.new(name, parent); errs = 1; endfunction
endclass

class dma_rand_stop_test extends dma_rand_test;
    `uvm_component_utils(dma_rand_stop_test)
    function new(string name, uvm_component parent); super.new(name, parent); stops = 1; endfunction
endclass

class dma_rand_reg_test extends dma_rand_test;
    `uvm_component_utils(dma_rand_reg_test)
    function new(string name, uvm_component parent); super.new(name, parent); regs_traffic = 1; endfunction
endclass

class dma_restart_race_test extends dma_base_test;
    `uvm_component_utils(dma_restart_race_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task body();
        run_vseq(restart_race_vseq::type_id::create("restart"));
    endtask
endclass

class dma_perf_test extends dma_base_test;
    `uvm_component_utils(dma_perf_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task body();
        run_vseq(perf_vseq::type_id::create("perf"));
    endtask
endclass
