# `dma_controller` test plan

| | |
|---|---|
| RTL | `rtl/source/dma_controller.sv` |
| Spec | `dma-spec.md` version 1.2 |
| CSV | `dma-test-plan.csv`: configurations, test items, coverage and assertions, one row each |

## 1. Scope

In scope: `dma_controller`, requirements R01–R27, protocol rules P1–P11.

| Out of scope | Covered by |
|---|---|
| Submodule unit checks | `probes/dma_probe_tb.sv` |
| SoC integration | System tests |
| Synthesis, timing, gate level | Physical design flow |

## 2. Configurations

| Config | Parameters | Why |
|---|---|---|
| C1 | `NUM_CHANNELS`=8, `FIFO_DEPTH`=16 | Defaults |
| C2 | `NUM_CHANNELS`=2, `FIFO_DEPTH`=4 | Smallest legal |
| C3 | `NUM_CHANNELS`=32, `FIFO_DEPTH`=16 | Most channels |
| C4 | `NUM_CHANNELS`=8, `FIFO_DEPTH`=32 | Deep queues |

Memory responder wait-state profiles: zero, fixed, random, bursty.

## 3. Testbench architecture

```
dma_test
 └─ dma_env
     ├─ cfg_agent: AHB manager on the register port, register model
     ├─ rd_agent:  AHB responder on the read port
     ├─ wr_agent:  AHB responder on the write port
     ├─ sys_agent: trigger_in, nRST, dma_interrupt
     ├─ dma_mem:   memory shared by both responders
     ├─ dma_scoreboard: reference model and checks
     └─ dma_coverage
dma_sva bound to the DUT
```

## 4. Test items

| ID | Req | Scenario | Expected | Test | Status |
|---|---|---|---|---|---|
| T01 | R03 | Read every register after reset | Reset values | `dma_reg_test` | Passing |
| T02 | R01 | Bit-bash every RW field | Read-back matches | `dma_reg_test` | Passing |
| T03 | R04 | Write status registers | Unchanged | `dma_reg_test` | Passing |
| T04 | R02 | Partial writes | ERROR, unchanged | `dma_reg_test` | Passing |
| T05 | R02 | Unaligned and unmapped accesses | ERROR | `dma_reg_test` | Passing |
| T06 | R01 | Back-to-back register transfers | Zero wait states | `dma_reg_test` | Passing |
| T07 | R05 | Enable after an error | Status reset | `dma_error_test` | Passing |
| T08 | R06 R07 | One-shot lengths 1 to 1000 | Correct data, `DONE`, status | `dma_copy_test` | Passing |
| T09 | R06 R10 | Every size, step and alignment | Only addressed bytes change | `dma_copy_test` | Passing |
| T10 | R06 | Data patterns | Exact data | `dma_copy_test` | Passing |
| T11 | R06 R19 | All channels at once | All correct, round robin | `dma_channels_test` | Passing |
| T12 | R12 | Overlapping `DONE` and `ERROR` | Interrupt = OR of bits | `dma_copy_test` | Passing |
| T13 | R07 R08 | Continuous, then stop | Repeats; `DONE` per pass, none after the stop | `dma_modes_test` | Passing |
| T14 | R09 | Ring, every `RING_SIZE` and side | Wraps; `DONE` per pass | `dma_modes_test` | Passing |
| T15 | R19 | Ring or continuous with a one-shot | Grant rules hold | `dma_channels_test` | Passing |
| T16 | R11 | Copies that can burst | INCR4 exactly when allowed | `dma_bus_test` | Passing |
| T17 | P8 | Every wait-state profile | Data and order correct | `dma_bus_test` | Passing |
| T18 | R11 | Bursts near a 1 KB boundary | No INCR4 crosses 1 KB | `dma_bus_test` | Passing |
| T19 | R27 | Sub-word items at every lane | `HADDR` = item address; strobes in its lanes | `dma_copy_test` | Passing |
| T20 | R18 | `SIZE`=3 | `DONE`, no traffic | `dma_corner_test` | Passing |
| T21 | R13 | Read error at each item position | Channel stops, `ERROR_ADDRESS` | `dma_error_test` | Passing |
| T22 | R13 R27 | Write error at each item position | As T21; bursts finish; waited data held | `dma_error_test` | Passing |
| T23 | R13 | Errors while other channels run | Others finish | `dma_error_test` | Passing |
| T24 | R14 | Re-enable after each error | Correct copy | `dma_error_test` | Passing |
| T25 | R15 | Abort at random points, every mode | Stops, no `DONE` | `dma_stop_test` | Passing |
| T26 | R16 | Disable at random points | As T25 | `dma_stop_test` | Passing |
| T27 | R17 | `ENABLE`=1 rewrite while running | No restart | `dma_stop_test` | Passing |
| T28 | R07 | `CONTROL` write in the completion cycle | `DONE` still sets | `dma_corner_test` | Passing |
| T29 | R03 | Reset during traffic | Clean reset, next copy works | `dma_stop_test` | Passing |
| T30 | R18 | Invalid `MODE`, zero length | `DONE`, no traffic | `dma_bad_cfg_test` | Passing |
| T31 | R18 | Continuous with zero length | `DONE`, no traffic | `dma_corner_test` | Passing |
| T32 | R21 | Arm a non-ring channel, then disarm and start | Stops, nothing moves; then copies | `dma_trigger_test` | Passing |
| T33 | R20 | Trigger pacing, several `COUNT` | Items ≤ credits | `dma_trigger_test` | Passing |
| T34 | R20 | Credit saturation | `OVERRUN` set, then cleared | `dma_trigger_test` | Passing |
| T35 | R20 | Disarm with credit | `CREDIT` = 0 | `dma_trigger_test` | Passing |
| T36 | R11 R20 | Triggered bursts | Bursts, one credit per item | `dma_trigger_test` | Passing |
| T37 | all | Random channels and modes | No mismatches | `dma_rand_test` | Passing |
| T38 | R13 R14 | Random plus random errors | Only faulted channels stop | `dma_rand_err_test` | Passing |
| T39 | R03 R15 R16 | Random plus stops and resets | Clean stops | `dma_rand_stop_test` | Passing |
| T40 | R01–R04 | Random register traffic during copies | Register model matches | `dma_rand_reg_test` | Passing |
| T41 | R24 | Everything in C1–C4 | Same results | `make regress` | Passing |
| T43 | R24 | `NUM_CHANNELS` = 1, 3, 64 | Elaboration error | `make regress` | Passing |
| T44 | R26 | Restart while old writes drain | Old items dropped; `DONE` only after the new copy | `dma_restart_race_test` | Passing |
| T45 | R25 | 64-word copy before and after 20 write errors | No slower after; within N + 12 cycles if `FIFO_DEPTH` ≥ 8 | `dma_perf_test` | Passing |
| T46 | R18 | `SIZE`=3 written to a running continuous channel | `DONE`; queued items finish; nothing new | `dma_corner_test` | Passing |

## 5. Coverage

| Covergroup | Bins | Rows |
|---|---|---|
| `cg_cfg` | Mode × size, steps, lengths | T08, T09, T13, T14 |
| `cg_ring` | `RING_SIZE` × `BUFFER_SEL` | T14 |
| `cg_conc` | Channels active at once, mode pairs | T11, T15, T37 |
| `cg_bus` | SINGLE/INCR4 × port, wait states | T16, T17 |
| `cg_error` | Port × item position × mode | T21–T23, T38 |
| `cg_stop` | Abort/disable/reset × point in the copy × mode | T25, T26, T29, T39 |
| `cg_reg` | Register × read/write × response | T01–T06, T40 |
| `cg_trig`, `cg_trig_evt` | `COUNT`, `CREDIT`, `OVERRUN`, disarm | T33–T36 |
| `cg_irq`, `cg_irq_clear` | Interrupt causes, clears | T12 |
| `cg_active` | `CURRENT_CHANNEL_ACTIVE` per channel | T11 |

Code coverage target: 100% line and branch, holes explained.

### 5.1 Covergroup definitions

The covergroups are in `environment/dma_coverage.svh`. The scoreboard samples them at the points named below. Goal: every bin hit at least once in every configuration. `CH[]` has one bin per channel, so its size follows `NUM_CHANNELS`.

**`cg_cfg`**: each time software starts a channel (`CONTROL` written with `ENABLE` = 1 while stopped).

| Item | Bins |
|---|---|
| `cp_mode` | `MODE`: `ONESHOT` 0; `CONTINUOUS` 1; `RING` 2; `INVALID` 3–7 |
| `cp_size` | `SIZE`: `BYTE` 0; `HALF` 1; `WORD` 2 |
| `mode_x_size` | `cp_mode` × `cp_size` |
| `cp_sinc`, `cp_dinc` | `SOURCE_INCR`, `DEST_INCR` against the item size: `ZERO` 0; `EQ_SIZE` the item size; `TWICE` twice the item size; `MAX255` 255; `OTHER` any other step |
| `cp_len` | `DESIRED_TRANSFERS`: `L1` 1; `L2_3` 2–3; `L4` 4; `L5_15` 5–15; `L16` 16; `L17` 17; `L18_255` 18–255; `L256_UP` 256 and up. Not counted in ring mode or at zero length |

**`cg_ring`**: at the same start, ring mode only.

| Item | Bins |
|---|---|
| `cp_rsize` | `RING_SIZE`: `RS[0]`–`RS[7]`, one bin per value |
| `cp_bsel` | `BUFFER_SEL`: `SRC_STEPS` 0; `DST_STEPS` 1 |
| `rsize_x_bsel` | `cp_rsize` × `cp_bsel` |

**`cg_conc`**: at the same start.

| Item | Bins |
|---|---|
| `cp_active` | Channels running, this one included: `ONE` 1; `TWO` 2; `SOME` 3 to `NUM_CHANNELS`−1; `ALL` `NUM_CHANNELS` |
| `cp_chan` | Starting channel: `CH[0]` to `CH[NUM_CHANNELS−1]` |
| `cp_pair` | Modes of this channel and the first other running channel: `OS_OS` both one-shot; `OS_RING` one-shot and ring; `RING_RING` both ring; `CONT_ANY` either continuous. Not counted when the channel runs alone |

**`cg_bus`**: every data beat on the read or write port.

| Item | Bins |
|---|---|
| `cp_port` | `RD` read port; `WR` write port |
| `cp_burst` | `SINGLE`; `INCR4` |
| `port_x_burst` | `cp_port` × `cp_burst` |
| `cp_waits` | Wait states on the beat: `W0` 0; `W1` 1; `W2_4` 2–4; `W5_UP` 5 and up |
| `cp_beat` | `SINGLE`; `B0`–`B3` beat of an INCR4 burst |
| `waits_x_beat` | `cp_waits` × `cp_beat` |

**`cg_error`**: every ERROR response on the read or write port.

| Item | Bins |
|---|---|
| `cp_port` | `RD`; `WR` |
| `cp_pos` | Failing item in the copy or pass: `FIRST`; `MIDDLE`; `LAST` |
| `cp_beat` | `SINGLE`; `B0`–`B3` beat of an INCR4 burst |
| `cp_mode` | `ONESHOT`; `CONTINUOUS`; `RING` |
| `cp_others` | `ALONE`; `WITH_OTHERS` another channel running |
| `port_x_pos`, `port_x_beat`, `port_x_mode`, `port_x_others` | `cp_port` × each of the other items |

**`cg_stop`**: each stop of a channel in a valid mode, by software (`ABORT`, or `ENABLE` = 0) or by reset while running.

| Item | Bins |
|---|---|
| `cp_kind` | `ABORT` `ABORT` = 1 with `ENABLE` = 0; `DISABLE` `ENABLE` = 0; `RESET` `nRST` |
| `cp_phase` | `BEFORE_FIRST_READ` no item read yet; `MID` copying; `LAST_WRITES` one-shot with every item read, writes pending; `AFTER_DONE` one-shot done, or a full pass written in continuous or ring |
| `cp_mode` | `ONESHOT`; `CONTINUOUS`; `RING` |
| `kind_x_phase`, `kind_x_mode` | `cp_kind` × `cp_phase`; `cp_kind` × `cp_mode` |

**`cg_reg`**: every transfer on the register port.

| Item | Bins |
|---|---|
| `cp_reg` | `SOURCE`; `DESTINATION`; `CONTROL`; `DESIRED` `DESIRED_TRANSFERS`; `COMPLETED` `TRANSFERS_COMPLETED`; `REMAINING` `TRANSFERS_REMAINING`; `ACTIVE` `CURRENT_CHANNEL_ACTIVE`; `ERRADDR` `ERROR_ADDRESS`; `TCFG` `TRIGGER_CONFIG`; `TSTAT` `TRIGGER_STATUS`; `UNMAPPED` no register |
| `cp_rw` | `READ`; `WRITE` |
| `cp_resp` | `OKAY`; `ERROR` |
| `reg_x_rw_x_resp` | `cp_reg` × `cp_rw` × `cp_resp` |
| `cp_access` | `WORD` aligned word; `SUBWORD_AT_0` aligned byte or halfword; `UNALIGNED` address not word-aligned; `UNMAPPED` no register; `PARTIAL_STROBE` write with `HWSTRB` ≠ `4'hF` |

**`cg_trig`**: each trigger edge on an armed channel's line.

| Item | Bins |
|---|---|
| `cp_count` | `COUNT`: `ZERO` 0; `ONE` 1; `MID` 2–254; `MAX` 255 |
| `cp_credit` | `CREDIT` before the edge: `ZERO` 0; `ONE` 1; `MID` 2–4094; `MAX` 4095 |

**`cg_trig_evt`**: each of the three trigger events below.

| Item | Bins |
|---|---|
| `cp_evt` | `OVERRUN_SEEN` `TRIGGER_STATUS` read with `OVERRUN` = 1; `OVERRUN_CLEARED` `TRIGGER_STATUS` written while `OVERRUN` may be set; `DISARM_WITH_CREDIT` `ARM` = 0 written with `CREDIT` > 0 |

**`cg_irq`**: each rising edge of `dma_interrupt`.

| Item | Bins |
|---|---|
| `cp_cause` | What last set `DONE` or `ERROR` on the first channel with one set: `ONESHOT_DONE` one-shot copy finished; `PASS_DONE` continuous or ring pass finished; `BUS_ERROR` bus error; `SW_WRITE` software wrote `DONE` or `ERROR` = 1 |
| `cp_srcs` | Channels with `DONE` or `ERROR` set: `ONE` 1; `SEVERAL` 2 and up |

**`cg_irq_clear`**: each `CONTROL` write that clears a set `DONE` or `ERROR`.

| Item | Bins |
|---|---|
| `cp_others` | Other channels with `DONE` or `ERROR` still set: `LAST_ONE` none, so the interrupt falls; `OTHERS_STILL_SET` 1 and up |

**`cg_active`**: each `CURRENT_CHANNEL_ACTIVE` read that returns a nonzero value.

| Item | Bins |
|---|---|
| `cp_chan` | Channel read: `CH[0]` to `CH[NUM_CHANNELS−1]` |

## 6. Assertions

| ID | Property | Spec rule |
|---|---|---|
| SVA01 | INCR4 beats are consecutive | P7 |
| SVA02 | Address and control stable while `HREADY`=0 | AHB |
| SVA03 | `HSIZE` ≤ word | P6 |
| SVA04 | No INCR4 crosses 1 KB | P7 |
| SVA05 | `HWSTRB` within `HADDR`/`HSIZE` | P6 |
| SVA06 | `BUSY` only inside a burst | AHB |
| SVA07 | Mapped register access: zero wait states, OKAY | P3 |
| SVA08 | ERROR response is two cycles | P4 |
| SVA09 | Interrupt = OR of `DONE` \| `ERROR` | R12 |
| SVA11 | Write data and strobes stable while waited | P8 |
| SVA12 | INCR4 runs four beats unless ERROR | P7 |

## 7. Traceability

| Requirement | Tests | Coverage | Assertions |
|---|---|---|---|
| R01 | T02 T06 T40 | `cg_reg` | SVA07 |
| R02 | T04 T05 T40 | `cg_reg` | SVA08 |
| R03 | T01 T29 T39 | `cg_stop` | — |
| R04 | T03 | `cg_reg` | — |
| R05 | T07 | — | — |
| R06 | T08–T11 T37 | `cg_cfg` | — |
| R07 | T08 T13 T28 | `cg_irq` | — |
| R08 | T13 | `cg_cfg` | — |
| R09 | T14 | `cg_ring` | — |
| R10 | T09 T19 | `cg_cfg` | — |
| R11 | T16 T18 T36 | `cg_bus` | SVA01 SVA04 |
| R12 | T12 | `cg_irq` | SVA09 |
| R13 | T21–T23 T38 | `cg_error` | — |
| R14 | T24 T38 | `cg_error` | — |
| R15 | T25 T39 | `cg_stop` | — |
| R16 | T26 T39 | `cg_stop` | — |
| R17 | T27 | — | — |
| R18 | T20 T30 T31 T46 | `cg_cfg` | — |
| R19 | T11 T15 | `cg_conc` | — |
| R20 | T33–T36 | `cg_trig` | — |
| R21 | T32 | `cg_trig` | — |
| R22 | T07 T08 T13 T21 | — | — |
| R23 | T11 | `cg_active` | — |
| R24 | T41 T43 | — | — |
| R25 | T45 | — | — |
| R26 | T44 | — | — |
| R27 | T17 T19 T22 T38 | `cg_bus` `cg_error` | SVA01–SVA06 SVA11 SVA12 |

## 8. Exit criteria

- [x] Every row passing in C1–C4.
- [x] Random tests: 50 seeds per configuration, all passing.
- [x] 100% functional coverage.
- [x] Code coverage holes explained.
- [x] Every mutant caught.
- [x] No open bugs.

## 9. Bugs

| ID | Found by | Description | Status |
|---|---|---|---|
| B1 | Probe | `DONE` lost on a same-cycle `CONTROL` write (Q3) | Fixed |
| B2 | Probe | Armed non-ring channel stuck (Q5) | Fixed |
| B3 | Probe | `CURRENT_CHANNEL_ACTIVE` 0 for channels ≥ 32 (Q8) | Fixed: more than 32 channels is illegal |
| B4 | Probe | Sub-word `HADDR` (Q7); `SIZE`=3 (Q10) | Fixed |
| B5 | Reading | `ahb_pkg.sv` swaps `SEQ` and `BUSY` (Q13) | Fixed |
| B6 | Reading | DMA-zing CI passes a hung or crashed simulation | Not applicable: that CI is not part of this example |
| B7 | Scoreboard | `DONE` after a stop (Q14) | Fixed |
| B8 | Scoreboard | Re-enable counts old writes (Q17) | Fixed |
| B9 | SVA11, SVA12 | Kill breaks AHB rules (Q15, Q16) | Fixed |
| B10 | Coverage | `committed` counter leak (Q18) | Fixed |
| B11 | Scoreboard | `ENABLE` lost during a held write error (Q19) | Fixed |
| B12 | Coverage | No bursts with `FIFO_DEPTH` < 6 (Q20) | Closed: intended (spec L6) |
| B13 | Mutants | Bench missed a fixed-priority arbiter | Fixed |
| B14 | SVA04 | Bursts cross 1 KB | Fixed |

## 10. Revision history

Revisions A to E are example entries for the course. The real history of this document starts at 0.1.

| Version | Date | Spec version | Change |
|---|---|---|---|
| A | 2024-02-23 | A | First test list: register access and one-shot copies |
| B | 2024-05-10 | B | Channel status and interrupt tests |
| C | 2024-09-20 | C | Ring and trigger tests |
| D | 2025-02-14 | D | Arbitration and error tests |
| E | 2025-07-11 | E | Configurations for 2 and 32 channels |
| 0.1 | 2026-10-06 | 1.0 | First draft |
| 0.2 | 2026-10-08 | 1.1 | Bench built; T44, T45, SVA11, SVA12, B7–B13 |
| 0.3 | 2026-10-08 | 1.2 | RTL fixed; waivers and expected fails removed; C5 dropped |
| 0.4 | 2026-10-12 | 1.2 | Covergroup definitions (5.1); CSV version |
