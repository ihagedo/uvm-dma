// File:        dma_seqs.svh
// Author:      Isaac Hagedorn
// Date:        2026-10-08
// Description: Virtual sequences for the DMA test plan rows.

typedef class rand_reg_vseq;

class dma_copy extends uvm_object;
    `uvm_object_utils(dma_copy)
    int        ch;
    bit [2:0]  mode;   // 0 one-shot, 1 continuous, 2 ring
    bit [1:0]  size  = 2;   // 0 byte, 1 halfword, 2 word
    bit [7:0]  sincr = 4, dincr = 4;
    bit [31:0] len   = 16;   // DESIRED_TRANSFERS
    bit [2:0]  ring_size;
    bit        bsel;
    bit [31:0] src_off, dst_off;

    function new(string name = "dma_copy");
        super.new(name);
    endfunction

    function bit [31:0] src(); return SRC_AREA + ch * AREA_SIZE + src_off; endfunction
    function bit [31:0] dst(); return DST_AREA + ch * AREA_SIZE + dst_off; endfunction

    function bit [31:0] ctrl(bit en = 1, bit do_abort = 0);
        return {bsel, ring_size, 1'b0, 1'b0, 1'b0, do_abort, dincr, sincr, en, mode, 2'b00, size};
    endfunction

    function int unsigned pass_items();
        return (mode == 2) ? (1 << ring_size) : len;
    endfunction

    function void randomize_copy(int c, int max_len = 64, bit allow_ring = 1, bit allow_cont = 0);
        int unsigned b;
        ch   = c;
        mode = allow_cont && $urandom_range(3) == 0 ? 1 : (allow_ring && $urandom_range(3) == 0 ? 2 : 0);
        size = $urandom_range(2);
        b    = 1 << size;
        case ($urandom_range(4))
            0: sincr = 0;
            1: sincr = b;
            2: sincr = 2 * b;
            3: sincr = 255 & ~(b - 1);
            4: sincr = b * $urandom_range(1, 255 / b);
        endcase
        case ($urandom_range(4))
            0: dincr = (mode == 2) ? b : 0;
            1: dincr = b;
            2: dincr = 2 * b;
            3: dincr = 255 & ~(b - 1);
            4: dincr = b * $urandom_range(1, 255 / b);
        endcase
        len       = $urandom_range(1, max_len);
        ring_size = $urandom_range(4);
        bsel      = $urandom_range(1);
        src_off   = ($urandom_range(32'h3_0000)) & ~(b - 1);
        dst_off   = ($urandom_range(32'h3_0000)) & ~(b - 1);
    endfunction

    function void copy_from(dma_copy o);
        ch = o.ch; mode = o.mode; size = o.size; sincr = o.sincr; dincr = o.dincr; len = o.len;
        ring_size = o.ring_size; bsel = o.bsel; src_off = o.src_off; dst_off = o.dst_off;
    endfunction

    function string convert2string();
        return $sformatf("ch%0d %s size=%0d steps=%0d/%0d len=%0d%s src=%h dst=%h", ch,
                         mode == 0 ? "one-shot" : mode == 1 ? "continuous" : mode == 2 ? "ring" : "mode?",
                         size, sincr, dincr, len, mode == 2 ? $sformatf(" ring=%0d sel=%0d", 1 << ring_size, bsel) : "",
                         src(), dst());
    endfunction
endclass

class dma_base_vseq extends uvm_sequence #(uvm_sequence_item);
    `uvm_object_utils(dma_base_vseq)

    dma_env       env;
    dma_reg_block regs;

    function new(string name = "dma_base_vseq");
        super.new(name);
        set_response_queue_depth(-1);
    endfunction

    task cycles(int unsigned n);
        repeat (n) @(posedge env.sys.drv.vif.CLK);
    endtask

    task xfer(ahb_item it);
        uvm_sequence_item r;
        start_item(it, -1, env.cfg.sqr);
        finish_item(it);
        get_response(r, it.get_transaction_id());
    endtask

    task raw_write(bit [31:0] a, bit [31:0] d, output bit resp, input bit [3:0] strb = 4'hF,
                   input bit [2:0] size = 3'd2);
        ahb_item it = ahb_item::type_id::create("w");
        it.write = 1; it.addr = a; it.wdata = d; it.strobe = strb; it.size = size;
        xfer(it);
        resp = it.resp;
    endtask

    task raw_read(bit [31:0] a, output bit [31:0] d, output bit resp, input bit [2:0] size = 3'd2);
        ahb_item it = ahb_item::type_id::create("r");
        it.write = 0; it.addr = a; it.size = size;
        xfer(it);
        d = it.rdata; resp = it.resp;
    endtask

    task wreg(uvm_reg r, uvm_reg_data_t v);
        uvm_status_e st;
        r.write(st, v, .parent(this));
        if (st != UVM_IS_OK) `uvm_error("SEQ", $sformatf("write of %s returned ERROR", r.get_name()))
    endtask

    task rreg(uvm_reg r, output uvm_reg_data_t v);
        uvm_status_e st;
        r.read(st, v, .parent(this));
        if (st != UVM_IS_OK) `uvm_error("SEQ", $sformatf("read of %s returned ERROR", r.get_name()))
    endtask

    function bit [31:0] pattern_word(int pat, int k);
        case (pat)
            0: return 32'h0000_0000;
            1: return 32'hFFFF_FFFF;
            2: return 32'hAAAA_AAAA;
            3: return 32'h5555_5555;
            4: return 32'h1 << (k % 32);
            5: return ~(32'h1 << (k % 32));
            default: return $urandom;
        endcase
    endfunction

    function void fill(dma_copy c, int pat = -1);
        int unsigned n = c.pass_items();
        if (n > 2048) n = 2048;
        if (n == 0)   n = 1;
        for (int k = 0; k < n; k++) begin
            bit [31:0] a = (c.mode == 2 && c.bsel) ? c.src() : c.src() + k * c.sincr;
            env.mem.write_word(a, pattern_word(pat, k));
        end
    endfunction

    task start_copy(dma_copy c);
        `uvm_info("SEQ", {"start ", c.convert2string()}, UVM_MEDIUM)
        wreg(regs.SOURCE[c.ch], c.src());
        wreg(regs.DESTINATION[c.ch], c.dst());
        wreg(regs.DESIRED_TRANSFERS[c.ch], c.len);
        wreg(regs.CONTROL[c.ch], c.ctrl(1));
    endtask

    task wait_done(int ch, output uvm_reg_data_t v, input int unsigned timeout = 200000, int unsigned gap = 16);
        longint t0 = edge_now();
        forever begin
            rreg(regs.CONTROL[ch], v);
            if (v[27] || v[26]) return;
            if (edge_now() - t0 > timeout) begin
                `uvm_error("SEQ", $sformatf("ch%0d: no DONE or ERROR after %0d cycles (CONTROL=%h)", ch, timeout, v))
                return;
            end
            cycles(gap);
        end
    endtask

    task wait_irq(output bit got, input int unsigned timeout = 200000);
        longint t0 = edge_now();
        got = 0;
        while (!env.sys.drv.vif.dma_interrupt) begin
            if (edge_now() - t0 > timeout) return;
            cycles(1);
        end
        got = 1;
    endtask

    task clear(int ch);
        wreg(regs.CONTROL[ch], 0);
    endtask

    task stop(dma_copy c, bit do_abort);
        wreg(regs.CONTROL[c.ch], c.ctrl(0, do_abort));
    endtask

    task reset_dut(int unsigned edges = 2, int unsigned pct = 40);
        sys_item it = sys_item::type_id::create("rst");
        it.kind = sys_item::RESET; it.rst_edges = edges; it.rst_pct = pct;
        start_item(it, -1, env.sys.sqr);
        finish_item(it);
    endtask

    task pulse(bit [NSRC-1:0] lines, int unsigned high = 1, int unsigned low = 1);
        sys_item it = sys_item::type_id::create("trig");
        it.kind = sys_item::PULSE; it.lines = lines; it.high = high; it.low = low;
        start_item(it, -1, env.sys.sqr);
        finish_item(it);
    endtask

    task wait_quiet(int unsigned n = 60);
        env.wait_quiet(n);
    endtask

    task wait_drained(int c, int unsigned timeout = 20000);
        longint t0 = edge_now();
        while (!env.scb.drained(c)) begin
            if (edge_now() - t0 > timeout) begin
                `uvm_error("SEQ", $sformatf("ch%0d did not drain in %0d cycles", c, timeout))
                return;
            end
            cycles(4);
        end
    endtask

    task sweep();
        uvm_reg_data_t v;
        for (int c = 0; c < NCH; c++) begin
            rreg(regs.SOURCE[c], v);
            rreg(regs.DESTINATION[c], v);
            rreg(regs.CONTROL[c], v);
            rreg(regs.DESIRED_TRANSFERS[c], v);
            rreg(regs.TRANSFERS_COMPLETED[c], v);
            rreg(regs.TRANSFERS_REMAINING[c], v);
            rreg(regs.CURRENT_CHANNEL_ACTIVE[c], v);
            rreg(regs.ERROR_ADDRESS[c], v);
            rreg(regs.TRIGGER_CONFIG[c], v);
            rreg(regs.TRIGGER_STATUS[c], v);
        end
    endtask

    task copy_and_wait(dma_copy c, int pat = -1);
        uvm_reg_data_t v;
        fill(c, pat);
        start_copy(c);
        wait_done(c.ch, v);
        clear(c.ch);
    endtask
endclass

class smoke_vseq extends dma_base_vseq;
    `uvm_object_utils(smoke_vseq)
    function new(string name = "smoke_vseq"); super.new(name); endfunction
    task body();
        dma_copy c = dma_copy::type_id::create("c");
        c.ch = 0; c.len = 16;
        copy_and_wait(c);
    endtask
endclass

class reg_reset_vseq extends dma_base_vseq;
    `uvm_object_utils(reg_reset_vseq)
    function new(string name = "reg_reset_vseq"); super.new(name); endfunction
    task body();
        uvm_reg_hw_reset_seq rs = uvm_reg_hw_reset_seq::type_id::create("hw_reset");
        rs.model = regs;
        rs.start(null, this);
    endtask
endclass

class reg_bitbash_vseq extends dma_base_vseq;
    `uvm_object_utils(reg_bitbash_vseq)
    function new(string name = "reg_bitbash_vseq"); super.new(name); endfunction
    task body();
        uvm_reg_bit_bash_seq bb = uvm_reg_bit_bash_seq::type_id::create("bit_bash");
        uvm_reg_data_t v;
        for (int c = 0; c < NCH; c++) begin
            uvm_reg skip[$] = '{regs.CONTROL[c], regs.TRANSFERS_COMPLETED[c], regs.TRANSFERS_REMAINING[c],
                                regs.CURRENT_CHANNEL_ACTIVE[c], regs.ERROR_ADDRESS[c], regs.TRIGGER_STATUS[c]};
            foreach (skip[i])
                uvm_resource_db #(bit)::set({"REG::", skip[i].get_full_name()}, "NO_REG_BIT_BASH_TEST", 1, this);
            if (c >= 4) begin
                uvm_reg rest[$] = '{regs.SOURCE[c], regs.DESTINATION[c], regs.DESIRED_TRANSFERS[c], regs.TRIGGER_CONFIG[c]};
                foreach (rest[i])
                    uvm_resource_db #(bit)::set({"REG::", rest[i].get_full_name()}, "NO_REG_BIT_BASH_TEST", 1, this);
            end
        end
        bb.model = regs;
        bb.start(null, this);
        for (int c = 4; c < NCH; c++) begin
            uvm_reg rest[$] = '{regs.SOURCE[c], regs.DESTINATION[c], regs.DESIRED_TRANSFERS[c], regs.TRIGGER_CONFIG[c]};
            foreach (rest[i]) begin
                wreg(rest[i], 32'hA5A5_5A5A ^ c); rreg(rest[i], v);
                wreg(rest[i], 32'h5A5A_A5A5 ^ c); rreg(rest[i], v);
                wreg(rest[i], (i == 3) ? 32'h0001_0000 : 0);
            end
        end
        for (int c = 0; c < NCH; c += (NCH > 8 ? 5 : 1)) begin
            for (int b = 0; b < 32; b++) begin
                if (b == 7 || b == 24) continue;
                wreg(regs.CONTROL[c], 32'h1 << b);              rreg(regs.CONTROL[c], v);
                wreg(regs.CONTROL[c], ~(32'h0100_0080 | (32'h1 << b)) & ~32'h0100_0080); rreg(regs.CONTROL[c], v);
            end
            wreg(regs.CONTROL[c], 0);
            wreg(regs.CONTROL[c], 32'h0100_0000);
            rreg(regs.CONTROL[c], v);
            rreg(regs.CONTROL[c], v);
            wreg(regs.CONTROL[c], 0);
        end
    endtask
endclass

class reg_ro_vseq extends dma_base_vseq;
    `uvm_object_utils(reg_ro_vseq)
    function new(string name = "reg_ro_vseq"); super.new(name); endfunction
    task body();
        uvm_reg_data_t v;
        bit resp;
        dma_copy c = dma_copy::type_id::create("c");
        c.ch = 0; c.len = 5;
        copy_and_wait(c);
        for (int ch = 0; ch < NCH; ch++) begin
            bit [31:0] base = REG_BASE + 16 * NCH + 16 * ch;
            for (int r = 0; r < 4; r++) begin
                raw_write(base + 4 * r, $urandom, resp);
                raw_read(base + 4 * r, v, resp);
            end
            raw_write(REG_BASE + 32 * NCH + 8 * ch + 4, $urandom, resp);
            raw_read(REG_BASE + 32 * NCH + 8 * ch + 4, v, resp);
        end
    endtask
endclass

class reg_partial_vseq extends dma_base_vseq;
    `uvm_object_utils(reg_partial_vseq)
    function new(string name = "reg_partial_vseq"); super.new(name); endfunction
    task body();
        uvm_reg_data_t v;
        bit resp;
        for (int ch = 0; ch < NCH; ch += (NCH > 8 ? 3 : 1)) begin
            bit [31:0] regs_a[$];
            for (int r = 0; r < 4; r++) regs_a.push_back(REG_BASE + 16 * ch + 4 * r);
            for (int r = 0; r < 4; r++) regs_a.push_back(REG_BASE + 16 * NCH + 16 * ch + 4 * r);
            regs_a.push_back(REG_BASE + 32 * NCH + 8 * ch);
            regs_a.push_back(REG_BASE + 32 * NCH + 8 * ch + 4);
            foreach (regs_a[i]) begin
                for (int lane = 0; lane < 4; lane++) raw_write(regs_a[i], $urandom, resp, 4'b0001 << lane, 3'd0);
                raw_write(regs_a[i], $urandom, resp, 4'b0011, 3'd1);
                raw_write(regs_a[i], $urandom, resp, 4'b1100, 3'd1);
                for (int s = 0; s < 15; s++) if ($urandom_range(2) == 0) raw_write(regs_a[i], $urandom, resp, s[3:0]);
                raw_write(regs_a[i], $urandom, resp, 4'b0000);
                raw_read(regs_a[i], v, resp);
            end
        end
    endtask
endclass

class reg_map_vseq extends dma_base_vseq;
    `uvm_object_utils(reg_map_vseq)
    function new(string name = "reg_map_vseq"); super.new(name); endfunction
    task body();
        uvm_reg_data_t v;
        bit resp;
        for (int off = 0; off < 40 * NCH; off += 4) begin
            if (NCH > 8 && $urandom_range(3) != 0) continue;
            for (int k = 1; k < 4; k++) begin
                raw_read(REG_BASE + off + k, v, resp, k == 2 ? 3'd1 : 3'd0);
                if ($urandom_range(1)) raw_write(REG_BASE + off + k, $urandom, resp, 4'b0001 << k, 3'd0);
            end
            raw_read(REG_BASE + off, v, resp, 3'd0);
            raw_read(REG_BASE + off, v, resp, 3'd1);
        end
        for (int off = 40 * NCH; off < 32'h1000; off += 4) begin
            raw_read(REG_BASE + off, v, resp);
            raw_write(REG_BASE + off, $urandom, resp);
        end
        raw_read(REG_BASE - 4, v, resp);
        raw_read(REG_BASE + 32'h1000, v, resp);
        raw_write(REG_BASE + 32'h1000, 0, resp);
        sweep();
    endtask
endclass

class reg_b2b_vseq extends dma_base_vseq;
    `uvm_object_utils(reg_b2b_vseq)
    function new(string name = "reg_b2b_vseq"); super.new(name); endfunction
    task body();
        uvm_sequence_item rsp;
        for (int round = 0; round < 8; round++) begin
            ahb_item items[$];
            for (int i = 0; i < 24; i++) begin
                ahb_item it = ahb_item::type_id::create("b2b");
                int ch = $urandom_range(NCH - 1);
                int kind = $urandom_range(9);
                it.write = $urandom_range(1);
                it.cancel_on_error = $urandom_range(1);
                case (kind)
                    0, 1, 2: it.addr = REG_BASE + 16 * ch + 4 * $urandom_range(1) * 4;
                    3:       it.addr = REG_BASE + 16 * ch + 4;
                    4, 5:    begin it.addr = REG_BASE + 16 * NCH + 16 * ch + 4 * $urandom_range(3); end
                    6:       begin it.addr = REG_BASE + 32 * NCH + 8 * ch; it.wdata[7] = 0; end
                    7:       it.addr = REG_BASE + 40 * NCH + 4 * $urandom_range(20);
                    8:       begin it.addr = REG_BASE + 16 * ch + 1; it.size = 0; it.strobe = 4'b0010; end
                    9:       begin it.addr = REG_BASE + 16 * ch; it.strobe = 4'b0011; end
                endcase
                it.wdata = $urandom;
                if (kind == 6) it.wdata[7] = 0;
                items.push_back(it);
            end
            foreach (items[i]) begin
                start_item(items[i], -1, env.cfg.sqr);
                finish_item(items[i]);
            end
            foreach (items[i]) get_response(rsp, items[i].get_transaction_id());
            cycles($urandom_range(3));
        end
        sweep();
    endtask
endclass

class reg_burst_vseq extends dma_base_vseq;
    `uvm_object_utils(reg_burst_vseq)
    function new(string name = "reg_burst_vseq"); super.new(name); endfunction

    function bit [31:0] beat_addr(bit [31:0] start, int b, int beats, bit wrap);
        bit [31:0] bytes = 4 * beats;
        if (!wrap) return start + 4 * b;
        return (start & ~(bytes - 1)) + ((start + 4 * b) & (bytes - 1));
    endfunction

    task body();
        uvm_sequence_item rsp;
        for (int hb = 1; hb < 8; hb++) begin
            int beats = (hb == 1) ? 3 : (4 << ((hb - 2) / 2));
            bit wrap = (hb inside {2, 4, 6});
            bit [31:0] start = REG_BASE + (wrap ? 8 : 0);   // a wrapping burst starts mid-block
            ahb_item items[$];
            for (int b = 0; b < beats; b++) begin
                ahb_item it = ahb_item::type_id::create("burst");
                it.write = 0; it.burst = hb;
                it.addr  = beat_addr(start, b, beats, wrap);
                it.trans = (b == 0) ? 2'b10 : 2'b11;
                if (b == 2) begin
                    ahb_item bz = ahb_item::type_id::create("busy");
                    bz.write = 0; bz.burst = hb; bz.trans = 2'b01; bz.addr = it.addr;
                    items.push_back(bz);
                end
                items.push_back(it);
            end
            foreach (items[i]) begin start_item(items[i], -1, env.cfg.sqr); finish_item(items[i]); end
            foreach (items[i]) get_response(rsp, items[i].get_transaction_id());
            cycles(2);
        end
    endtask
endclass

class oneshot_len_vseq extends dma_base_vseq;
    `uvm_object_utils(oneshot_len_vseq)
    function new(string name = "oneshot_len_vseq"); super.new(name); endfunction
    task body();
        int unsigned lens[$] = '{1, 2, 3, 4, 5, 15, 16, 17, 2 * FDEPTH + 1, 300};
        if ($test$plusargs("LONG")) lens.push_back(1000);
        foreach (lens[i]) begin
            dma_copy c = dma_copy::type_id::create("c");
            c.ch = i % NCH; c.len = lens[i];
            c.src_off = 4 * $urandom_range(1024); c.dst_off = 4 * $urandom_range(1024);
            copy_and_wait(c);
        end
    endtask
endclass

class size_step_vseq extends dma_base_vseq;
    `uvm_object_utils(size_step_vseq)
    function new(string name = "size_step_vseq"); super.new(name); endfunction
    task body();
        int n;
        for (int sz = 0; sz < 3; sz++) begin
            int unsigned b = 1 << sz;
            bit [7:0] steps[$] = '{0, b, 2 * b, 255 & ~(b - 1)};
            foreach (steps[i]) foreach (steps[j]) for (int al = 0; al < 4; al += b) begin
                dma_copy c = dma_copy::type_id::create("c");
                c.ch = n++ % NCH; c.size = sz; c.sincr = steps[i]; c.dincr = steps[j];
                c.len = $urandom_range(1, 6);
                c.src_off = 32'h100 * $urandom_range(64) + al;
                c.dst_off = 32'h100 * $urandom_range(64) + ((al + b * $urandom_range(3)) % 4);
                copy_and_wait(c);
            end
        end
    endtask
endclass

class pattern_vseq extends dma_base_vseq;
    `uvm_object_utils(pattern_vseq)
    function new(string name = "pattern_vseq"); super.new(name); endfunction
    task body();
        for (int pat = 0; pat < 6; pat++)
            for (int sz = 0; sz < 3; sz++) begin
                dma_copy c = dma_copy::type_id::create("c");
                c.ch = (pat + sz) % NCH; c.size = sz; c.sincr = 1 << sz; c.dincr = 1 << sz;
                c.len = (sz == 2) ? 32 : 32 * 4 / (1 << sz);
                copy_and_wait(c, pat);
            end
    endtask
endclass

class all_channels_vseq extends dma_base_vseq;
    `uvm_object_utils(all_channels_vseq)
    function new(string name = "all_channels_vseq"); super.new(name); endfunction
    task body();
        dma_copy cs[$];
        uvm_reg_data_t v;
        for (int round = 0; round < 3; round++) begin
            cs.delete();
            for (int ch = 0; ch < NCH; ch++) begin
                dma_copy c = dma_copy::type_id::create("c");
                c.randomize_copy(ch, 40, 0, 0);
                fill(c);
                cs.push_back(c);
            end
            foreach (cs[i]) begin
                wreg(regs.SOURCE[cs[i].ch], cs[i].src());
                wreg(regs.DESTINATION[cs[i].ch], cs[i].dst());
                wreg(regs.DESIRED_TRANSFERS[cs[i].ch], cs[i].len);
            end
            foreach (cs[i]) wreg(regs.CONTROL[cs[i].ch], cs[i].ctrl(1));
            for (int k = 0; k < 2 * NCH; k++) rreg(regs.CURRENT_CHANNEL_ACTIVE[$urandom_range(NCH - 1)], v);
            foreach (cs[i]) begin
                wait_done(cs[i].ch, v);
                clear(cs[i].ch);
            end
        end
        if (NCH > 2) begin
            int m = NCH / 2;
            dma_copy big = dma_copy::type_id::create("big");
            big.ch = m; big.len = 40 * NCH;
            fill(big);
            start_copy(big);
            cs.delete();
            for (int ch = 0; ch < NCH; ch++) if (ch != m) begin
                dma_copy c = dma_copy::type_id::create("c");
                c.ch = ch; c.len = 6;
                fill(c);
                cs.push_back(c);
                start_copy(c);
            end
            wait_done(m, v); clear(m);
            foreach (cs[i]) begin wait_done(cs[i].ch, v); clear(cs[i].ch); end
        end
        for (int ch = 0; ch < NCH; ch++) begin
            dma_copy c = dma_copy::type_id::create("c");
            c.ch = ch; c.len = 120;
            fill(c);
            start_copy(c);
            rreg(regs.CURRENT_CHANNEL_ACTIVE[ch], v);
            rreg(regs.CURRENT_CHANNEL_ACTIVE[ch], v);
            wait_done(ch, v);
            clear(ch);
        end
    endtask
endclass

class irq_vseq extends dma_base_vseq;
    `uvm_object_utils(irq_vseq)
    function new(string name = "irq_vseq"); super.new(name); endfunction
    task body();
        uvm_reg_data_t v;
        int n = (NCH < 3) ? NCH : 3;
        for (int round = 0; round < 4; round++) begin
            dma_copy cs[$];
            for (int i = 0; i < n; i++) begin
                dma_copy c = dma_copy::type_id::create("c");
                c.ch = (round + i) % NCH; c.len = 4 + 4 * i;
                fill(c);
                if (i == 1) env.rd_cfg.add_fault(c.src() + 4 * 2);
                cs.push_back(c);
                start_copy(c);
            end
            foreach (cs[i]) wait_done(cs[i].ch, v);
            if (NCH > n) wreg(regs.CONTROL[(round + n) % NCH], 32'h0800_0000);
            if (NCH > n + 1) wreg(regs.CONTROL[(round + n + 1) % NCH], 32'h0400_0000);
            cycles(4);
            if (round % 2) cs.reverse();
            foreach (cs[i]) begin clear(cs[i].ch); cycles($urandom_range(3)); end
            if (NCH > n)     clear((round + n) % NCH);
            if (NCH > n + 1) clear((round + n + 1) % NCH);
        end
        env.rd_cfg.clear_faults();
    endtask
endclass

class continuous_vseq extends dma_base_vseq;
    `uvm_object_utils(continuous_vseq)
    function new(string name = "continuous_vseq"); super.new(name); endfunction
    task body();
        int unsigned lens[$] = '{1, 4, 17};
        uvm_reg_data_t v;
        foreach (lens[i]) for (int ab = 0; ab < 2; ab++) begin
            dma_copy c = dma_copy::type_id::create("c");
            c.ch = (2 * i + ab) % NCH; c.mode = 1; c.len = lens[i]; c.size = $urandom_range(2);
            c.sincr = 1 << c.size; c.dincr = 1 << c.size;
            fill(c);
            start_copy(c);
            do begin
                cycles(20);
                rreg(regs.TRANSFERS_COMPLETED[c.ch], v);
                if ($urandom_range(1)) wreg(regs.CONTROL[c.ch], c.ctrl(1));
            end while (v < 5 * lens[i]);
            stop(c, ab);
            wait_quiet(40);
            rreg(regs.CONTROL[c.ch], v);
            clear(c.ch);
        end
    endtask
endclass

class ring_vseq extends dma_base_vseq;
    `uvm_object_utils(ring_vseq)
    function new(string name = "ring_vseq"); super.new(name); endfunction
    task body();
        uvm_reg_data_t v;
        int n;
        for (int rs = 0; rs < 8; rs++) for (int bs = 0; bs < 2; bs++) begin
            dma_copy c = dma_copy::type_id::create("c");
            int unsigned target = 3 * (1 << rs);
            c.ch = n++ % NCH; c.mode = 2; c.ring_size = rs; c.bsel = bs;
            c.size = $urandom_range(2);
            c.sincr = bs ? 3 * (1 << c.size) : (1 << c.size);
            c.dincr = bs ? (1 << c.size) : 3 * (1 << c.size);
            fill(c);
            start_copy(c);
            do begin
                cycles(4 * (1 << rs) + 10);
                rreg(regs.TRANSFERS_COMPLETED[c.ch], v);
            end while (v < target);
            stop(c, 0);
            wait_quiet(40);
            clear(c.ch);
        end
    endtask
endclass

class arb_mix_vseq extends dma_base_vseq;
    `uvm_object_utils(arb_mix_vseq)
    function new(string name = "arb_mix_vseq"); super.new(name); endfunction
    task body();
        uvm_reg_data_t v;
        dma_copy r = dma_copy::type_id::create("r");
        dma_copy o = dma_copy::type_id::create("o");
        dma_copy k = dma_copy::type_id::create("k");
        if (NCH < 2) return;
        r.ch = 0; r.mode = 2; r.ring_size = 3; r.bsel = 1;
        o.ch = NCH - 1; o.len = 40;
        fill(r); fill(o);
        start_copy(r);
        cycles(10);
        start_copy(o);
        wait_done(o.ch, v);
        clear(o.ch);
        stop(r, 0);
        wait_quiet(40);
        clear(r.ch);
        k.ch = 1 % NCH; k.mode = 1; k.len = 6;
        o.ch = (NCH > 2) ? 2 : 0; o.len = 8;
        fill(k); fill(o);
        start_copy(k);
        cycles(10);
        start_copy(o);
        cycles(200);
        rreg(regs.TRANSFERS_COMPLETED[o.ch], v);
        stop(k, 0);
        wait_done(o.ch, v);
        clear(o.ch);
        wait_quiet(40);
        clear(k.ch);
    endtask
endclass

class profile_vseq extends dma_base_vseq;
    `uvm_object_utils(profile_vseq)
    function new(string name = "profile_vseq"); super.new(name); endfunction
    function void set_profiles(int rp, int rn, int wp, int wn);
        env.rd_cfg.set_profile(dma_resp_cfg::profile_e'(rp), rn);
        env.wr_cfg.set_profile(dma_resp_cfg::profile_e'(wp), wn);
        `uvm_info("SEQ", $sformatf("profiles: read %s(%0d), write %s(%0d)", env.rd_cfg.profile.name(), rn,
                                   env.wr_cfg.profile.name(), wn), UVM_MEDIUM)
    endfunction
    function void zero_profiles();
        set_profiles(dma_resp_cfg::ZERO, 0, dma_resp_cfg::ZERO, 0);
    endfunction
endclass

class burst_vseq extends profile_vseq;
    `uvm_object_utils(burst_vseq)
    function new(string name = "burst_vseq"); super.new(name); endfunction
    task body();
        uvm_reg_data_t v;
        int profiles[5][2] = '{'{0, 0}, '{1, 1}, '{1, 3}, '{2, 8}, '{3, 0}};
        for (int rp = 0; rp < 5; rp++) for (int wp = 0; wp < 5; wp++) begin
            dma_copy a = dma_copy::type_id::create("a");
            dma_copy b = dma_copy::type_id::create("b");
            set_profiles(profiles[rp][0], profiles[rp][1], profiles[wp][0], profiles[wp][1]);
            a.ch = 0; a.len = 32 + $urandom_range(16);
            b.ch = NCH - 1; b.len = 24;
            case ($urandom_range(3))
                0: begin b.sincr = 8; b.dincr = 8; end
                1: begin b.size = 1; b.sincr = 2; b.dincr = 2; end
                2: begin b.size = 1; b.sincr = 4; b.dincr = 4; end
                3: ;
            endcase
            fill(a); fill(b);
            start_copy(a);
            if (NCH > 1) start_copy(b);
            wait_done(a.ch, v); clear(a.ch);
            if (NCH > 1) begin wait_done(b.ch, v); clear(b.ch); end
        end
        zero_profiles();
    endtask
endclass

class stall_vseq extends profile_vseq;
    `uvm_object_utils(stall_vseq)
    function new(string name = "stall_vseq"); super.new(name); endfunction
    task body();
        uvm_reg_data_t v;
        for (int round = 0; round < 10; round++) begin
            dma_copy cs[$];
            set_profiles($urandom_range(3), $urandom_range(1, 6), $urandom_range(3), $urandom_range(1, 6));
            for (int i = 0; i < ((NCH < 3) ? NCH : 3); i++) begin
                dma_copy c = dma_copy::type_id::create("c");
                c.randomize_copy((round + i) % NCH, 48, 0, 0);
                fill(c);
                start_copy(c);
                cs.push_back(c);
            end
            foreach (cs[i]) begin wait_done(cs[i].ch, v); clear(cs[i].ch); end
        end
        zero_profiles();
    endtask
endclass

class kb_cross_vseq extends profile_vseq;
    `uvm_object_utils(kb_cross_vseq)
    function new(string name = "kb_cross_vseq"); super.new(name); endfunction
    task body();
        uvm_reg_data_t v;
        bit [31:0] starts[3] = '{32'h3F4, 32'h3F8, 32'h3FC};
        foreach (starts[i]) for (int k = 0; k < 4; k++) begin
            dma_copy c = dma_copy::type_id::create("c");
            set_profiles(dma_resp_cfg::FIXED, 2, dma_resp_cfg::FIXED, 3);
            c.ch = k % NCH; c.len = 24;
            c.src_off = 32'h400 * (1 + k) + starts[i] - 4 * 4 * k;
            c.dst_off = 32'h400 * (1 + k) + starts[i];
            copy_and_wait(c);
        end
        zero_profiles();
    endtask
endclass

class bus_err_vseq extends profile_vseq;
    `uvm_object_utils(bus_err_vseq)
    bit on_write;
    function new(string name = "bus_err_vseq"); super.new(name); endfunction
    task body();
        uvm_reg_data_t v;
        int profiles[4][2] = '{'{0, 0}, '{1, 2}, '{2, 6}, '{3, 0}};
        for (int p = 0; p < 5; p++) begin
            int unsigned len = 24;
            int unsigned ks[$] = '{0, 1, len / 2 + $urandom_range(3), len - 1};
            if (p == 4) begin
                ks = '{4, 5, 6, 7, 9, 10, 11, 12};
                reset_dut();
                cycles(2);
            end
            foreach (ks[i]) begin
                dma_copy c = dma_copy::type_id::create("c");
                bit [31:0] fault;
                if (p == 4 && on_write) set_profiles(dma_resp_cfg::ZERO, 0, dma_resp_cfg::FIXED, 3);
                else if (p == 4)        set_profiles(dma_resp_cfg::FIXED, 3, dma_resp_cfg::ZERO, 0);
                else set_profiles(profiles[p][0], profiles[p][1], profiles[(p + 1) % 4][0], profiles[(p + 1) % 4][1]);
                c.ch = (p + i) % NCH; c.len = len;
                c.src_off = 32'h1000 * $urandom_range(15); c.dst_off = 32'h1000 * $urandom_range(15);
                fault = on_write ? c.dst() + 4 * ks[i] : c.src() + 4 * ks[i];
                if (on_write) env.wr_cfg.add_fault(fault); else env.rd_cfg.add_fault(fault);
                fill(c);
                start_copy(c);
                wait_done(c.ch, v);
                rreg(regs.ERROR_ADDRESS[c.ch], v);
                rreg(regs.TRANSFERS_COMPLETED[c.ch], v);
                wait_quiet(30);
                rreg(regs.CONTROL[c.ch], v);
                clear(c.ch);
                start_copy(c);
                rreg(regs.TRANSFERS_COMPLETED[c.ch], v);
                rreg(regs.ERROR_ADDRESS[c.ch], v);
                rreg(regs.TRANSFERS_REMAINING[c.ch], v);
                wait_done(c.ch, v);
                clear(c.ch);
            end
        end
        env.rd_cfg.clear_faults(); env.wr_cfg.clear_faults();
        zero_profiles();
    endtask
endclass

class err_isolation_vseq extends profile_vseq;
    `uvm_object_utils(err_isolation_vseq)
    function new(string name = "err_isolation_vseq"); super.new(name); endfunction
    task body();
        uvm_reg_data_t v;
        int n = (NCH < 4) ? NCH : 4;
        for (int round = 0; round < 6; round++) begin
            dma_copy cs[$];
            int nbad = (NCH < 2) ? 1 : $urandom_range(1, (n < 3) ? n - 1 : 3);
            set_profiles($urandom_range(2), 2, $urandom_range(2), 2);
            for (int i = 0; i < n; i++) begin
                dma_copy c = dma_copy::type_id::create("c");
                c.randomize_copy((round + i) % NCH, 40, 0, 0);
                c.size = 2; c.sincr = 4; c.dincr = 4; c.len = 16 + $urandom_range(24);
                c.src_off &= ~3; c.dst_off &= ~3;
                if (i < nbad) begin
                    if ($urandom_range(1)) env.rd_cfg.add_fault(c.src() + 4 * $urandom_range(c.len - 1));
                    else                   env.wr_cfg.add_fault(c.dst() + 4 * $urandom_range(c.len - 1));
                end
                fill(c);
                cs.push_back(c);
            end
            foreach (cs[i]) start_copy(cs[i]);
            foreach (cs[i]) begin wait_done(cs[i].ch, v); clear(cs[i].ch); end
            wait_quiet(30);
            env.rd_cfg.clear_faults(); env.wr_cfg.clear_faults();
        end
        zero_profiles();
    endtask
endclass

class stop_vseq extends profile_vseq;
    `uvm_object_utils(stop_vseq)
    bit do_abort = 1;
    function new(string name = "stop_vseq"); super.new(name); endfunction
    task body();
        uvm_reg_data_t v;
        int n;
        for (int mode = 0; mode < 3; mode++) for (int phase = 0; phase < 4; phase++) begin
            dma_copy c = dma_copy::type_id::create("c");
            if (mode != 0 && phase == 2) continue;
            set_profiles($urandom_range(2), 2, $urandom_range(2), 2);
            c.randomize_copy(n++ % NCH, 48, 0, 0);
            c.mode = mode; c.len = 24 + $urandom_range(24); c.ring_size = 4; c.bsel = $urandom_range(1);
            if (mode == 2 && c.dincr == 0) c.dincr = 1 << c.size;
            fill(c);
            start_copy(c);
            case (phase)
                0: ;
                1: cycles(4 * c.len / 3 + $urandom_range(10));
                2: do rreg(regs.CONTROL[c.ch], v); while (v[7]);
                3: begin
                       wait_done(c.ch, v);
                       if (mode == 0) cycles(2);
                   end
            endcase
            stop(c, do_abort);
            rreg(regs.CONTROL[c.ch], v);
            rreg(regs.CONTROL[c.ch], v);
            wait_drained(c.ch);
            c.src_off ^= 32'h8000; c.dst_off ^= 32'h8000;
            fill(c);
            clear(c.ch);
            start_copy(c);
            if (mode == 0) wait_done(c.ch, v);
            else begin
                wait_done(c.ch, v);
                stop(c, $urandom_range(1));
            end
            wait_quiet(50);
            clear(c.ch);
        end
        zero_profiles();
    endtask
endclass

class restart_race_vseq extends profile_vseq;
    `uvm_object_utils(restart_race_vseq)
    bit do_abort = 1;
    function new(string name = "restart_race_vseq"); super.new(name); endfunction
    task body();
        uvm_reg_data_t v;
        for (int i = 0; i < 4; i++) begin
            dma_copy c = dma_copy::type_id::create("c");
            set_profiles(dma_resp_cfg::ZERO, 0, dma_resp_cfg::FIXED, 3);
            c.ch = i % NCH; c.len = 24;
            fill(c);
            start_copy(c);
            do rreg(regs.CONTROL[c.ch], v); while (v[7]);
            stop(c, i % 2);
            clear(c.ch);
            c.src_off += 32'h1000; c.dst_off += 32'h1000;
            fill(c);
            start_copy(c);
            wait_done(c.ch, v);
            wait_quiet(50);
            rreg(regs.TRANSFERS_COMPLETED[c.ch], v);
            clear(c.ch);
        end
        zero_profiles();
    endtask
endclass

class perf_vseq extends profile_vseq;
    `uvm_object_utils(perf_vseq)
    function new(string name = "perf_vseq"); super.new(name); endfunction
    task body();
        uvm_reg_data_t v;
        longint t0, t1;
        dma_copy big = dma_copy::type_id::create("big");
        zero_profiles();
        big.ch = 0; big.len = 64;
        copy_and_wait(big);
        t0 = env.scb.copy_time(0);
        if (FDEPTH >= 8) env.scb.check_copy_time(0);
        for (int i = 0; i < 20; i++) begin
            dma_copy k = dma_copy::type_id::create("k");
            k.ch = 1 % NCH; k.len = 8; k.src_off = 32'h100 * i; k.dst_off = 32'h100 * i;
            env.wr_cfg.add_fault(k.dst() + 4 * 2);
            fill(k);
            start_copy(k);
            wait_done(k.ch, v);
            wait_drained(k.ch);
            clear(k.ch);
        end
        big.src_off = 32'h1_0000;
        copy_and_wait(big);
        t1 = env.scb.copy_time(0);
        if (FDEPTH >= 8) env.scb.check_copy_time(0);
        if (t1 > t0)
            `uvm_error("PERF", $sformatf("64-word copy took %0d cycles after 20 write errors, %0d before  [R25]", t1, t0))
    endtask
endclass

class rewrite_vseq extends dma_base_vseq;
    `uvm_object_utils(rewrite_vseq)
    function new(string name = "rewrite_vseq"); super.new(name); endfunction
    task body();
        uvm_reg_data_t v;
        for (int i = 0; i < 6; i++) begin
            dma_copy c = dma_copy::type_id::create("c");
            dma_copy c2;
            c.ch = i % NCH; c.mode = (i % 3 == 2) ? 1 : 0; c.len = 64;
            fill(c);
            c2 = dma_copy::type_id::create("c2");
            c2.copy_from(c);
            case (i % 2)
                0: begin c2.sincr = 8; c2.dincr = 8; end
                1: begin c2.size = 1; end
            endcase
            fill(c2);
            start_copy(c);
            cycles(15 + $urandom_range(20));
            rreg(regs.TRANSFERS_COMPLETED[c.ch], v);
            wreg(regs.CONTROL[c.ch], c2.ctrl(1));
            rreg(regs.TRANSFERS_COMPLETED[c.ch], v);
            if (c.mode == 0) wait_done(c.ch, v);
            else begin cycles(300); stop(c2, 0); end
            wait_quiet(50);
            clear(c.ch);
        end
    endtask
endclass

class reset_mid_vseq extends profile_vseq;
    `uvm_object_utils(reset_mid_vseq)
    function new(string name = "reset_mid_vseq"); super.new(name); endfunction
    task body();
        uvm_reg_data_t v;
        for (int kind = 0; kind < 3; kind++) for (int rep = 0; rep < 3; rep++) begin
            dma_copy a = dma_copy::type_id::create("a");
            dma_copy b = dma_copy::type_id::create("b");
            if (kind == 1) set_profiles(dma_resp_cfg::FIXED, 2, dma_resp_cfg::FIXED, 3);
            a.ch = 0; a.len = 48; a.src_off = 32'h1000 * rep;
            b.ch = NCH - 1; b.mode = (rep == 2) ? 2 : 0; b.ring_size = 3; b.len = 30; b.dst_off = 32'h1000 * rep;
            fill(a); fill(b);
            if (kind == 2) env.rd_cfg.add_fault(a.src() + 4 * 6);
            start_copy(a);
            if (NCH > 1) start_copy(b);
            if (rep == 1) begin
                do rreg(regs.CONTROL[a.ch], v); while (v[7]);
            end else cycles(10 + $urandom_range(30));
            reset_dut($urandom_range(1, 3), $urandom_range(20, 80));
            env.rd_cfg.clear_faults();
            zero_profiles();
            cycles(2);
            rreg(regs.CONTROL[0], v);
            a.src_off += 32'h400;
            copy_and_wait(a);
        end
        sweep();
    endtask
endclass

class bad_cfg_vseq extends dma_base_vseq;
    `uvm_object_utils(bad_cfg_vseq)
    function new(string name = "bad_cfg_vseq"); super.new(name); endfunction
    task body();
        uvm_reg_data_t v;
        for (int m = 3; m <= 8; m++) begin
            dma_copy c = dma_copy::type_id::create("c");
            c.ch = m % NCH;
            if (m == 8) begin c.mode = 0; c.len = 0; end
            else        begin c.mode = m; c.len = 8; end
            c.size = m % 3; c.sincr = 1 << c.size; c.dincr = 1 << c.size;
            start_copy(c);
            wait_done(c.ch, v);
            rreg(regs.TRANSFERS_COMPLETED[c.ch], v);
            clear(c.ch);
        end
    endtask
endclass

function automatic bit [31:0] tcfg_val(bit [7:0] count, bit arm, int line);
    return {8'h00, count, 8'h00, arm, 2'b00, 5'(line)};
endfunction

class trig_pace_vseq extends dma_base_vseq;
    `uvm_object_utils(trig_pace_vseq)
    function new(string name = "trig_pace_vseq"); super.new(name); endfunction
    task body();
        uvm_reg_data_t v;
        bit [7:0] counts[4] = '{0, 1, 3, 255};
        foreach (counts[i]) begin
            dma_copy c = dma_copy::type_id::create("c");
            int line = $urandom_range(NSRC - 1);
            c.ch = (i + 1) % NCH; c.mode = 2; c.ring_size = 4; c.bsel = 1;
            c.size = $urandom_range(2); c.sincr = 0; c.dincr = 1 << c.size;
            fill(c);
            wreg(regs.TRIGGER_CONFIG[c.ch], tcfg_val(counts[i], 1, line));
            start_copy(c);
            repeat (6) begin
                pulse(NSRC'(1) << line, $urandom_range(1, 6), $urandom_range(1, 40));
                if ($urandom_range(1)) pulse(NSRC'(1) << ((line + 1) % NSRC), 2, 2);
            end
            wait_quiet(60);
            env.scb.settle();
            rreg(regs.TRIGGER_STATUS[c.ch], v);
            rreg(regs.TRANSFERS_COMPLETED[c.ch], v);
            stop(c, 0);
            wait_quiet(40);
            wreg(regs.TRIGGER_CONFIG[c.ch], tcfg_val(1, 0, 0));
            clear(c.ch);
        end
    endtask
endclass

class trig_credit_vseq extends dma_base_vseq;
    `uvm_object_utils(trig_credit_vseq)
    function new(string name = "trig_credit_vseq"); super.new(name); endfunction
    task body();
        uvm_reg_data_t v;
        int ch = 0, line = 7 % NSRC;
        bit resp;
        wreg(regs.TRIGGER_CONFIG[ch], tcfg_val(255, 1, line));
        repeat (18) pulse(NSRC'(1) << line, 1, 2);
        cycles(3);
        rreg(regs.TRIGGER_STATUS[ch], v);
        raw_write(REG_BASE + 32 * NCH + 8 * ch + 4, 32'hFFFF_FFFF, resp);
        rreg(regs.TRIGGER_STATUS[ch], v);
        wreg(regs.TRIGGER_CONFIG[ch], tcfg_val(255, 0, line));
        rreg(regs.TRIGGER_STATUS[ch], v);
        wreg(regs.TRIGGER_CONFIG[ch], tcfg_val(5, 1, line));
        rreg(regs.TRIGGER_STATUS[ch], v);
        repeat (3) pulse(NSRC'(1) << line, 1, 1);
        cycles(2);
        rreg(regs.TRIGGER_STATUS[ch], v);
        wreg(regs.TRIGGER_CONFIG[ch], tcfg_val(1, 0, 0));
        rreg(regs.TRIGGER_STATUS[ch], v);
        wreg(regs.TRIGGER_CONFIG[ch], tcfg_val(1, 1, line));
        repeat (2) pulse(NSRC'(1) << line, 1, 1);
        cycles(2);
        rreg(regs.TRIGGER_STATUS[ch], v);
        wreg(regs.TRIGGER_CONFIG[ch], tcfg_val(1, 0, 0));
    endtask
endclass

class trig_burst_vseq extends profile_vseq;
    `uvm_object_utils(trig_burst_vseq)
    function new(string name = "trig_burst_vseq"); super.new(name); endfunction
    task body();
        uvm_reg_data_t v;
        dma_copy c = dma_copy::type_id::create("c");
        int line = 3;
        set_profiles(dma_resp_cfg::FIXED, 2, dma_resp_cfg::ZERO, 0);
        c.ch = NCH - 1; c.mode = 2; c.ring_size = 7; c.bsel = 0;
        fill(c);
        wreg(regs.TRIGGER_CONFIG[c.ch], tcfg_val(255, 1, line));
        start_copy(c);
        pulse(NSRC'(1) << line, 1, 1);
        wait_quiet(60);
        env.scb.settle();
        rreg(regs.TRIGGER_STATUS[c.ch], v);
        rreg(regs.TRANSFERS_COMPLETED[c.ch], v);
        stop(c, 0);
        wait_quiet(40);
        wreg(regs.TRIGGER_CONFIG[c.ch], tcfg_val(1, 0, 0));
        clear(c.ch);
        zero_profiles();
    endtask
endclass

class armed_nonring_vseq extends dma_base_vseq;
    `uvm_object_utils(armed_nonring_vseq)
    function new(string name = "armed_nonring_vseq"); super.new(name); endfunction
    task body();
        uvm_reg_data_t v;
        for (int mode = 0; mode < 2; mode++) begin
            dma_copy c = dma_copy::type_id::create("c");
            c.ch = mode % NCH; c.mode = mode; c.len = 12;
            fill(c);
            wreg(regs.TRIGGER_CONFIG[c.ch], tcfg_val(4, 1, 2));
            start_copy(c);
            pulse(NSRC'(1) << 2, 1, 1);
            cycles(80);
            rreg(regs.CONTROL[c.ch], v);
            rreg(regs.TRANSFERS_COMPLETED[c.ch], v);
            wreg(regs.TRIGGER_CONFIG[c.ch], tcfg_val(1, 0, 0));
            start_copy(c);
            if (mode == 0) wait_done(c.ch, v);
            else begin wait_done(c.ch, v); stop(c, 0); end
            wait_quiet(40);
            clear(c.ch);
        end
    endtask
endclass

class corner_vseq extends dma_base_vseq;
    `uvm_object_utils(corner_vseq)
    function new(string name = "corner_vseq"); super.new(name); endfunction
    task body();
        uvm_reg_data_t v;
        dma_copy c = dma_copy::type_id::create("c");
        c.ch = 0; c.size = 3; c.len = 8;
        copy_and_wait(c);
        c = dma_copy::type_id::create("c");
        c.ch = 1 % NCH; c.mode = 1; c.len = 0;
        fill(c);
        start_copy(c);
        cycles(150);
        rreg(regs.TRANSFERS_COMPLETED[c.ch], v);
        stop(c, 0);
        wait_quiet(40);
        clear(c.ch);
        for (int mode = 1; mode <= 2; mode++) begin
            c = dma_copy::type_id::create("c");
            c.ch = 2 % NCH; c.mode = mode; c.len = 2; c.ring_size = 1; c.bsel = 1;
            fill(c);
            start_copy(c);
            for (int k = 0; k < 60; k++) begin
                cycles(k % 7);
                wreg(regs.CONTROL[c.ch], c.ctrl(1));
            end
            stop(c, 0);
            wait_quiet(40);
            clear(c.ch);
        end
        for (int k = 0; k < 4; k++) begin
            dma_copy bad = dma_copy::type_id::create("bad");
            c = dma_copy::type_id::create("c");
            c.ch = 4 % NCH; c.mode = 1; c.len = 16;
            fill(c);
            start_copy(c);
            cycles(20 + 7 * k);
            bad.copy_from(c);
            bad.size = 3;
            wreg(regs.CONTROL[c.ch], bad.ctrl(1));
            wait_done(c.ch, v);
            wait_quiet(40);
            clear(c.ch);
        end
        for (int k = 0; k < 40; k++) begin
            c = dma_copy::type_id::create("c");
            c.ch = 3 % NCH; c.len = 4;
            fill(c);
            start_copy(c);
            cycles(k);
            wreg(regs.CONTROL[c.ch], c.ctrl(1));
            wait_quiet(30);
            env.scb.settle();
            rreg(regs.CONTROL[c.ch], v);
            clear(c.ch);
        end
    endtask
endclass

class rand_vseq extends profile_vseq;
    `uvm_object_utils(rand_vseq)

    bit with_errors, with_stops, with_regs;
    int unsigned budget = 20000;
    bit stop_all;
    int reserved = -1;   // channel reserved for register traffic

    typedef enum {IDLE, BUSY, STOPPED} st_e;
    st_e     st[NCH];
    dma_copy cur[NCH];
    longint  t_start[NCH], t_stop[NCH];
    int unsigned n_started, n_stopped, n_resets;

    function new(string name = "rand_vseq"); super.new(name); endfunction

    task body();
        rand_reg_vseq rr;
        void'($value$plusargs("CYCLES=%d", budget));
        if (with_regs && NCH > 1) reserved = NCH - 1;
        foreach (st[c]) st[c] = IDLE;
        if (with_errors) begin
            env.rd_cfg.err_permille = $urandom_range(1, 20);
            env.wr_cfg.err_permille = $urandom_range(1, 20);
            env.rd_cfg.err_lo = SRC_AREA; env.rd_cfg.err_hi = SRC_AREA + NCH * AREA_SIZE - 1;
            env.wr_cfg.err_lo = DST_AREA; env.wr_cfg.err_hi = DST_AREA + NCH * AREA_SIZE - 1;
        end
        if (with_regs) begin
            rr = rand_reg_vseq::type_id::create("regs_thread");
            rr.env = env; rr.regs = regs; rr.reserved = reserved; rr.owner = this;
        end
        fork
            if (with_regs) rr.start(null, this);
            mix();
        join
        env.rd_cfg.clear_faults(); env.wr_cfg.clear_faults();
        zero_profiles();
        `uvm_info("RAND", $sformatf("%0d copies started, %0d stopped early, %0d resets", n_started, n_stopped, n_resets), UVM_LOW)
    endtask

    task mix();
        longint t0 = edge_now();
        uvm_reg_data_t v;
        while (edge_now() - t0 < budget) begin
            if ($urandom_range(99) < 3) set_profiles($urandom_range(3), $urandom_range(1, 6), $urandom_range(3), $urandom_range(1, 6));
            if (with_stops && $urandom_range(999) < 4) begin
                reset_dut($urandom_range(1, 3), $urandom_range(20, 80));
                n_resets++;
                foreach (st[c]) st[c] = IDLE;
                cycles(2);
            end
            for (int c = 0; c < NCH; c++) begin
                if (c == reserved) continue;
                case (st[c])
                    IDLE: if ($urandom_range(99) < 15) start_one(c);
                    BUSY: service(c);
                    STOPPED: if (env.scb.drained(c)) begin clear(c); st[c] = IDLE; end
                endcase
            end
            cycles($urandom_range(5, 25));
        end
        for (int c = 0; c < NCH; c++) if (st[c] == BUSY && cur[c].mode != 0) stop(cur[c], 0);
        for (int c = 0; c < NCH; c++) if (st[c] == BUSY && cur[c].mode == 0) wait_done(c, v);
        stop_all = 1;
        wait_quiet(60);
        for (int c = 0; c < NCH; c++) if (c != reserved) clear(c);
    endtask

    task start_one(int c);
        dma_copy x = dma_copy::type_id::create("x");
        x.randomize_copy(c, 80, 1, 1);
        if (x.mode == 2 && x.dincr == 0) x.dincr = 1 << x.size;
        fill(x);
        cur[c] = x;
        start_copy(x);
        st[c] = BUSY;
        t_start[c] = edge_now();
        n_started++;
    endtask

    task service(int c);
        uvm_reg_data_t v;
        dma_copy x = cur[c];
        longint age = edge_now() - t_start[c];
        if (x.mode != 0 && age > (x.mode == 1 ? 150 : 600)) begin
            stop(x, $urandom_range(1)); st[c] = STOPPED; t_stop[c] = edge_now(); n_stopped++;
            return;
        end
        if (with_stops && x.mode == 0 && $urandom_range(99) < 2) begin
            stop(x, $urandom_range(1)); st[c] = STOPPED; t_stop[c] = edge_now(); n_stopped++;
            return;
        end
        if (!env.sys.drv.vif.dma_interrupt && age < 20000) return;
        rreg(regs.CONTROL[c], v);
        if (v[26]) begin
            st[c] = STOPPED; t_stop[c] = edge_now();
        end else if (v[27] && x.mode == 0) begin
            clear(c); st[c] = IDLE;
        end else if (v[27]) begin
            wreg(regs.CONTROL[c], x.ctrl(1));
        end else if (age >= 20000) begin
            `uvm_error("RAND", $sformatf("ch%0d: copy still running after %0d cycles: %s", c, age, x.convert2string()))
            st[c] = STOPPED; t_stop[c] = edge_now();
        end
    endtask
endclass

class rand_reg_vseq extends dma_base_vseq;
    `uvm_object_utils(rand_reg_vseq)
    int       reserved = -1;
    rand_vseq owner;
    function new(string name = "rand_reg_vseq"); super.new(name); endfunction
    task body();
        uvm_reg_data_t v;
        bit [31:0] d;
        bit resp;
        while (!owner.stop_all) begin
            int ch = $urandom_range(NCH - 1);
            case ($urandom_range(7))
                0, 1: raw_read(REG_BASE + 4 * $urandom_range(10 * NCH - 1), d, resp);
                2:    raw_write(REG_BASE + 16 * ch + 4 * $urandom_range(3), $urandom, resp, 4'(1 + $urandom_range(13)));
                3:    raw_read(REG_BASE + 4 * $urandom_range(10 * NCH - 1) + $urandom_range(1, 3), d, resp, 3'd0);
                4:    if ($urandom_range(1)) raw_write(REG_BASE + 40 * NCH + 4 * $urandom_range(100), $urandom, resp);
                      else                   raw_read(REG_BASE + 40 * NCH + 4 * $urandom_range(100), d, resp);
                5:    raw_write(REG_BASE + 16 * NCH + 16 * ch + 4 * $urandom_range(3), $urandom, resp);
                6:    if (reserved >= 0) begin
                          wreg(regs.SOURCE[reserved], SRC_AREA + reserved * AREA_SIZE + 4 * $urandom_range(1000));
                          wreg(regs.DESIRED_TRANSFERS[reserved], $urandom);
                          wreg(regs.TRIGGER_CONFIG[reserved], tcfg_val($urandom, 0, $urandom_range(31)));
                      end
                7:    raw_read(REG_BASE + 32 * NCH + 8 * ch + 4 * $urandom_range(1), d, resp);
            endcase
            cycles($urandom_range(0, 8));
        end
    endtask
endclass
