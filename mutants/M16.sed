# M16 (R10, P6): a halfword read takes the wrong half of HRDATA
# file: source/ahb_read_manager.sv
s/2'b01:   return {16'd0, word\[16\*lane\[1\]+:16\]};/2'b01:   return {16'd0, word[16*lane[0]+:16]};/
