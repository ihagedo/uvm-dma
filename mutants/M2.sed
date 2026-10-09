# M2 (R07): a one-shot copy sets DONE one write early
# file: source/channel_manager.sv
s/(transfers_completed\[i\] == transfer_amount\[i\]);/(transfers_completed[i] + 1 == transfer_amount[i]);/
