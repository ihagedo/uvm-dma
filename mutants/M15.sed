# M15 (R08): a continuous pass is one item too long
# file: source/address_generator.sv
s/(arb_strobe && mode != RINGBUFFER) ? sel_transfer_amount\[DATA_SIZE-1:0\] : '1;/(arb_strobe \&\& mode != RINGBUFFER) ? sel_transfer_amount[DATA_SIZE-1:0] + 1 : '1;/
