// File:        dma_mem.svh
// Author:      Isaac Hagedorn
// Date:        2026-10-08
// Description: Memory shared by the two responders, and each responder's wait-state and error settings.

class dma_mem extends uvm_object;
    `uvm_object_utils(dma_mem)

    bit [7:0] bytes[bit [31:0]];
    bit       bus_written[bit [31:0]];   // bytes changed by the DUT's write port

    function new(string name = "dma_mem");
        super.new(name);
    endfunction

    static function bit [7:0] background(bit [31:0] a);
        bit [31:0] h = a * 32'h9E37_79B1;
        return h[31:24] ^ h[7:0];
    endfunction

    function bit [7:0] get_byte(bit [31:0] a);
        return bytes.exists(a) ? bytes[a] : background(a);
    endfunction

    function bit [31:0] read_word(bit [31:0] a);
        bit [31:0] w;
        a[1:0] = 0;
        for (int i = 0; i < 4; i++) w[8*i +: 8] = get_byte(a + i);
        return w;
    endfunction

    function void write_word(bit [31:0] a, bit [31:0] w, bit [3:0] strb = 4'hF);
        a[1:0] = 0;
        for (int i = 0; i < 4; i++) if (strb[i]) bytes[a + i] = w[8*i +: 8];
    endfunction

    function void bus_write(bit [31:0] a, bit [31:0] w, bit [3:0] strb);
        a[1:0] = 0;
        for (int i = 0; i < 4; i++)
            if (strb[i]) begin
                bytes[a + i]       = w[8*i +: 8];
                bus_written[a + i] = 1;
            end
    endfunction
endclass

class dma_resp_cfg extends uvm_object;
    `uvm_object_utils(dma_resp_cfg)

    typedef enum {ZERO, FIXED, RANDOM, BURSTY} profile_e;
    profile_e    profile = ZERO;
    int unsigned fixed_n = 1;
    int unsigned rnd_max = 8;   // max wait states for RANDOM
    int unsigned err_permille;   // random ERROR rate, per mille
    int unsigned err_lo = 32'h0000_0000, err_hi = 32'hFFFF_FFFF;   // address range for random errors

    int unsigned fault_nth[bit [31:0]];
    int unsigned hits[bit [31:0]];
    int unsigned n_injected;

    function new(string name = "dma_resp_cfg");
        super.new(name);
    endfunction

    function void set_profile(profile_e p, int unsigned n = 1);
        profile = p;
        if (p == FIXED)  fixed_n = n;
        if (p == RANDOM) rnd_max = n;
    endfunction

    function void add_fault(bit [31:0] a, int unsigned nth = 1);
        a[1:0] = 0;
        fault_nth[a] = hits.exists(a) ? hits[a] + nth : nth;
    endfunction

    function void clear_faults();
        fault_nth.delete();
        err_permille = 0;
    endfunction

    function int unsigned pick_waits();
        case (profile)
            ZERO:    return 0;
            FIXED:   return fixed_n;
            RANDOM:  return $urandom_range(rnd_max);
            BURSTY:  return ($urandom_range(99) < 90) ? 0 : 20;
        endcase
        return 0;
    endfunction

    function bit pick_error(bit [31:0] a);
        a[1:0] = 0;
        hits[a] = hits.exists(a) ? hits[a] + 1 : 1;
        if (fault_nth.exists(a) && fault_nth[a] == hits[a]) begin
            fault_nth.delete(a);
            n_injected++;
            return 1;
        end
        if (err_permille && a >= err_lo && a <= err_hi && $urandom_range(999) < err_permille) begin
            n_injected++;
            return 1;
        end
        return 0;
    endfunction
endclass
