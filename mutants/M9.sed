# M9 (R10): halfword write strobes pick the wrong half of the word
# file: source/ahb_write_manager.sv
s/dphase_addr\[1\] ? 4'b1100 : 4'b0011/dphase_addr[1] ? 4'b0011 : 4'b1100/g
