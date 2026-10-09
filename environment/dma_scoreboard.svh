// File:        dma_scoreboard.svh
// Author:      Isaac Hagedorn
// Date:        2026-10-08
// Description: Reference model and checker for the DMA. Predicts every memory transfer, register read and interrupt from the spec.

`uvm_analysis_imp_decl(_cfg)
`uvm_analysis_imp_decl(_rd)
`uvm_analysis_imp_decl(_wr)
`uvm_analysis_imp_decl(_sys)

class dma_chan;
    int        ch;
    bit [31:0] src, dst, len, ctrl_sw, tcfg;
    dma_hwval  enable, done, error, abort, err_addr;
    longint    completed;   // writes of the current run that completed
    bit        running;   // run_active
    longint    running_until;   // edge after which run_active clears
    dma_run    runs[$];
    dma_run    cur;   // latest run
    int        n_runs;
    longint    credit_hi, credit_lo;
    dma_hwval  overrun;
    longint    armed_grants, armed_reads;
    longint    n_rd_checked, n_wr_checked;

    function new(int c);
        ch = c;
        reset();
    endfunction

    function void reset();
        src = 0; dst = 0; len = 0; ctrl_sw = 0; tcfg = 32'h0001_0000;
        enable = new(0); done = new(0); error = new(0); abort = new(0); err_addr = new(0);
        overrun = new(0);
        completed = 0; running = 0; running_until = dma_hwval::MAXT;
        runs.delete(); cur = null;
        credit_hi = 0; credit_lo = 0; armed_grants = 0; armed_reads = 0;
    endfunction

    function bit running_at(longint W);
        return running && W <= running_until;
    endfunction

    function void end_running(longint last);
        running_until = last;
    endfunction

    function bit armed();        return tcfg[7];                endfunction
    function int sel();          return tcfg[$clog2(NSRC)-1:0]; endfunction
    function bit [7:0] count();  return tcfg[23:16];            endfunction

    function bit [31:0] remaining();
        bit [31:0] L;
        if (cur == null) return 0;
        L = cur.pass_len();
        if (cur.cfg.mode == 0) return L - completed;
        if (L == 0) return 0;
        return L - (completed % L);
    endfunction
endclass

class dma_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(dma_scoreboard)

    uvm_analysis_imp_cfg #(ahb_item, dma_scoreboard) cfg_imp;
    uvm_analysis_imp_rd  #(ahb_item, dma_scoreboard) rd_imp;
    uvm_analysis_imp_wr  #(ahb_item, dma_scoreboard) wr_imp;
    uvm_analysis_imp_sys #(sys_obs,  dma_scoreboard) sys_imp;

    sys_vif      vif;
    dma_mem      mem;
    dma_coverage cov;

    dma_chan     chans[NCH];
    ahb_item     q_cfg[$], q_rd[$], q_wr[$];
    sys_obs      q_sys[$];
    bit [7:0]    exp_mem[bit [31:0]];
    bit          in_reset = 1, seen_reset;
    int          last_rd_ch = -1;
    dma_run      last_rd_run;   // the run the previous read belonged to
    longint      last_mem_edge;   // last completed memory transfer (either port)
    int          slack = 0;   // +SCB_SLACK: widen timing windows
    bit          trace;   // +SCB_TRACE
    bit          irq_last;
    dma_infl_t   infl[$];   // items in a write data phase when their channel was dropped
    ahb_item     prev_rd;   // previous read on the read port

    int unsigned n_reg_reads, n_reg_writes, n_rd, n_wr, n_irq_checks, n_errors_seen,
                 n_null_wr, n_shadow, n_dead_rd, n_landed, n_runs, n_mismatch;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        cfg_imp = new("cfg_imp", this);
        rd_imp  = new("rd_imp", this);
        wr_imp  = new("wr_imp", this);
        sys_imp = new("sys_imp", this);
        foreach (chans[c]) chans[c] = new(c);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(sys_vif)::get(this, "", "vif", vif))
            `uvm_fatal("NOVIF", "dma_scoreboard: no virtual interface")
        void'($value$plusargs("SCB_SLACK=%d", slack));
        trace = $test$plusargs("SCB_TRACE");
    endfunction

    function void write_cfg(ahb_item t); q_cfg.push_back(t); endfunction
    function void write_rd(ahb_item t);  q_rd.push_back(t);  endfunction
    function void write_wr(ahb_item t);  q_wr.push_back(t);  endfunction
    function void write_sys(sys_obs t);  q_sys.push_back(t); endfunction

    function void tr(longint T, string msg);
        if (trace) $display("[SCB_TRACE] edge %0d: %s", T, msg);
    endfunction

    function void err(string id, string msg);
        n_mismatch++;
        `uvm_error(id, msg)
    endfunction

    task run_phase(uvm_phase phase);
        forever begin
            @(posedge vif.CLK);
            #0.5ns;
            process_edge(edge_now());
        end
    endtask

    function void process_edge(longint T);
        sys_obs  s, edge_obs;
        ahb_item it;
        ahb_item reads[$], writes[$], rds[$], wrs[$];

        while (q_sys.size()) begin
            s = q_sys.pop_front();
            if (s.kind == sys_obs::RESET) do_reset();
            else edge_obs = s;
        end
        if (edge_obs == null) return;
        if (!edge_obs.nRST) begin
            in_reset = 1;
            q_cfg.delete(); q_rd.delete(); q_wr.delete();
            return;
        end
        in_reset = 0;
        if (!seen_reset) begin
            q_cfg.delete(); q_rd.delete(); q_wr.delete();
            return;
        end

        foreach (q_cfg[i]) if (q_cfg[i].trans != 2'b01) begin
            if (q_cfg[i].write) writes.push_back(q_cfg[i]); else reads.push_back(q_cfg[i]);
        end
        q_cfg.delete();
        foreach (q_rd[i]) if (!q_rd[i].aphase_only) rds.push_back(q_rd[i]);
        foreach (q_wr[i]) if (!q_wr[i].aphase_only) wrs.push_back(q_wr[i]);
        q_rd.delete(); q_wr.delete();

        foreach (reads[i]) reg_read(reads[i]);
        check_irq(T, edge_obs.irq);
        if (trace) begin
            foreach (rds[i]) tr(T, {"bus ", rds[i].convert2string()});
            foreach (wrs[i]) tr(T, {"bus ", wrs[i].convert2string()});
        end
        foreach (wrs[i]) if (!wrs[i].resp) mem_write(wrs[i]);
        foreach (rds[i]) if (!rds[i].resp) mem_read(rds[i]);
        foreach (wrs[i]) if (wrs[i].resp)  mem_error(wrs[i]);
        foreach (rds[i]) if (rds[i].resp)  mem_error(rds[i]);
        foreach (rds[i]) if (rds[i].cyc > last_mem_edge) last_mem_edge = rds[i].cyc;
        foreach (wrs[i]) if (wrs[i].cyc > last_mem_edge) last_mem_edge = wrs[i].cyc;
        foreach (chans[c]) foreach (chans[c].runs[i]) begin
            dma_run x = chans[c].runs[i];
            if (x.state == dma_run::STOPPED && T - ((last_mem_edge > x.end_edge) ? last_mem_edge : x.end_edge) > 40)
                x.rd_closed = 1;
        end
        trigger_edges(T, edge_obs.rise);
        foreach (writes[i]) reg_write(writes[i]);
        if (cov != null) cov.sample_edge(this, T, edge_obs.irq);
    endfunction

    function void do_reset();
        if (cov != null) cov.sample_reset(this);
        foreach (chans[c]) begin
            foreach (chans[c].runs[r]) note_stop(chans[c].runs[r], "reset");
            chans[c].reset();
        end
        last_rd_ch = -1;
        last_rd_run = null;
        infl.delete();
        prev_rd = null;
        seen_reset = 1;
        in_reset   = 1;
    endfunction

    function void check_irq(longint T, bit irq);
        bit must = 0, may = 0;
        foreach (chans[c]) begin
            dma_chan h = chans[c];
            bit d1 = h.done.may_be(T, 1), d0 = h.done.may_be(T, 0);
            bit e1 = h.error.may_be(T, 1), e0 = h.error.may_be(T, 0);
            if (d1 || e1) may = 1;
            if ((d1 && !d0) || (e1 && !e0)) must = 1;
        end
        n_irq_checks++;
        if (irq != irq_last) tr(T, $sformatf("dma_interrupt -> %0d", irq));
        irq_last = irq;
        if (irq && !may)
            err("IRQ", $sformatf("edge %0d: dma_interrupt is 1 but no channel can have DONE or ERROR set  [R12]%s", T, irq_state()));
        if (!irq && must)
            err("IRQ", $sformatf("edge %0d: dma_interrupt is 0 but a channel has DONE or ERROR set  [R12]%s", T, irq_state()));
    endfunction

    function string irq_state();
        string s;
        foreach (chans[c]) if (chans[c].runs.size() || chans[c].done.cur || chans[c].error.cur)
            s = {s, $sformatf("\n    ch%0d DONE %s ERROR %s; %s", c, chans[c].done.str(), chans[c].error.str(),
                              chans[c].cur == null ? "no run" : chans[c].cur.str())};
        return s;
    endfunction

    function void reg_read(ahb_item t);
        int ch;
        reg_kind_e k = decode_reg(t.addr, ch);
        dma_chan h;
        bit [31:0] v = t.rdata;
        longint T = t.cyc;
        n_reg_reads++;
        tr(T, $sformatf("read  %s ch%0d = %h%s", k.name(), ch, v, t.resp ? " ERROR" : ""));
        if (cov != null) cov.sample_reg(t, k, ch);
        if (k == R_UNMAPPED) begin
            if (!t.resp) err("REG", $sformatf("read of unmapped or unaligned address %h returned OKAY, expected ERROR  [R02]", t.addr));
            return;
        end
        if (t.resp) begin
            err("REG", $sformatf("read of %s ch%0d (%h) returned ERROR  [R01]", k.name(), ch, t.addr));
            return;
        end
        h = chans[ch];
        case (k)
            R_SOURCE:      expect_eq(t, k, ch, v, h.src);
            R_DESTINATION: expect_eq(t, k, ch, v, h.dst);
            R_DESIRED:     expect_eq(t, k, ch, v, h.len);
            R_TCFG:        expect_eq(t, k, ch, v, h.tcfg);
            R_COMPLETED:   expect_eq(t, k, ch, v, 32'(h.completed), "R22");
            R_REMAINING:   expect_eq(t, k, ch, v, h.remaining(), "R22");
            R_ERRADDR: begin
                if (!h.err_addr.may_be(T, v))
                    err("REG", $sformatf("ch%0d ERROR_ADDRESS read %h, model %s  [R13 R22]", ch, v, h.err_addr.str()));
                h.err_addr.observe(T, v);
            end
            R_ACTIVE: begin
                bit [31:0] one = (ch < 32) ? (32'd1 << ch) : 0;
                if (v != 0 && v != one)
                    err("REG", $sformatf("ch%0d CURRENT_CHANNEL_ACTIVE read %h, expected 0 or %h  [R23]", ch, v, one));
                if (cov != null && v != 0) cov.sample_active(ch);
            end
            R_CONTROL:     check_control(t, h, v);
            R_TSTAT:       check_tstat(t, h, v);
        endcase
    endfunction

    function void expect_eq(ahb_item t, reg_kind_e k, int ch, bit [31:0] v, bit [31:0] e, string req = "R01");
        if (v != e) err("REG", $sformatf("ch%0d %s read %h, expected %h  [%s] (%s)", ch, k.name(), v, e, req,
                                         t.convert2string()));
    endfunction

    function void check_control(ahb_item t, dma_chan h, bit [31:0] v);
        bit [31:0] hw_mask = 32'h0C00_0080 | 32'h0100_0000;   // DONE, ERROR, ENABLE, ABORT
        longint T = t.cyc;
        string bad;
        if ((v & ~hw_mask) != (h.ctrl_sw & ~hw_mask))
            bad = {bad, $sformatf(" fields %h (expected %h)", v & ~hw_mask, h.ctrl_sw & ~hw_mask)};
        if (!h.enable.may_be(T, v[7]))  bad = {bad, $sformatf(" ENABLE=%0d (model %s)", v[7], h.enable.str())};
        if (!h.abort.may_be(T, v[24]))  bad = {bad, $sformatf(" ABORT=%0d (model %s)", v[24], h.abort.str())};
        if (!h.error.may_be(T, v[26]))  bad = {bad, $sformatf(" ERROR=%0d (model %s)", v[26], h.error.str())};
        if (!h.done.may_be(T, v[27]))   bad = {bad, $sformatf(" DONE=%0d (model %s)", v[27], h.done.str())};
        if (bad != "")
            err("REG", $sformatf("ch%0d CONTROL read %h at edge %0d:%s  [R05 R07 R13 R15-R18 R21]", h.ch, v, T, bad));
        h.enable.observe(T, v[7]);
        h.abort.observe(T, v[24]);
        h.error.observe(T, v[26]);
        h.done.observe(T, v[27]);
    endfunction

    function void check_tstat(ahb_item t, dma_chan h, bit [31:0] v);
        longint T = t.cyc;
        if (v[11:0] < h.credit_lo || v[11:0] > h.credit_hi || (v & 32'hFFFE_F000) != 0)
            err("REG", $sformatf("ch%0d TRIGGER_STATUS read %h: CREDIT %0d not in [%0d,%0d] or reserved bits set  [R20]",
                                 h.ch, v, v[11:0], h.credit_lo, h.credit_hi));
        if (!h.overrun.may_be(T, v[16]))
            err("REG", $sformatf("ch%0d TRIGGER_STATUS.OVERRUN=%0d, model %s  [R20]", h.ch, v[16], h.overrun.str()));
        h.overrun.observe(T, v[16]);
        if (cov != null && v[16]) cov.sample_trig_evt(0);
    endfunction

    function void reg_write(ahb_item t);
        int ch;
        reg_kind_e k = decode_reg(t.addr, ch);
        bit want_err = (k == R_UNMAPPED) || t.strobe != 4'hF;
        dma_chan h;
        longint W = t.cyc;
        n_reg_writes++;
        tr(W, $sformatf("write %s ch%0d = %h strobe %b%s", k.name(), ch, t.wdata, t.strobe, t.resp ? " ERROR" : ""));
        if (cov != null) cov.sample_reg(t, k, ch);
        if (t.resp != want_err) begin
            err("REG", $sformatf("write %h strobe %b got %s, expected %s  [R01 R02]", t.addr, t.strobe,
                                 t.resp ? "ERROR" : "OKAY", want_err ? "ERROR" : "OKAY"));
            return;
        end
        if (t.resp) return;
        h = chans[ch];
        case (k)
            R_SOURCE:      h.src = t.wdata;
            R_DESTINATION: h.dst = t.wdata;
            R_DESIRED:     h.len = t.wdata;
            R_CONTROL:     write_control(h, W, t.wdata);
            R_TCFG:        write_tcfg(h, W, t.wdata);
            R_TSTAT: begin
                if (cov != null && h.overrun.may_be(W, 1)) cov.sample_trig_evt(1);
                h.overrun.sw_write(W, 0);
            end
            default: ;
        endcase
    endfunction

    function void write_control(dma_chan h, longint W, bit [31:0] v);
        dma_xfer_cfg c = new(v);
        bit run   = h.running_at(W);
        bit start = v[7] && !run;
        bit stop  = run && (!v[7] || v[24]);
        if (h.running && !run) h.running = 0;
        if (cov != null) begin
            int others = 0;
            foreach (chans[o]) if (o != h.ch && (chans[o].done.may_be(W, 1) || chans[o].error.may_be(W, 1))) others++;
            if ((h.done.may_be(W, 1) && !v[27]) || (h.error.may_be(W, 1) && !v[26])) cov.sample_irq_clear(others);
            if (v[27] || v[26]) cov.note_cause(h.ch, 3);
        end
        h.ctrl_sw = v;
        h.done.sw_write(W, v[27], 1);
        h.error.sw_write(W, v[26], 1);
        h.abort.sw_write(W, v[24]);
        if (v[24]) begin
            h.abort.hw_event(0, W + 2, W + 3 + slack);
            if (v[7]) h.enable.hw_event(0, W + 2, W + 2 + slack);
        end
        if (start) begin
            h.enable.sw_write(W, 1);
            start_run(h, W, c);
        end else if (v[7] && run && invalid(c, h.len)) begin
            h.done.hw_event(1, W + 2, W + 2 + slack);
            h.enable.hw_event(0, W + 2, W + 2 + slack);
            h.end_running(W + 1);
            if (h.cur != null && h.cur.state == dma_run::RUNNING) begin
                h.cur.state    = dma_run::STOPPED;
                h.cur.end_edge = W + 1;
                note_stop(h.cur, "invalid rewrite");
            end
        end else if (v[7] && run) begin
            if (h.cur != null && h.cur.state == dma_run::RUNNING && !c.same(h.cur.cfg)) begin
                h.cur.cfg_next      = c;
                h.cur.cfg_next_edge = W;
            end
        end else begin
            h.enable.sw_write(W, v[7]);
        end
        if (stop) begin
            h.running = 0;
            if (h.cur != null && h.cur.state inside {dma_run::RUNNING, dma_run::INVALID}) begin
                if (cov != null) cov.sample_stop(v[24] ? 0 : 1, h.cur, !h.enable.cur && !h.enable.pend && !h.enable.unknown);
                h.cur.state    = dma_run::STOPPED;
                h.cur.end_edge = W;
                note_stop(h.cur, v[24] ? "abort" : "disable");
            end else if (h.cur != null && h.cur.state == dma_run::DONE && h.cur.cfg.mode == 0) begin
                if (cov != null) cov.sample_stop(v[24] ? 0 : 1, h.cur);
                if (W <= h.cur.end_edge) h.done.pend = 0;
            end
        end
    endfunction

    function bit invalid(dma_xfer_cfg c, bit [31:0] len);
        return c.mode > 2 || c.size == 3 || (c.mode != 2 && len == 0);
    endfunction

    function void start_run(dma_chan h, longint W, dma_xfer_cfg c);
        dma_run r = new();
        r.ch = h.ch; r.id = ++h.n_runs; r.cfg = c;
        r.src0 = h.src; r.dst0 = h.dst; r.len = h.len;
        r.start_edge = W;
        n_runs++;
        kill_runs(h, W, "restart", 1);
        h.running   = 1;
        h.running_until = dma_hwval::MAXT;
        h.completed = 0;
        h.err_addr.sw_write(W, 0);
        h.cur = r;
        h.runs.push_back(r);
        if (invalid(c, h.len)) begin
            r.state = dma_run::INVALID;
            h.end_running(W + 1);
            h.done.hw_event(1, W + 2, W + 2 + slack);
            h.enable.hw_event(0, W + 2, W + 2 + slack);
        end else if (h.armed() && c.mode != 2) begin
            r.state     = dma_run::STOPPED;
            r.end_edge  = W;
            r.rd_closed = 1;
            h.end_running(W + 1);
            h.enable.hw_event(0, W + 2, W + 2 + slack);
        end else begin
            r.state = dma_run::RUNNING;
            if (c.mode == 0) h.enable.hw_event(0, W + 2, dma_hwval::MAXT);
        end
        tr(W, {"start ", r.str()});
        if (cov != null) cov.sample_start(this, h, r);
    endfunction

    function void write_tcfg(dma_chan h, longint W, bit [31:0] v);
        bit was = h.armed();
        h.tcfg = v;
        if (!v[7]) begin
            if (cov != null && (h.credit_hi > 0)) cov.sample_trig_disarm();
            h.credit_hi = 0; h.credit_lo = 0;
            h.armed_grants = 0; h.armed_reads = 0;
        end else if (!was) begin
            h.armed_grants = h.credit_hi; h.armed_reads = 0;
            if (h.cur != null && h.cur.state == dma_run::RUNNING && h.cur.cfg.mode != 2 && h.running_at(W)) begin
                h.enable.hw_event(0, W + 2, W + 2 + slack);
                h.end_running(W + 1);
                h.cur.state    = dma_run::STOPPED;
                h.cur.end_edge = W + 1;
                note_stop(h.cur, "armed outside ring mode");
            end
        end
    endfunction

    function void trigger_edges(longint T, bit [NSRC-1:0] rise);
        foreach (chans[c]) begin
            dma_chan h = chans[c];
            if (h.armed() && rise[h.sel()]) begin
                longint hi = h.credit_hi + h.count(), lo = h.credit_lo + h.count();
                if (cov != null) cov.sample_trig(h.count(), h.credit_hi);
                h.armed_grants += h.count();
                if (lo > 4095)      h.overrun.hw_event(1, T + 1, T + 1 + slack);
                else if (hi > 4095) begin h.overrun.hw_event(1, T + 1, dma_hwval::MAXT); h.overrun.unknown = 1; end
                h.credit_hi = hi > 4095 ? 4095 : hi;
                h.credit_lo = lo > 4095 ? 4095 : lo;
            end
        end
    endfunction

    function void mem_read(ahb_item t);
        int c = src_owner(t.addr);
        dma_chan h;
        dma_run  r;
        bit [31:0] s, d;
        dma_xfer_cfg used;
        if (t.trans == 2'b01) return;
        if (t.shadow) begin n_shadow++; return; end
        n_rd++;
        if (c < 0) begin
            err("RD", $sformatf("read outside every channel's source area: %s  [R06]", t.convert2string()));
            return;
        end
        h = chans[c];
        if (dead_read(t, c) != null) return;
        foreach (h.runs[i]) begin
            dma_run x = h.runs[i];
            if (!x.wants_reads()) continue;
            if (match_read(x, t, used, s, d)) begin r = x; break; end
        end
        if (r == null) begin
            report_unexpected_read(h, t);
            return;
        end
        foreach (h.runs[i]) if (h.runs[i] != r && h.runs[i].id < r.id) h.runs[i].rd_closed = 1;
        close_older_than(r.start_edge);
        check_grant(c, t, r);
        if (used != r.cfg) begin r.cfg = used; r.cfg_next = null; end
        r.pend.push_back('{src: s, dst: d, size: used.size, data: lane_extract(t.rdata, used.size, s), k: r.n_rd});
        r.last_src = s; r.last_dst = d;
        r.n_rd++;
        if (r.state == dma_run::STOPPED) r.n_after_stop++;
        if (h.armed() && r.cfg.mode == 2) begin
            h.armed_reads++;
            if (h.armed_reads > h.armed_grants)
                err("TRIG", $sformatf("ch%0d moved %0d items but was given only %0d credits  [R20]",
                                      c, h.armed_reads, h.armed_grants));
            if (h.credit_hi > 0) h.credit_hi--;
            h.credit_lo = h.credit_hi > FDEPTH + 3 ? h.credit_hi - (FDEPTH + 3) : 0;
        end
        h.n_rd_checked++;
        if (cov != null) cov.sample_read(t, r);
    endfunction

    function void close_older_than(longint S);
        foreach (chans[c]) foreach (chans[c].runs[i]) begin
            dma_run x = chans[c].runs[i];
            if (x.state == dma_run::STOPPED && x.end_edge + 1 < S) x.rd_closed = 1;
        end
    endfunction

    function bit match_read(dma_run r, ahb_item t, output dma_xfer_cfg used, output bit [31:0] s, output bit [31:0] d);
        dma_xfer_cfg cands[$];
        if (r.n_rd == 0 && t.cyc < r.start_edge + 4) return 0;
        cands.push_back(r.cfg);
        if (r.cfg_next != null) cands.push_back(r.cfg_next);
        foreach (cands[i]) begin
            r.next_addr(cands[i], s, d);
            if (t.addr == haddr(s, cands[i].size) && t.size == {1'b0, cands[i].size}) begin
                used = cands[i];
                return 1;
            end
        end
        return 0;
    endfunction

    function void report_unexpected_read(dma_chan h, ahb_item t);
        string why;
        if (h.runs.size() == 0) why = "no copy was ever started on this channel";
        else begin
            dma_run r = h.runs[$];
            bit [31:0] s, d;
            r.next_addr(r.cfg, s, d);
            if (!r.wants_reads()) why = $sformatf("%s expects no more reads", r.str());
            else why = $sformatf("%s expects item %0d: HADDR %h HSIZE %0d", r.str(), r.n_rd, haddr(s, r.cfg.size), r.cfg.size);
        end
        err("RD", $sformatf("unexpected read %s: %s  [R06 R08 R09 R13 R15 R16]", t.convert2string(), why));
    endfunction

    function void check_grant(int c, ahb_item t, dma_run r_new);
        if (last_rd_ch >= 0 && last_rd_ch != c) begin
            dma_chan p = chans[last_rd_ch];
            dma_run  r = p.cur;
            check_round_robin(last_rd_ch, c, t);
            if (r != null && r.state == dma_run::RUNNING && !r.rd_closed && !p.armed() && r.n_rd > 0) begin
                bit [31:0] L = r.pass_len();
                bit owed = (r.cfg.mode == 0 && r.n_rd < L) || (r.cfg.mode == 1) ||
                           (r.cfg.mode == 2 && L != 0 && (r.n_rd % L) != 0);
                if (owed && r.cfg_next == null)
                    err("ARB", $sformatf("ch%0d lost the grant to ch%0d after %0d items of %s: %s  [R19]",
                                         last_rd_ch, c, r.n_rd, r.str(), t.convert2string()));
            end
        end
        last_rd_ch  = c;
        last_rd_run = r_new;
    endfunction

    function void check_round_robin(int p, int c, ahb_item t);
        dma_run pr = last_rd_run;
        int dc = (c - p + NCH) % NCH;
        longint decide;   // earliest regrant edge
        if (pr == null || chans[p].armed()) return;
        case (pr.cfg.mode)
            0:       decide = pr.start_edge + pr.len;
            2:       decide = pr.start_edge + (longint'(1) << pr.cfg.ring_size);
            default: decide = (pr.state inside {dma_run::STOPPED, dma_run::ERRORED}) ? pr.end_edge : -1;
        endcase
        if (pr.state inside {dma_run::STOPPED, dma_run::ERRORED} && pr.end_edge < decide) decide = pr.end_edge;
        if (decide < 0) return;
        foreach (chans[k]) foreach (chans[k].runs[i])
            if (chans[k].runs[i].state == dma_run::INVALID) return;
        foreach (chans[d]) begin
            dma_chan hd = chans[d];
            dma_run  rd = hd.cur;
            int dd = (d - p + NCH) % NCH;
            if (d == p || d == c || rd == null || dd >= dc) continue;
            if (rd.state == dma_run::RUNNING && !rd.rd_closed && rd.n_rd == 0 && !hd.armed() &&
                rd.start_edge + 2 <= decide && hd.running_at(t.cyc))
                err("ARB", $sformatf("after ch%0d the grant went to ch%0d, but ch%0d (waiting since edge %0d) comes first in round-robin order  [R19]  (%s could hand over from edge %0d)",
                                     p, c, d, rd.start_edge, pr.str(), decide));
        end
    endfunction

    function void mem_write(ahb_item t);
        int c = dst_owner(t.addr);
        dma_chan h;
        dma_run  r;
        dma_pend_t p;
        bit [3:0]  st;
        bit [31:0] dv;
        if (t.trans == 2'b01) return;
        if (t.shadow) begin
            n_shadow++;
            if (t.strobe != 0)
                err("WR", $sformatf("write accepted in the 2nd cycle of an ERROR has HWSTRB=%b, expected 0000: %s  [P9]",
                                    t.strobe, t.convert2string()));
            return;
        end
        if (landed(t, c)) begin
            n_landed++;
            return;
        end
        if (c < 0) begin
            if (t.strobe != 0)
                err("WR", $sformatf("write outside every channel's destination area: %s  [R06]", t.convert2string()));
            return;
        end
        h = chans[c];
        if (t.strobe == 0) begin
            bit ok = 0;
            foreach (h.runs[i]) if (h.runs[i].state == dma_run::ERRORED && t.cyc > h.runs[i].err_edge) ok = 1;
            n_null_wr++;
            if (!ok) err("WR", $sformatf("write with HWSTRB=0000 that no ERROR explains (a lost write?): %s  [R06]", t.convert2string()));
            return;
        end
        n_wr++;
        foreach (h.runs[i]) if (h.runs[i].pend.size()) begin r = h.runs[i]; break; end
        if (r == null) begin
            err("WR", $sformatf("unexpected write (no item of ch%0d is waiting to be written): %s  [R06 R13 R15 R16]",
                                c, t.convert2string()));
            return;
        end
        if (r.state == dma_run::ERRORED && t.cyc > r.err_edge) begin
            err("WR", $sformatf("ch%0d wrote after its bus ERROR at edge %0d: %s  [R13]", c, r.err_edge, t.convert2string()));
            return;
        end
        p  = r.pend.pop_front();
        st = lanes(p.dst, p.size);
        dv = lane_place(p.data, p.size, p.dst);
        if (!wr_matches(t, p))
            err("WR", $sformatf("ch%0d item %0d: wrote %s, expected HADDR %h HSIZE %0d HWSTRB %b data %h  [R06 R08-R10 P6]",
                                c, p.k, t.convert2string(), haddr(p.dst, p.size), p.size, st, dv & {{8{st[3]}}, {8{st[2]}}, {8{st[1]}}, {8{st[0]}}}));
        expect_bytes(p);
        r.n_wr++;
        h.n_wr_checked++;
        if (cov != null) cov.sample_write(t, r);
        if (r == h.cur) begin
            bit [31:0] L = r.pass_len();
            h.completed++;
            if (r.cfg.mode == 0 && r.state == dma_run::RUNNING && r.n_wr == L) begin
                r.state    = dma_run::DONE;
                r.end_edge = t.cyc;
                h.end_running(t.cyc + 1);
                h.done.hw_event(1, t.cyc + 2, t.cyc + 2 + slack);
                h.enable.hw_event(0, h.enable.pend ? h.enable.vis_from : t.cyc + 1, t.cyc + 1);
                h.enable.settle();
                if (cov != null) cov.note_cause(h.ch, 0);
            end else if (r.cfg.mode inside {1, 2} && (L == 0 || r.n_wr % L == 0) &&
                         (r.state == dma_run::RUNNING || (r.state == dma_run::STOPPED && t.cyc <= r.end_edge))) begin
                h.done.hw_event(1, t.cyc + 1, t.cyc + 1 + slack);
                tr(t.cyc, $sformatf("ch%0d pass end after %0d writes", c, r.n_wr));
                if (cov != null) cov.note_cause(h.ch, 1);
            end
        end
    endfunction

    function void mem_error(ahb_item t);
        bit is_rd = (t.port == ahb_item::RD);
        int c = is_rd ? src_owner(t.addr) : dst_owner(t.addr);
        dma_chan h;
        dma_run  r;
        bit [31:0] item_addr, s, d;
        dma_xfer_cfg used;
        n_errors_seen++;
        if (t.shadow || t.trans == 2'b01) return;
        if (c < 0) begin
            err("ERR", $sformatf("ERROR response on a transfer outside every channel's area: %s", t.convert2string()));
            return;
        end
        h = chans[c];
        if (is_rd) begin
            dma_run x = dead_read(t, c);
            if (x != null) begin
                x.dead_open = 0;
                return;
            end
            foreach (h.runs[i]) if (h.runs[i].wants_reads() && match_read(h.runs[i], t, used, s, d)) begin
                r = h.runs[i]; break;
            end
            if (r == null) begin
                foreach (h.runs[i]) if (h.runs[i].state == dma_run::ERRORED && t.cyc <= h.runs[i].err_edge &&
                                        match_read(h.runs[i], t, used, s, d)) begin
                    h.runs[i].n_rd++;
                    h.runs[i].last_src = s; h.runs[i].last_dst = d;
                    channel_error(h, t, s, 0);
                    return;
                end
                report_unexpected_read(h, t);
                return;
            end
            item_addr = s;
            check_grant(c, t, r);
        end else begin
            if (landed(t, c)) return;
            if (t.strobe == 0) begin
                bit ok = 0;
                foreach (h.runs[i]) if (h.runs[i].state == dma_run::ERRORED && t.cyc > h.runs[i].err_edge) ok = 1;
                if (!ok) err("ERR", $sformatf("ERROR on a write with HWSTRB=0000 that no kill explains: %s", t.convert2string()));
                return;
            end
            foreach (h.runs[i]) if (h.runs[i].pend.size()) begin r = h.runs[i]; break; end
            if (r == null) begin
                err("ERR", $sformatf("ERROR on an unexpected write of ch%0d: %s", c, t.convert2string()));
                return;
            end
            item_addr = r.pend[0].dst;
            if (t.addr != haddr(item_addr, r.pend[0].size))
                err("WR", $sformatf("ch%0d item %0d: write to %h, expected %h  [R06]", c, r.pend[0].k, t.addr,
                                    haddr(item_addr, r.pend[0].size)));
        end
        if (cov != null) cov.sample_error(this, t, r);
        channel_error(h, t, item_addr, 0);
    endfunction

    function void channel_error(dma_chan h, ahb_item t, bit [31:0] item_addr, bit addr_unsure);
        bit is_rd = (t.port == ahb_item::RD);
        h.end_running(t.cyc + 1);
        h.error.hw_event(1, t.cyc + 2, t.cyc + 2 + slack);
        h.enable.hw_event(0, t.cyc + 2, t.cyc + 2 + slack);
        h.err_addr.hw_event(item_addr, t.cyc + 2, t.cyc + 2 + slack, 1);
        if (addr_unsure) h.err_addr.unknown = 1;
        kill_runs(h, t.cyc, is_rd ? "read error" : "write error", is_rd);
    endfunction

    // Drops a channel's queued items one cycle after edge K. The item in its write data phase then may still land.
    function void kill_runs(dma_chan h, longint K, string why, bit may_land);
        foreach (h.runs[i]) begin
            dma_run x = h.runs[i];
            if (x.state == dma_run::DONE && x.pend.size() == 0) continue;
            if (x.state == dma_run::INVALID || x.state == dma_run::ERRORED) begin
                x.pend.delete();
                continue;
            end
            if (x.state != dma_run::STOPPED) x.end_edge = K;
            x.state      = dma_run::ERRORED;
            x.err_edge   = K;
            x.dead_open  = 1;
            x.post_seen  = 0;
            x.dead_beats = 0;
            note_stop(x, why);
            if (may_land && x.pend.size()) begin
                dma_infl_t f;   // VCS cannot pass this struct literal to push_back directly
                f = '{ch: h.ch, item: x.pend[0], kill_edge: K};
                infl.push_back(f);
            end
            x.pend.delete();
        end
    endfunction

    // Reads still on the bus when a run was dropped at edge K: the item in its data phase, the address
    // presented at the kill, and the rest of the burst that address started. Checks every read in port order.
    function dma_run dead_read(ahb_item t, int c);
        dma_run hit;
        foreach (chans[k]) foreach (chans[k].runs[i]) begin
            dma_run x = chans[k].runs[i];
            dma_xfer_cfg used;
            bit [31:0] s, d;
            bit mine, dead;
            if (!x.dead_open || t.cyc <= x.err_edge) continue;
            mine = (k == c) && match_read(x, t, used, s, d);
            if (t.aedge <= x.err_edge) dead = mine;
            else if (!x.post_seen) begin
                x.post_seen  = 1;
                dead = mine && (t.aedge == x.err_edge + 1 ||
                                (prev_rd != null && prev_rd.aedge <= x.err_edge && prev_rd.cyc == t.aedge));
                x.dead_beats = (dead && t.burst == 3'b011) ? 3 - t.beat : 0;
            end else if (x.dead_beats > 0) begin
                dead = mine && t.trans == 2'b11;
                if (dead) x.dead_beats--;
            end
            if (!dead && t.aedge > x.err_edge) x.dead_open = 0;
            if (dead && hit == null) begin
                hit = x;
                x.n_dead_rd++; x.n_rd++;
                x.last_src = s; x.last_dst = d;
                n_dead_rd++;
            end
        end
        prev_rd = t;
        return hit;
    endfunction

    // The first write after a kill may be the dropped channel's item whose address phase was already accepted.
    function bit landed(ahb_item t, int c);
        bit hit = 0;
        for (int i = infl.size() - 1; i >= 0; i--) if (t.cyc > infl[i].kill_edge) begin
            if (!hit && c == infl[i].ch && t.aedge <= infl[i].kill_edge && t.strobe != 0 && wr_matches(t, infl[i].item)) begin
                hit = 1;
                if (!t.resp) expect_bytes(infl[i].item);
                tr(t.cyc, $sformatf("ch%0d item %0d was in its data phase when dropped and %s", c, infl[i].item.k,
                                    t.resp ? "got ERROR" : "landed"));
            end
            infl.delete(i);
        end
        return hit;
    endfunction

    function bit wr_matches(ahb_item t, dma_pend_t p);
        bit [3:0]  st = lanes(p.dst, p.size);
        bit [31:0] dv = lane_place(p.data, p.size, p.dst);
        return t.addr == haddr(p.dst, p.size) && t.size == {1'b0, p.size} && t.strobe == st &&
               ((t.wdata ^ dv) & {{8{st[3]}}, {8{st[2]}}, {8{st[1]}}, {8{st[0]}}}) == 0;
    endfunction

    function void expect_bytes(dma_pend_t p);
        bit [3:0]  st = lanes(p.dst, p.size);
        bit [31:0] dv = lane_place(p.data, p.size, p.dst);
        for (int i = 0; i < 4; i++) if (st[i]) exp_mem[{p.dst[31:2], 2'b00} + i] = dv[8 * i +: 8];
    endfunction

    function void note_stop(dma_run r, string why);
        tr(edge_now(), $sformatf("%s ends (%s) after %0d reads, %0d writes", r.str(), why, r.n_rd, r.n_wr));
    endfunction

    function void settle();
        foreach (chans[c]) begin
            dma_chan h = chans[c];
            h.done.settle(); h.enable.settle(); h.error.settle(); h.abort.settle(); h.err_addr.settle();
            h.overrun.settle();
            h.credit_lo = h.credit_hi;
            foreach (h.runs[i]) if (h.runs[i].state == dma_run::INVALID) begin
                h.runs[i].state = dma_run::DONE;
                h.running = 0;
            end
        end
    endfunction

    function longint copy_time(int c);
        dma_run r = chans[c].cur;
        if (r == null || r.state != dma_run::DONE) begin
            err("PERF", $sformatf("ch%0d: no completed copy to time", c));
            return -1;
        end
        return r.end_edge - r.start_edge;
    endfunction

    function void check_copy_time(int c, longint margin = 12);
        dma_run r = chans[c].cur;
        if (copy_time(c) < 0) return;
        if (r.end_edge - r.start_edge > r.len + margin)
            err("PERF", $sformatf("ch%0d: %0d-item copy took %0d cycles, more than N + %0d = %0d  [R25]",
                                  c, r.len, r.end_edge - r.start_edge, margin, r.len + margin));
        else
            tr(r.end_edge, $sformatf("ch%0d: %0d-item copy took %0d cycles", c, r.len, r.end_edge - r.start_edge));
    endfunction

    function bit drained(int c);
        dma_chan h = chans[c];
        if (h.running_at(edge_now())) return 0;
        foreach (h.runs[i]) begin
            dma_run x = h.runs[i];
            if (x.pend.size()) return 0;
            if (x.state == dma_run::STOPPED && !x.rd_closed) return 0;
            if (x.state == dma_run::ERRORED && edge_now() < x.err_edge + 10) return 0;
        end
        return 1;
    endfunction

    function void check_phase(uvm_phase phase);
        int bytes_checked;
        foreach (exp_mem[a]) begin
            bytes_checked++;
            if (mem.get_byte(a) != exp_mem[a])
                err("MEM", $sformatf("byte %h is %h, expected %h  [R06 R10]", a, mem.get_byte(a), exp_mem[a]));
        end
        foreach (mem.bus_written[a])
            if (!exp_mem.exists(a))
                err("MEM", $sformatf("byte %h was written but no expected write covers it  [R06]", a));
        foreach (chans[c]) foreach (chans[c].runs[i]) begin
            dma_run r = chans[c].runs[i];
            if (r.state == dma_run::RUNNING && r.cfg.mode == 0 && !r.rd_closed)
                err("SCB", $sformatf("%s did not finish: %0d of %0d items written", r.str(), r.n_wr, r.len));
            if (r.pend.size() && r.state != dma_run::ERRORED)
                err("SCB", $sformatf("%s: %0d items read but never written", r.str(), r.pend.size()));
            if (r.state inside {dma_run::DONE, dma_run::STOPPED} && r.cfg.mode <= 2 && r.n_rd > 0 && r.n_wr == 0)
                err("SCB", $sformatf("%s compared no writes", r.str()));
        end
        if (n_reg_reads + n_rd + n_wr == 0)
            err("SCB", "nothing was compared: the test checked nothing");
        `uvm_info("SCB", $sformatf("memory bytes checked: %0d", bytes_checked), UVM_LOW)
    endfunction

    function void report_phase(uvm_phase phase);
        `uvm_info("SCB", $sformatf("compares: %0d  (reads %0d, writes %0d, register reads %0d, interrupt %0d)   mismatches: %0d",
                                   n_rd + n_wr + n_reg_reads + n_irq_checks, n_rd, n_wr, n_reg_reads, n_irq_checks, n_mismatch), UVM_LOW)
        `uvm_info("SCB", $sformatf("runs %0d, register writes %0d, ERROR responses %0d, shadow %0d, dead reads %0d, null writes %0d, landed after a kill %0d",
                                   n_runs, n_reg_writes, n_errors_seen, n_shadow, n_dead_rd, n_null_wr, n_landed), UVM_LOW)
    endfunction
endclass
