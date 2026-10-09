# M14 (R03): DESIRED_TRANSFERS resets to 1 instead of 0
# file: source/channel_csr.sv
s/      transfer_amount <= '0;/      transfer_amount <= 32'd1;/
