# M11 (R11, P7): halfword items are put in INCR4 read bursts too
# file: source/ahb_read_manager.sv
s/(raddr_fifo_rdata\[DATA_SIZE+1:DATA_SIZE\] == 2'b10) && consecutive_words;/(raddr_fifo_rdata[DATA_SIZE+1:DATA_SIZE] != 2'b00) \&\& consecutive_words;/
