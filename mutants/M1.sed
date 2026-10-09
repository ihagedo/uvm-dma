# M1 (R12): the interrupt ignores ERROR (only DONE raises it)
# file: source/dma_engine.sv
s/if (channel_control\[i\]\[27\] || channel_control\[i\]\[26\]) dma_interrupt/if (channel_control[i][27]) dma_interrupt/
