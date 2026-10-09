# `rtl/`: the design under test

An AHB DMA controller by the `DMA-zing` contributors, fixed to match spec 1.2 (`../docs/dma-spec.md`, sections 12 and 13).

| File | Contents |
|---|---|
| `source/dma_controller.sv` | Top level: engine, three queues, two AHB managers; parameter checks |
| `source/dma_engine.sv` | Registers, triggers, arbiter, address generator |
| `source/channel_manager.sv`, `channel_csr.sv` | Register map, run control, `DONE`/`ERROR`, status |
| `source/address_generator.sv` | Source and destination addresses for the granted channel |
| `source/dma_arbiter.sv` | Round robin over requesting channels |
| `source/trigger_controller.sv` | Trigger edges, credits, trigger registers |
| `source/ahb_read_manager.sv`, `ahb_write_manager.sv` | AHB managers with INCR4 bursts |
| `source/ahb_subordinate.sv` | Register-port front end |
| `source/dma_fifo.sv` | Queue that drops a channel's entries in one cycle |
| `include/` | `ahb_if`, `bus_protocol_if`, `socetlib_counter`, `ahb_pkg` |

## What the testbench needs to know

- Registers sit at `0x9000_1000` on the subordinate port; memories sit behind the two manager ports.
- A bus error, or a restart of a stopped channel, drops that channel's queued items. Reads already on the bus still complete, and a write whose address phase was accepted still lands.
- Invalid configurations (`MODE` 3–7, `SIZE` = 3, zero length) set `DONE` with no bus traffic.
- Bursts need `FIFO_DEPTH` ≥ 8 and never cross a 1 KB boundary.
