# M12 (R04, R20): a write to TRIGGER_STATUS also clears CREDIT
# file: source/trigger_controller.sv
s/if (status_write && !saturated\[reg_channel\]) next_overrun\[reg_channel\] = 1'b0;/if (status_write \&\& !saturated[reg_channel]) begin next_overrun[reg_channel] = 1'b0; next_credit[reg_channel] = '0; end/
