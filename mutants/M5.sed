# M5 (R02): reads of unmapped offsets answer OKAY instead of ERROR
# file: source/channel_manager.sv
s/invalid_address = !mapped_address && (ren | wen);/invalid_address = !mapped_address \&\& wen;/
