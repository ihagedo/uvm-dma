# M7 (R20): an armed ring channel ignores its trigger credit
# file: source/channel_manager.sv
s/(!trigger_armed\[i\] || trigger_credit\[i\]);/1'b1;/
