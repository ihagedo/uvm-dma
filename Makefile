# File:        Makefile
# Author:      Isaac Hagedorn
# Date:        2026-10-09
# Description: Build and run the DMA example on Verilator (default), Questa, Xcelium or VCS. Run `make help`.

# verilator | questa | xcelium | vcs
SIM      ?= verilator
# parameter set C1..C4 (see docs/dma-test-plan.md)
CONFIG   ?= C1
# UVM test to run
TEST     ?= dma_smoke_test
# random seed
SEED     ?= 1
# UVM verbosity
VERB     ?= UVM_LOW
# extra plusargs, e.g. +SCB_TRACE or +BUS_TRACE=100,200
ARGS     ?=
# n: build the DUT with planted bug Mn (mutants/Mn.sed)
BUG      ?= 0
# planted bug that check-bug expects the default test to catch
CHECK_BUG ?= 2
# 1: dump waves (FST on Verilator, VCD elsewhere)
WAVES    ?= 0
# Verilator build jobs
JOBS     ?= $(shell nproc 2>/dev/null || echo 4)
# seeds per directed test, per random test, and configurations for regress
SEEDS    ?= 5
RAND_SEEDS ?= 50
CONFIGS  ?= C1 C2 C3 C4

ROOT     := $(abspath .)
# Accellera UVM 1.2 source: the UVM_Library submodule of uvm-training, or a sibling clone
UVM_HOME ?= $(firstword $(wildcard $(ROOT)/../../UVM_Library/src $(ROOT)/../UVM_Library/src))

NCH_C1   := 8
FD_C1    := 16
NCH_C2   := 2
FD_C2    := 4
NCH_C3   := 32
FD_C3    := 16
NCH_C4   := 8
FD_C4    := 32
NCH      := $(NCH_$(CONFIG))
FD       := $(FD_$(CONFIG))
ifeq ($(NCH),)
  $(error CONFIG must be one of C1..C4)
endif

RTL_FILES := include/ahb_if.sv include/bus_protocol_if.sv include/socetlib_counter.sv \
             source/dma_fifo.sv source/channel_csr.sv source/channel_manager.sv \
             source/trigger_controller.sv source/dma_arbiter.sv source/address_generator.sv \
             source/ahb_subordinate.sv source/dma_engine.sv source/ahb_read_manager.sv \
             source/ahb_write_manager.sv source/dma_controller.sv
TOP      := tb_top
BUILD    := $(ROOT)/build/$(SIM)_$(CONFIG)$(if $(filter-out 0,$(BUG)),_bug$(BUG))$(if $(filter 1,$(WAVES)),_waves)
# RTL file the planted bug changes (line 2 of its sed script)
MUT_FILE := $(if $(filter-out 0,$(BUG)),$(shell sed -n '2s/^# file: //p' $(ROOT)/mutants/M$(BUG).sed))
DUT      := $(foreach f,$(RTL_FILES),$(if $(filter $(f),$(MUT_FILE)),$(BUILD)/mut/$(notdir $(f)),$(ROOT)/rtl/$(f)))
INCS     := +incdir+$(UVM_HOME) +incdir+$(ROOT)/rtl/include +incdir+$(ROOT)/agent +incdir+$(ROOT)/environment \
            +incdir+$(ROOT)/test
SRCS     := $(DUT) $(ROOT)/agent/dma_ahb_if.sv $(ROOT)/environment/dma_sva.sv $(ROOT)/test/dma_tb_pkg.sv \
            $(ROOT)/top_tb/tb_top.sv
DEPS     := $(wildcard $(ROOT)/rtl/*/* $(ROOT)/agent/* $(ROOT)/environment/* $(ROOT)/test/* $(ROOT)/top_tb/*)
DEFS     := +define+UVM_NO_DPI +define+DMA_NCH=$(NCH) +define+DMA_FDEPTH=$(FD) \
            $(if $(filter 1,$(WAVES)),+define+WAVES)
PLUSARGS := +UVM_TESTNAME=$(TEST) +UVM_VERBOSITY=$(VERB) $(ARGS)
RUNDIR   := $(BUILD)/runs/$(TEST)_s$(SEED)
STAMP    := $(BUILD)/.built

# On CAE machines the commercial simulators only run inside these container wrappers.
# The conda env's compilers (on PATH for Verilator) link against a newer glibc than the
# containers have, so the wrappers get PATH without the conda env.
CLEAN_PATH := $(if $(CONDA_PREFIX),$(subst $(CONDA_PREFIX)/bin:,,$(PATH)),$(PATH))
wrap = $(if $(shell command -v $(1) 2>/dev/null),env PATH=$(CLEAN_PATH) $(1))

ifeq ($(SIM),verilator)
  TOOL      := verilator
  HINT      := source env/setup.sh in uvm-training (or: module load conda-forge/26.3.2 && conda activate ~/.conda/envs/sb-uvm)
  BUILD_CMD := verilator --binary --timing --assert -j $(JOBS) --timescale 1ns/1ps -Wno-fatal -Wno-lint -Wno-style \
               -Wno-MULTIDRIVEN -Werror-USERERROR --coverage-user --coverage-line --coverage-toggle --coverage-expr \
               $(if $(filter 1,$(WAVES)),--trace-fst) $(DEFS) $(INCS) $(UVM_HOME)/uvm_pkg.sv $(SRCS) \
               --top-module $(TOP) --Mdir $(BUILD)/obj -o Vtb
  RUN_CMD   := $(BUILD)/obj/Vtb $(PLUSARGS) +verilator+seed+$(SEED)
else ifeq ($(SIM),questa)
  TOOL      := vsim
  HINT      := module load mentor/suite/2026
  WRAP      := $(call wrap,mentor-run)
  BUILD_CMD := $(WRAP) sh -c "vlib work && vlog -sv -timescale 1ns/1ps $(DEFS) $(INCS) $(UVM_HOME)/uvm_pkg.sv $(SRCS)"
  RUN_CMD   := $(WRAP) vsim -c -lib $(BUILD)/work $(TOP) $(PLUSARGS) -sv_seed $(SEED) -do "run -all; quit -f"
else ifeq ($(SIM),xcelium)
  TOOL      := xrun
  HINT      := module load cadence/xcelium/2509   (the default 2603 is newer than the campus license)
  WRAP      := $(call wrap,cadence-run)
  BUILD_CMD := $(WRAP) xrun -64bit -elaborate -sv -sysv_ext +.svh -timescale 1ns/1ps \
               -uvmhome $(abspath $(UVM_HOME)/..) -uvmnocdnsextra $(DEFS) $(INCS) $(SRCS) \
               -top $(TOP) -xmlibdirname $(BUILD)/xcelium.d
  RUN_CMD   := $(WRAP) xrun -64bit -R -xmlibdirname $(BUILD)/xcelium.d $(PLUSARGS) -svseed $(SEED)
else ifeq ($(SIM),vcs)
  TOOL      := vcs
  HINT      := module load synopsys/vcs-mx/2026.03
  WRAP      := $(call wrap,synopsys-run)
  BUILD_CMD := $(WRAP) vcs -full64 -sverilog -timescale=1ns/1ps $(DEFS) $(INCS) $(UVM_HOME)/uvm_pkg.sv $(SRCS) \
               -top $(TOP) -o $(BUILD)/simv
  RUN_CMD   := $(WRAP) $(BUILD)/simv $(PLUSARGS) +ntb_random_seed=$(SEED)
else
  $(error SIM must be verilator, questa, xcelium or vcs)
endif

.PHONY: help build run check-bug waves gui regress mutants clean

help:
	@echo "make build | run | check-bug | waves | gui | regress | mutants | clean"
	@echo "knobs: SIM=verilator|questa|xcelium|vcs CONFIG=C1..C4 TEST SEED VERB ARGS BUG WAVES JOBS UVM_HOME"
	@echo "e.g.   make run SIM=questa CONFIG=C3 SEED=3   or   make run BUG=2"

$(BUILD)/mut/%.sv: $(ROOT)/rtl/$(MUT_FILE) $(ROOT)/mutants/M$(BUG).sed
	@mkdir -p $(BUILD)/mut
	@sed -f $(ROOT)/mutants/M$(BUG).sed $(ROOT)/rtl/$(MUT_FILE) > $@
	@! cmp -s $(ROOT)/rtl/$(MUT_FILE) $@ || { echo "mutant M$(BUG) did not change $(MUT_FILE)"; rm -f $@; exit 1; }

$(STAMP): $(DEPS) $(DUT)
	@# /usr/local/cae/bin holds warning stubs, not simulators
	@case "$$(command -v $(TOOL))" in ""|/usr/local/cae/bin/*) echo "$(TOOL) not found. Run: $(HINT)"; exit 1;; esac
	$(if $(filter verilator,$(SIM)),@v=$$(verilator --version | awk '{print $$2}'); \
	  [ "$$(printf '%s\n' 5.052 $$v | sort -V | head -1)" = 5.052 ] || { echo "verilator $$v is older than 5.052 (the version this course is tested with). Run: $(HINT)"; exit 1; })
	@test -f "$(UVM_HOME)/uvm_pkg.sv" || { echo "UVM source not found. Clone uvm-training with --recurse-submodules, or set UVM_HOME=<UVM_Library>/src"; exit 1; }
	@mkdir -p $(BUILD)
	@echo "[build] $(SIM) $(CONFIG) (NUM_CHANNELS=$(NCH) FIFO_DEPTH=$(FD))$(if $(filter-out 0,$(BUG)), bug M$(BUG)) -> $(BUILD)"
	@cd $(BUILD) && $(BUILD_CMD) > $(BUILD)/build.log 2>&1 || { tail -40 $(BUILD)/build.log; exit 1; }
	@touch $@

build: $(STAMP)

run: $(STAMP)
	@mkdir -p $(RUNDIR)
	@echo "[run] $(TEST) seed $(SEED) -> $(RUNDIR)/sim.log"
	@cd $(RUNDIR) && $(RUN_CMD) > sim.log 2>&1; \
	  grep -E 'UVM_(ERROR|FATAL) [^:]' sim.log | head -20; \
	  if grep -qE '^(# )?UVM_ERROR :\s+0\s*$$' sim.log && grep -qE '^(# )?UVM_FATAL :\s+0\s*$$' sim.log; then \
	    echo "PASS $(TEST) seed=$(SEED) config=$(CONFIG) sim=$(SIM)"; \
	  else echo "FAIL $(TEST) seed=$(SEED) config=$(CONFIG) sim=$(SIM): see $(RUNDIR)/sim.log"; exit 1; fi

check-bug:
	@$(MAKE) --no-print-directory build BUG=$(CHECK_BUG)
	@if $(MAKE) --no-print-directory run BUG=$(CHECK_BUG) >/dev/null 2>&1; then \
	  echo "FAIL BUG=$(CHECK_BUG) passed: the testbench missed the planted bug (sim=$(SIM))"; exit 1; fi
	@grep -qE 'UVM_ERROR [^:]' $(ROOT)/build/$(SIM)_$(CONFIG)_bug$(CHECK_BUG)/runs/$(TEST)_s$(SEED)/sim.log \
	  && echo "PASS BUG=$(CHECK_BUG) caught by the testbench (sim=$(SIM))" \
	  || { echo "FAIL BUG=$(CHECK_BUG) run failed without a UVM_ERROR (sim=$(SIM))"; exit 1; }

waves:
	@$(MAKE) --no-print-directory run WAVES=1
	@echo "waves: $(BUILD)_waves/runs/$(TEST)_s$(SEED)/waves.$(if $(filter verilator,$(SIM)),fst,vcd)"

# Questa only: interactive GUI with every top-level signal in the wave window
gui: $(STAMP)
	@test "$(SIM)" = questa || { echo "gui needs SIM=questa; use 'make waves' and gtkwave elsewhere"; exit 1; }
	@mkdir -p $(RUNDIR)
	cd $(RUNDIR) && $(WRAP) vsim -lib $(BUILD)/work -voptargs=+acc $(TOP) $(PLUSARGS) -sv_seed $(SEED) \
	  -do "add wave -r /$(TOP)/*; run -all"

# Verilator only: every test over seeds and configurations, with coverage; writes results/regress.txt
regress:
	python3 -I scripts/regress.py --configs $(CONFIGS) --seeds $(SEEDS) --rand-seeds $(RAND_SEEDS) --jobs $(JOBS)

# Verilator only: every planted bug must fail at least one test; writes results/mutants.txt
mutants:
	python3 -I scripts/regress.py --mutants --configs C1 --seeds 1 --jobs $(JOBS)

clean:
	rm -rf $(ROOT)/build
