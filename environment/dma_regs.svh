// File:        dma_regs.svh
// Author:      Isaac Hagedorn
// Date:        2026-10-08
// Description: UVM register model of the DMA register map, with its adapter and predictor.

virtual class dma_reg_base extends uvm_reg;
    function new(string name);
        super.new(name, 32, UVM_NO_COVERAGE);
    endfunction
    pure virtual function void build();
endclass

class dma_reg_rw extends dma_reg_base;
    `uvm_object_utils(dma_reg_rw)
    rand uvm_reg_field VALUE;
    function new(string name = "dma_reg_rw");
        super.new(name);
    endfunction
    virtual function void build();
        VALUE = uvm_reg_field::type_id::create("VALUE");
        VALUE.configure(this, 32, 0, "RW", 0, 32'h0, 1, 1, 1);
    endfunction
endclass

class dma_reg_status extends dma_reg_base;
    `uvm_object_utils(dma_reg_status)
    uvm_reg_field VALUE;
    function new(string name = "dma_reg_status");
        super.new(name);
    endfunction
    virtual function void build();
        VALUE = uvm_reg_field::type_id::create("VALUE");
        VALUE.configure(this, 32, 0, "RO", 1, 32'h0, 1, 0, 1);
        VALUE.set_compare(UVM_NO_CHECK);
    endfunction
endclass

class dma_reg_control extends dma_reg_base;
    `uvm_object_utils(dma_reg_control)
    rand uvm_reg_field SIZE, RSVD_3_2, MODE, ENABLE, SOURCE_INCR, DEST_INCR, ABORT, RSVD_25,
                       ERROR, DONE, RING_SIZE, BUFFER_SEL;
    function new(string name = "dma_reg_control");
        super.new(name);
    endfunction
    function uvm_reg_field mk(string n, int unsigned w, int unsigned lsb, bit vol);
        uvm_reg_field f = uvm_reg_field::type_id::create(n);
        f.configure(this, w, lsb, "RW", vol, 0, 1, 1, 0);
        if (vol) f.set_compare(UVM_NO_CHECK);
        return f;
    endfunction
    virtual function void build();
        SIZE        = mk("SIZE",        2,  0, 0);
        RSVD_3_2    = mk("RSVD_3_2",    2,  2, 0);   // reserved, stored
        MODE        = mk("MODE",        3,  4, 0);
        ENABLE      = mk("ENABLE",      1,  7, 1);
        SOURCE_INCR = mk("SOURCE_INCR", 8,  8, 0);
        DEST_INCR   = mk("DEST_INCR",   8, 16, 0);
        ABORT       = mk("ABORT",       1, 24, 1);
        RSVD_25     = mk("RSVD_25",     1, 25, 0);
        ERROR       = mk("ERROR",       1, 26, 1);
        DONE        = mk("DONE",        1, 27, 1);
        RING_SIZE   = mk("RING_SIZE",   3, 28, 0);
        BUFFER_SEL  = mk("BUFFER_SEL",  1, 31, 0);
    endfunction
endclass

class dma_reg_tcfg extends dma_reg_base;
    `uvm_object_utils(dma_reg_tcfg)
    rand uvm_reg_field SOURCE_SEL, RSVD_6_5, ARM, RSVD_15_8, COUNT, RSVD_31_24;
    function new(string name = "dma_reg_tcfg");
        super.new(name);
    endfunction
    function uvm_reg_field mk(string n, int unsigned w, int unsigned lsb, uvm_reg_data_t rst);
        uvm_reg_field f = uvm_reg_field::type_id::create(n);
        f.configure(this, w, lsb, "RW", 0, rst, 1, 1, 0);
        return f;
    endfunction
    virtual function void build();
        SOURCE_SEL = mk("SOURCE_SEL", 5,  0, 0);
        RSVD_6_5   = mk("RSVD_6_5",   2,  5, 0);
        ARM        = mk("ARM",        1,  7, 0);
        RSVD_15_8  = mk("RSVD_15_8",  8,  8, 0);
        COUNT      = mk("COUNT",      8, 16, 1);
        RSVD_31_24 = mk("RSVD_31_24", 8, 24, 0);
    endfunction
endclass

class dma_reg_tstat extends dma_reg_base;
    `uvm_object_utils(dma_reg_tstat)
    uvm_reg_field CREDIT, OVERRUN;
    function new(string name = "dma_reg_tstat");
        super.new(name);
    endfunction
    virtual function void build();
        CREDIT  = uvm_reg_field::type_id::create("CREDIT");
        CREDIT.configure(this, 12, 0, "RO", 1, 0, 1, 0, 0);
        CREDIT.set_compare(UVM_NO_CHECK);
        OVERRUN = uvm_reg_field::type_id::create("OVERRUN");
        OVERRUN.configure(this, 1, 16, "WC", 1, 0, 1, 0, 0);
        OVERRUN.set_compare(UVM_NO_CHECK);
    endfunction
endclass

class dma_reg_block extends uvm_reg_block;
    `uvm_object_utils(dma_reg_block)

    rand dma_reg_rw      SOURCE[NCH], DESTINATION[NCH], DESIRED_TRANSFERS[NCH];
    rand dma_reg_control CONTROL[NCH];
    dma_reg_status       TRANSFERS_COMPLETED[NCH], TRANSFERS_REMAINING[NCH],
                         CURRENT_CHANNEL_ACTIVE[NCH], ERROR_ADDRESS[NCH];
    rand dma_reg_tcfg    TRIGGER_CONFIG[NCH];
    dma_reg_tstat        TRIGGER_STATUS[NCH];

    function new(string name = "dma_reg_block");
        super.new(name, UVM_NO_COVERAGE);
    endfunction

    function void add(dma_reg_base r, uvm_reg_addr_t off, string rights);
        r.configure(this);
        r.build();
        default_map.add_reg(r, off, rights);
    endfunction

    virtual function void build();
        default_map = create_map("map", REG_BASE, 4, UVM_LITTLE_ENDIAN, 1);
        for (int c = 0; c < NCH; c++) begin
            SOURCE[c]            = dma_reg_rw::type_id::create($sformatf("SOURCE_%0d", c));
            DESTINATION[c]       = dma_reg_rw::type_id::create($sformatf("DESTINATION_%0d", c));
            CONTROL[c]           = dma_reg_control::type_id::create($sformatf("CONTROL_%0d", c));
            DESIRED_TRANSFERS[c] = dma_reg_rw::type_id::create($sformatf("DESIRED_TRANSFERS_%0d", c));
            add(SOURCE[c],            16 * c + 'h0, "RW");
            add(DESTINATION[c],       16 * c + 'h4, "RW");
            add(CONTROL[c],           16 * c + 'h8, "RW");
            add(DESIRED_TRANSFERS[c], 16 * c + 'hC, "RW");

            TRANSFERS_COMPLETED[c]    = dma_reg_status::type_id::create($sformatf("TRANSFERS_COMPLETED_%0d", c));
            TRANSFERS_REMAINING[c]    = dma_reg_status::type_id::create($sformatf("TRANSFERS_REMAINING_%0d", c));
            CURRENT_CHANNEL_ACTIVE[c] = dma_reg_status::type_id::create($sformatf("CURRENT_CHANNEL_ACTIVE_%0d", c));
            ERROR_ADDRESS[c]          = dma_reg_status::type_id::create($sformatf("ERROR_ADDRESS_%0d", c));
            add(TRANSFERS_COMPLETED[c],    16 * NCH + 16 * c + 'h0, "RO");
            add(TRANSFERS_REMAINING[c],    16 * NCH + 16 * c + 'h4, "RO");
            add(CURRENT_CHANNEL_ACTIVE[c], 16 * NCH + 16 * c + 'h8, "RO");
            add(ERROR_ADDRESS[c],          16 * NCH + 16 * c + 'hC, "RO");

            TRIGGER_CONFIG[c] = dma_reg_tcfg::type_id::create($sformatf("TRIGGER_CONFIG_%0d", c));
            TRIGGER_STATUS[c] = dma_reg_tstat::type_id::create($sformatf("TRIGGER_STATUS_%0d", c));
            add(TRIGGER_CONFIG[c], 32 * NCH + 8 * c + 'h0, "RW");
            add(TRIGGER_STATUS[c], 32 * NCH + 8 * c + 'h4, "RW");
        end
        lock_model();
    endfunction
endclass

class dma_reg_adapter extends uvm_reg_adapter;
    `uvm_object_utils(dma_reg_adapter)
    function new(string name = "dma_reg_adapter");
        super.new(name);
        provides_responses = 1;
        supports_byte_enable = 0;
    endfunction
    virtual function uvm_sequence_item reg2bus(const ref uvm_reg_bus_op rw);
        ahb_item it = ahb_item::type_id::create("reg");
        it.write  = (rw.kind == UVM_WRITE);
        it.addr   = rw.addr;
        it.size   = 3'd2;
        it.strobe = 4'hF;
        it.wdata  = rw.data;
        return it;
    endfunction
    virtual function void bus2reg(uvm_sequence_item bus_item, ref uvm_reg_bus_op rw);
        ahb_item it;
        if (!$cast(it, bus_item)) `uvm_fatal("ADAPT", "not an ahb_item")
        rw.kind    = it.write ? UVM_WRITE : UVM_READ;
        rw.addr    = it.addr;
        rw.data    = it.write ? it.wdata : it.rdata;
        rw.n_bits  = 32;
        rw.byte_en = '1;
        rw.status  = (it.resp || it.aborted) ? UVM_NOT_OK : UVM_IS_OK;
    endfunction
endclass

class dma_reg_predictor extends uvm_reg_predictor #(ahb_item);
    `uvm_component_utils(dma_reg_predictor)
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
    virtual function void write(ahb_item tr);
        if (tr.resp || tr.size != 3'd2 || tr.addr[1:0] != 0 || (tr.write && tr.strobe != 4'hF)) return;
        super.write(tr);
    endfunction
endclass
