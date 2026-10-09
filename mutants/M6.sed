# M6 (R15): ABORT never clears itself
# file: source/channel_manager.sv
s/          next_control\[i\]\[24\] = 0;/          next_control[i][24] = next_control[i][24];/
