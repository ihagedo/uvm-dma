# M8 (R09): a source-stepping ring uses DEST_INCR as its step
# file: source/address_generator.sv
s/recent_ring_address\[control\] + source_incr/recent_ring_address[control] + dest_incr/g
