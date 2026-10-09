# M3 (R13): a read ERROR does not clear the channel's ENABLE
# file: source/channel_manager.sv
/if (rd_err) next_control\[read_error_channel\]\[7\] = 0;/d
