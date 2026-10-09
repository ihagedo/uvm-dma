// File:        dma_coverage.svh
// Author:      Isaac Hagedorn
// Date:        2026-10-08
// Description: Functional coverage for the DMA test plan, sampled by the scoreboard.

typedef class dma_scoreboard;
typedef class dma_chan;

class dma_coverage extends uvm_component;
    `uvm_component_utils(dma_coverage)

    int mode, size, sinc, dinc, lenc, rsize, bsel, nact, chn, pair;
    int port, burst, beat, waits, pos, others, epos_beat;
    int skind, sphase;
    int rkind, rw, resp, akind;
    int tcount, tcredit, tevt;
    int icause, nsrc;

    covergroup cg_cfg;
        cp_mode: coverpoint mode { bins ONESHOT = {0}; bins CONTINUOUS = {1}; bins RING = {2}; bins INVALID = {[3:7]}; }
        cp_size: coverpoint size { bins BYTE = {0}; bins HALF = {1}; bins WORD = {2}; }
        mode_x_size: cross cp_mode, cp_size;
        cp_sinc: coverpoint sinc { bins ZERO = {0}; bins EQ_SIZE = {1}; bins TWICE = {2}; bins MAX255 = {3}; bins OTHER = {4}; }
        cp_dinc: coverpoint dinc { bins ZERO = {0}; bins EQ_SIZE = {1}; bins TWICE = {2}; bins MAX255 = {3}; bins OTHER = {4}; }
        cp_len:  coverpoint lenc { bins L1 = {1}; bins L2_3 = {2}; bins L4 = {4}; bins L5_15 = {5}; bins L16 = {16};
                                   bins L17 = {17}; bins L18_255 = {18}; bins L256_UP = {256}; }
    endgroup

    covergroup cg_ring;
        cp_rsize: coverpoint rsize { bins RS[] = {[0:7]}; }
        cp_bsel:  coverpoint bsel  { bins SRC_STEPS = {0}; bins DST_STEPS = {1}; }
        rsize_x_bsel: cross cp_rsize, cp_bsel;
    endgroup

    covergroup cg_conc;
        cp_active: coverpoint nact { bins ONE = {1}; bins TWO = {2}; bins SOME = {[3:NCH-1]}; bins ALL = {NCH}; }
        cp_chan:   coverpoint chn  { bins CH[] = {[0:NCH-1]}; }
        cp_pair:   coverpoint pair { bins OS_OS = {1}; bins OS_RING = {2}; bins RING_RING = {3}; bins CONT_ANY = {4}; }
    endgroup

    covergroup cg_bus;
        cp_port:  coverpoint port  { bins RD = {0}; bins WR = {1}; }
        cp_burst: coverpoint burst { bins SINGLE = {0}; bins INCR4 = {1}; }
        port_x_burst: cross cp_port, cp_burst;
        cp_waits: coverpoint waits { bins W0 = {0}; bins W1 = {1}; bins W2_4 = {[2:4]}; bins W5_UP = {[5:$]}; }
        cp_beat:  coverpoint beat  { bins SINGLE = {4}; bins B0 = {0}; bins B1 = {1}; bins B2 = {2}; bins B3 = {3}; }
        waits_x_beat: cross cp_waits, cp_beat;
    endgroup

    covergroup cg_error;
        cp_port:   coverpoint port      { bins RD = {0}; bins WR = {1}; }
        cp_pos:    coverpoint pos       { bins FIRST = {0}; bins MIDDLE = {1}; bins LAST = {2}; }
        cp_beat:   coverpoint epos_beat { bins SINGLE = {4}; bins B0 = {0}; bins B1 = {1}; bins B2 = {2}; bins B3 = {3}; }
        cp_mode:   coverpoint mode      { bins ONESHOT = {0}; bins CONTINUOUS = {1}; bins RING = {2}; }
        cp_others: coverpoint others    { bins ALONE = {0}; bins WITH_OTHERS = {1}; }
        port_x_pos:    cross cp_port, cp_pos;
        port_x_beat:   cross cp_port, cp_beat;
        port_x_mode:   cross cp_port, cp_mode;
        port_x_others: cross cp_port, cp_others;
    endgroup

    covergroup cg_stop;
        cp_kind:  coverpoint skind  { bins ABORT = {0}; bins DISABLE = {1}; bins RESET = {2}; }
        cp_phase: coverpoint sphase { bins BEFORE_FIRST_READ = {0}; bins MID = {1}; bins LAST_WRITES = {2}; bins AFTER_DONE = {3}; }
        cp_mode:  coverpoint mode   { bins ONESHOT = {0}; bins CONTINUOUS = {1}; bins RING = {2}; }
        kind_x_phase: cross cp_kind, cp_phase;
        kind_x_mode:  cross cp_kind, cp_mode;
    endgroup

    covergroup cg_reg;
        cp_reg:  coverpoint rkind { bins SOURCE = {0}; bins DESTINATION = {1}; bins CONTROL = {2}; bins DESIRED = {3};
                                    bins COMPLETED = {4}; bins REMAINING = {5}; bins ACTIVE = {6}; bins ERRADDR = {7};
                                    bins TCFG = {8}; bins TSTAT = {9}; bins UNMAPPED = {10}; }
        cp_rw:   coverpoint rw    { bins READ = {0}; bins WRITE = {1}; }
        cp_resp: coverpoint resp  { bins OKAY = {0}; bins ERROR = {1}; }
        reg_x_rw_x_resp: cross cp_reg, cp_rw, cp_resp;
        cp_access: coverpoint akind { bins WORD = {0}; bins SUBWORD_AT_0 = {1}; bins UNALIGNED = {2}; bins UNMAPPED = {3};
                                      bins PARTIAL_STROBE = {4}; }
    endgroup

    covergroup cg_trig;
        cp_count:  coverpoint tcount  { bins ZERO = {0}; bins ONE = {1}; bins MID = {[2:254]}; bins MAX = {255}; }
        cp_credit: coverpoint tcredit { bins ZERO = {0}; bins ONE = {1}; bins MID = {[2:4094]}; bins MAX = {4095}; }
    endgroup

    covergroup cg_trig_evt;
        cp_evt: coverpoint tevt { bins OVERRUN_SEEN = {0}; bins OVERRUN_CLEARED = {1}; bins DISARM_WITH_CREDIT = {2}; }
    endgroup

    covergroup cg_irq;
        cp_cause: coverpoint icause { bins ONESHOT_DONE = {0}; bins PASS_DONE = {1}; bins BUS_ERROR = {2}; bins SW_WRITE = {3}; }
        cp_srcs:  coverpoint nsrc   { bins ONE = {1}; bins SEVERAL = {[2:$]}; }
    endgroup

    covergroup cg_irq_clear;
        cp_others: coverpoint nsrc { bins LAST_ONE = {0}; bins OTHERS_STILL_SET = {[1:$]}; }
    endgroup

    covergroup cg_active;
        cp_chan: coverpoint chn { bins CH[] = {[0:NCH-1]}; }
    endgroup

    bit  irq_prev;
    int  cause_q[NCH];   // what last set DONE/ERROR on each channel

    function new(string name, uvm_component parent);
        super.new(name, parent);
        cg_cfg = new(); cg_ring = new(); cg_conc = new(); cg_bus = new();
        cg_error = new(); cg_stop = new(); cg_reg = new(); cg_trig = new(); cg_trig_evt = new();
        cg_irq = new(); cg_irq_clear = new(); cg_active = new();
    endfunction

    static function int incr_class(bit [7:0] inc, bit [1:0] sz);
        int b = 1 << sz;
        if (inc == 0)     return 0;
        if (inc == 255)   return 3;
        if (inc == b)     return 1;
        if (inc == 2 * b) return 2;
        return 4;
    endfunction

    static function int len_class(bit [31:0] l);
        if (l == 1) return 1;
        if (l <= 3) return 2;
        if (l == 4) return 4;
        if (l <= 15) return 5;
        if (l == 16) return 16;
        if (l == 17) return 17;
        if (l <= 255) return 18;
        return 256;
    endfunction

    function void sample_start(dma_scoreboard scb, dma_chan h, dma_run r);
        mode = r.cfg.mode; size = r.cfg.size;
        sinc = incr_class(r.cfg.sincr, r.cfg.size);
        dinc = incr_class(r.cfg.dincr, r.cfg.size);
        lenc = (r.cfg.mode == 2 || r.len == 0) ? 0 : len_class(r.len);
        cg_cfg.sample();
        if (r.cfg.mode == 2) begin
            rsize = r.cfg.ring_size; bsel = r.cfg.bsel;
            cg_ring.sample();
        end
        nact = 0; pair = 0; chn = h.ch;
        foreach (scb.chans[c]) if (scb.chans[c].running && scb.chans[c].cur != null) begin
            nact++;
            if (c != h.ch && pair == 0) begin
                int m1 = r.cfg.mode, m2 = scb.chans[c].cur.cfg.mode;
                if (m1 == 1 || m2 == 1)        pair = 4;
                else if (m1 == 0 && m2 == 0)   pair = 1;
                else if (m1 == 2 && m2 == 2)   pair = 3;
                else if (m1 <= 2 && m2 <= 2)   pair = 2;
            end
        end
        cg_conc.sample();
    endfunction

    function void sample_xfer(ahb_item t);
        port  = (t.port == ahb_item::WR);
        burst = (t.burst == 3'b011);
        beat  = burst ? t.beat : 4;
        waits = t.waits;
        cg_bus.sample();
    endfunction

    function void sample_read(ahb_item t, dma_run r);  sample_xfer(t); endfunction
    function void sample_write(ahb_item t, dma_run r); sample_xfer(t); endfunction

    function void sample_error(dma_scoreboard scb, ahb_item t, dma_run r);
        longint k = (t.port == ahb_item::RD) ? r.n_rd : (r.pend.size() ? r.pend[0].k : r.n_wr);
        bit [31:0] L = r.pass_len();
        port = (t.port == ahb_item::WR);
        mode = r.cfg.mode;
        if (L == 0)                      pos = 0;
        else if (k % L == 0)             pos = 0;
        else if (k % L == L - 1)         pos = 2;
        else                             pos = 1;
        epos_beat = (t.burst == 3'b011) ? t.beat : 4;
        others = 0;
        foreach (scb.chans[c]) if (c != r.ch && scb.chans[c].running) others = 1;
        cg_error.sample();
        cause_q[r.ch] = 2;
    endfunction

    function void sample_stop(int kind, dma_run r, bit all_queued = 0);
        bit [31:0] L = r.pass_len();
        skind = kind;
        mode  = r.cfg.mode;
        if (mode > 2) return;
        if (r.n_rd == 0)                                       sphase = 0;
        else if (r.state == dma_run::DONE || (mode != 0 && L != 0 && r.n_wr >= L)) sphase = 3;
        else if (mode == 0 && (r.n_rd >= L || all_queued))    sphase = 2;
        else                                                   sphase = 1;
        cg_stop.sample();
    endfunction

    function void sample_reg(ahb_item t, reg_kind_e k, int ch);
        rkind = k;
        rw    = t.write;
        resp  = t.resp;
        if (t.addr[1:0] != 0)                     akind = 2;
        else if (k == R_UNMAPPED)                 akind = 3;
        else if (t.write && t.strobe != 4'hF)     akind = 4;
        else if (t.size != 3'd2)                  akind = 1;
        else                                      akind = 0;
        cg_reg.sample();
    endfunction

    function void sample_trig(bit [7:0] cnt, longint credit_before);
        tcount  = cnt;
        tcredit = credit_before;
        cg_trig.sample();
    endfunction

    function void sample_trig_evt(int e);
        tevt = e;
        cg_trig_evt.sample();
    endfunction

    function void sample_trig_disarm(); sample_trig_evt(2); endfunction

    function void note_cause(int ch, int cause);
        cause_q[ch] = cause;
    endfunction

    function void sample_irq_clear(int others_set);
        nsrc = others_set;
        cg_irq_clear.sample();
    endfunction

    function void sample_active(int ch);
        chn = ch;
        cg_active.sample();
    endfunction

    function void sample_reset(dma_scoreboard scb);
        foreach (scb.chans[c]) begin
            dma_chan h = scb.chans[c];
            if (h.cur != null && h.cur.state inside {dma_run::RUNNING, dma_run::STOPPED} && h.running)
                sample_stop(2, h.cur, !h.enable.cur && !h.enable.pend && !h.enable.unknown);
        end
        irq_prev = 0;
    endfunction

    function void sample_edge(dma_scoreboard scb, longint T, bit irq);
        if (irq && !irq_prev) begin
            int n = 0, cause = -1;
            foreach (scb.chans[c]) begin
                dma_chan h = scb.chans[c];
                if (h.done.may_be(T, 1) || h.error.may_be(T, 1)) begin
                    n++;
                    if (cause < 0) cause = cause_q[c];
                end
            end
            icause = cause < 0 ? 3 : cause;
            nsrc   = n;
            cg_irq.sample();
        end
        irq_prev = irq;
    endfunction
endclass
