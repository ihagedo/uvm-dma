// File:        dma_model.svh
// Author:      Isaac Hagedorn
// Date:        2026-10-08
// Description: Reference-model building blocks: register values with timing windows, copy runs and register decode.

class dma_hwval;
    bit [31:0] cur;
    bit        pend;
    bit [31:0] pend_val;
    longint    vis_from, vis_to;   // window in which the new value becomes visible
    bit        unknown;   // any value accepted until a read sees one

    static const longint MAXT = 64'h7FFF_FFFF_FFFF_FFFF;

    function new(bit [31:0] v = 0);
        cur = v;
    endfunction

    function void commit(longint T);
        if (pend && T >= vis_to) begin
            cur  = pend_val;
            pend = 0;
        end
    endfunction

    function void hw_event(bit [31:0] v, longint from, longint to, bit override = 0);
        if (override && pend && pend_val != v) begin
            pend_val = v; vis_from = from; vis_to = to;
            return;
        end
        if (pend && pend_val == v) begin
            if (from < vis_from) vis_from = from;
            if (to < vis_to)     vis_to   = to;
            return;
        end
        if (pend) unknown = 1;
        pend     = 1;
        pend_val = v;
        vis_from = from;
        vis_to   = to;
    endfunction

    function void sw_write(longint W, bit [31:0] v, bit hw_wins = 0);
        unknown = 0;
        if (pend) begin
            longint lo = vis_from - 1, hi = vis_to - 1;
            if (hi < W) begin
                pend = 0;
            end else if (lo > W || (hw_wins && lo == W && hi == W)) begin
                cur = v;
                return;
            end else if (lo == W && hi == W) begin
                pend = 0;
            end else begin
                cur     = v;
                unknown = (pend_val != v);
                pend    = 0;
                return;
            end
        end
        cur = v;
    endfunction

    function bit may_be(longint T, bit [31:0] v);
        commit(T);
        if (unknown) return 1;
        if (!pend || T < vis_from) return v == cur;
        return v == cur || v == pend_val;
    endfunction

    function void observe(longint T, bit [31:0] v);
        commit(T);
        if (unknown) begin
            cur = v; unknown = 0; pend = 0;
        end else if (pend && T >= vis_from && v == pend_val) begin
            cur = v; pend = 0;
        end
    endfunction

    function void settle();
        if (pend) begin
            cur  = pend_val;
            pend = 0;
        end
    endfunction

    function string str();
        if (unknown) return "unknown";
        if (pend) return $sformatf("%h->%h in [%0d,%0d]", cur, pend_val, vis_from, vis_to);
        return $sformatf("%h", cur);
    endfunction
endclass

class dma_xfer_cfg;
    bit [2:0] mode;
    bit [1:0] size;
    bit [7:0] sincr, dincr;
    bit [2:0] ring_size;
    bit       bsel;
    function new(bit [31:0] ctrl);
        mode = ctrl[6:4]; size = ctrl[1:0]; sincr = ctrl[15:8]; dincr = ctrl[23:16];
        ring_size = ctrl[30:28]; bsel = ctrl[31];
    endfunction
    function bit same(dma_xfer_cfg o);
        return mode == o.mode && size == o.size && sincr == o.sincr && dincr == o.dincr &&
               ring_size == o.ring_size && bsel == o.bsel;
    endfunction
    function string str();
        return $sformatf("%s size=%0d steps=%0d/%0d%s", mode == 0 ? "one-shot" : mode == 1 ? "continuous" :
                         mode == 2 ? "ring" : "invalid", size, sincr, dincr,
                         mode == 2 ? $sformatf(" ring=%0d sel=%0d", 1 << ring_size, bsel) : "");
    endfunction
endclass

typedef struct {
    bit [31:0] src, dst;
    bit [1:0]  size;
    bit [31:0] data;   // lane-extracted value read from the source
    longint    k;   // item number in the run
} dma_pend_t;

typedef struct {
    int        ch;
    dma_pend_t item;
    longint    kill_edge;
} dma_infl_t;

class dma_run;
    typedef enum {RUNNING, STOPPED, ERRORED, DONE, INVALID} state_e;

    int          ch, id;
    state_e      state;
    dma_xfer_cfg cfg, cfg_next;   // fields after a mid-run rewrite
    longint      cfg_next_edge;
    bit [31:0]   src0, dst0;   // SOURCE / DESTINATION
    bit [31:0]   len;   // DESIRED_TRANSFERS
    longint      start_edge, end_edge;
    longint      n_rd, n_wr;   // items read / written
    longint      n_dead_rd;   // reads after a kill (data dropped)
    bit          dead_open;   // reads of this run may still be on the bus after its kill
    bit          post_seen;   // an address phase after the kill has been seen
    int          dead_beats;   // INCR4 beats still to come after the kill
    longint      n_after_stop;   // items read after a disable / abort
    bit [31:0]   last_src, last_dst;
    dma_pend_t   pend[$];
    longint      err_edge;
    bit          rd_closed;   // no more reads can belong to this run

    function bit [31:0] pass_len();
        if (cfg.mode == 2) return 32'd1 << cfg.ring_size;
        return len;
    endfunction

    function void next_addr(dma_xfer_cfg c, output bit [31:0] s, output bit [31:0] d);
        bit [31:0] L = (c.mode == 2) ? (32'd1 << c.ring_size) : len;
        bit first = (L == 0) || (n_rd % L == 0);
        if (c.mode == 2) begin
            s = c.bsel ? src0 : (first ? src0 : last_src + c.sincr);
            d = c.bsel ? (first ? dst0 : last_dst + c.dincr) : dst0;
        end else begin
            s = first ? src0 : last_src + c.sincr;
            d = first ? dst0 : last_dst + c.dincr;
        end
    endfunction

    function bit wants_reads();
        if (rd_closed || (cfg.mode == 0 && n_rd >= len)) return 0;
        if (state == STOPPED) return n_after_stop < FDEPTH + 3;
        return state == RUNNING;
    endfunction

    function string str();
        return $sformatf("ch%0d run%0d (%s, %0d items from %h to %h, %s)", ch, id, cfg.str(), len,
                         src0, dst0, state.name());
    endfunction
endclass

function automatic bit [31:0] haddr(bit [31:0] a, bit [1:0] size);
    case (size)
        2'd0:    return a;
        2'd1:    return {a[31:1], 1'b0};
        default: return {a[31:2], 2'b00};
    endcase
endfunction

function automatic bit [3:0] lanes(bit [31:0] a, bit [1:0] size);
    case (size)
        2'd0:    return 4'b0001 << a[1:0];
        2'd1:    return a[1] ? 4'b1100 : 4'b0011;
        default: return 4'b1111;
    endcase
endfunction

function automatic bit [31:0] lane_extract(bit [31:0] w, bit [1:0] size, bit [31:0] a);
    case (size)
        2'd0:    return {24'd0, w[8 * a[1:0] +: 8]};
        2'd1:    return {16'd0, w[16 * a[1] +: 16]};
        default: return w;
    endcase
endfunction

function automatic bit [31:0] lane_place(bit [31:0] v, bit [1:0] size, bit [31:0] a);
    case (size)
        2'd0:    return v << (8 * a[1:0]);
        2'd1:    return v << (16 * a[1]);
        default: return v;
    endcase
endfunction

typedef enum {R_SOURCE, R_DESTINATION, R_CONTROL, R_DESIRED, R_COMPLETED, R_REMAINING, R_ACTIVE,
              R_ERRADDR, R_TCFG, R_TSTAT, R_UNMAPPED} reg_kind_e;

function automatic reg_kind_e decode_reg(bit [31:0] a, output int ch);
    bit [31:0] off = a - REG_BASE;
    ch = 0;
    if (a < REG_BASE || off >= 32'h1000 || a[1:0] != 0 || off >= 40 * NCH) return R_UNMAPPED;
    if (off < 16 * NCH) begin
        ch = off / 16;
        case (off[3:2]) 0: return R_SOURCE; 1: return R_DESTINATION; 2: return R_CONTROL; default: return R_DESIRED; endcase
    end
    if (off < 32 * NCH) begin
        ch = (off - 16 * NCH) / 16;
        case (off[3:2]) 0: return R_COMPLETED; 1: return R_REMAINING; 2: return R_ACTIVE; default: return R_ERRADDR; endcase
    end
    ch = (off - 32 * NCH) / 8;
    return off[2] ? R_TSTAT : R_TCFG;
endfunction

function automatic int src_owner(bit [31:0] a);
    if (a < SRC_AREA || a >= SRC_AREA + NCH * AREA_SIZE) return -1;
    return (a - SRC_AREA) / AREA_SIZE;
endfunction

function automatic int dst_owner(bit [31:0] a);
    if (a < DST_AREA || a >= DST_AREA + NCH * AREA_SIZE) return -1;
    return (a - DST_AREA) / AREA_SIZE;
endfunction
