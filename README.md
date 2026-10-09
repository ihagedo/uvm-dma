# uvm-dma

Worked example 4 of the [SiliconBadgers UVM training](https://github.com/ihagedo/uvm-training). A complete UVM testbench for an AHB DMA controller with 2–32 channels, built from a spec and a test plan: three AHB agents, a register model, reactive memories that inject wait states and errors, a reference model that predicts every bus transfer, assertions, coverage, and a regression that must catch sixteen planted bugs.

![DMA block diagram](./docs/dma_controller_block.svg)

## Run it

From a `uvm-training` checkout (`git clone --recurse-submodules git@github.com:ihagedo/uvm-training.git`):

```bash
cd examples/dma
make run                       # Verilator (default), CONFIG=C1: 8 channels, FIFO_DEPTH=16
make run SIM=questa            # or xcelium, vcs
make run CONFIG=C3 TEST=dma_rand_err_test SEED=3
make run TEST=dma_restart_race_test ARGS=+SCB_TRACE
make run BUG=2                 # planted bug M2: DONE one write early
make waves                     # FST waves; open with gtkwave
make regress                   # Verilator: 17 tests, C1-C4, with coverage (about 30 min)
make mutants                   # Verilator: every planted bug must be caught
```

Set up the tools first; see the `uvm-training` README. Outside `uvm-training`, point `UVM_HOME` at the `src/` directory of a UVM 1.2 checkout.

A passing run ends with `*** TEST PASSED ***` and `PASS dma_smoke_test`.

## Layout

| Path | Contents |
|---|---|
| `rtl/` | The DUT, `dma_controller` and its submodules (see `rtl/README.md`) |
| `docs/` | Spec, test plan, block diagram |
| `agent/` | Interfaces, transactions, register-port manager, memory responders, monitors, agents, shared memory |
| `environment/` | Register model, reference model, scoreboard, coverage, environment, assertions |
| `test/` | Virtual sequences, tests, package |
| `top_tb/` | Top module: clock, interfaces, DUT, assertions, `run_test()` |
| `mutants/` | Planted bugs M1–M16 as `sed` scripts |
| `scripts/` | Regression and mutant runner |
| `results/` | Last `make regress` and `make mutants` reports |
| `probes/` | Directed checks behind the spec (`probes/run.sh`) |

## Walkthrough

Read the files in this order. Each step answers one question.

1. **What must the DMA do?** `docs/dma-spec.md`: register map, modes, protocol rules P1–P11, requirements R01–R27.
2. **What will be checked, and how?** `docs/dma-test-plan.md`: configurations C1–C4, test items, coverage, assertions, traceability.
3. **How does the testbench reach the DUT?** `top_tb/tb_top.sv` and `agent/dma_ahb_if.sv`: one AHB register port, two AHB memory ports, and the trigger, reset and interrupt pins.
4. **What is a transaction?** `agent/dma_item.svh`: an AHB transfer stamped with the edges of its address and data phases, a trigger or reset request, and a sample of the system pins.
5. **How does stimulus reach the pins?** `agent/dma_drivers.svh`. The register-port driver pipelines AHB transfers. The two memory responders answer the DMA from one shared memory (`agent/dma_mem.svh`), with wait-state profiles and injected errors.
6. **How are the ports observed?** `agent/dma_monitors.svh`: one monitor per port.
7. **How is a register written?** `environment/dma_regs.svh`, a `uvm_reg` model the sequences use for every register access.
8. **What should have happened?** `environment/dma_model.svh` and `environment/dma_scoreboard.svh`. The model predicts every memory transfer, register read and interrupt from the spec. Where the spec allows a range of cycles, a value carries a timing window instead of a single cycle.
9. **Which bus rules are checked?** `environment/dma_sva.sv`: AHB burst, wait-state and strobe rules, and the interrupt.
10. **What was exercised?** `environment/dma_coverage.svh`. `make regress` reports every bin, and the RTL lines that were missed.
11. **How is a test put together?** `test/dma_seqs.svh` and `test/dma_tests.svh`: one virtual sequence per test-plan row, plus random tests with errors, stops and register traffic.
12. **How do we know the testbench works?** `mutants/` and `make mutants`: each planted bug must fail at least one test.

## Exercises

1. Run `make run BUG=7`. It passes. Which single test catches M7 (`results/mutants.txt`), and why?
2. Run `make run TEST=dma_restart_race_test ARGS=+SCB_TRACE`. Find where the old run's items are dropped, and match it to R26 in the spec.
3. Run `make run CONFIG=C2 TEST=dma_bus_test` and compare its burst coverage with C1. Which spec rule explains the difference?
4. Add a test that runs one channel in each mode at the same time with slow memories. Add a row for it to the test plan and run it on C1 and C3.

## Results

`results/regress.txt`: 1 060 runs over C1–C4, all passing.

| Config | Runs passed | Functional coverage | Code coverage (line · branch) |
|---|---|---|---|
| C1 | 265/265 | 267/267 | 84.8% · 92.4% |
| C2 | 265/265 | 220/220 | 84.0% · 91.2% |
| C3 | 265/265 | 315/315 | 84.8% · 92.4% |
| C4 | 265/265 | 267/267 | 84.8% · 92.0% |

Code coverage holes:

| Where | Why |
|---|---|
| `ahb_read_manager.sv` `RD_FIFO_PUSH`, `tdata_fifo_full` paths | Unreachable: reads wait for room |
| `ahb_write_manager.sv` `WR_FIFO_PULL`, `tdata_fifo_empty` paths | Unreachable: writes wait for data |
| `ahb_write_manager.sv` `WR_FIRST_ADDR` with `HREADY` = 0 | No data phase is pending in a first address phase |
| `ahb_subordinate.sv` `request_stall` paths | `request_stall` tied to 0 |
| `channel_manager.sv` `default` items | Unaligned offsets rejected earlier |
| Other `default` branches | Fully decoded |
| Function bodies | Not counted by Verilator |

`results/mutants.txt`: all 16 planted bugs caught.

## History

Moved here from `examples/dma` of `ihagedo/uvm-onboarding`. The RTL is by the `DMA-zing` contributors, fixed to spec 1.2.
