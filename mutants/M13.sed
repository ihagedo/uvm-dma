# M13 (R19): the arbiter always searches from channel 0 (fixed priority, not round robin)
# file: source/dma_arbiter.sv
s/grant_idx = IDX_WIDTH'(i) + channel_select;/grant_idx = IDX_WIDTH'(i);/
