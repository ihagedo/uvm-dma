#!/bin/bash
# File:        run.sh
# Author:      Isaac Hagedorn
# Date:        2026-10-08
# Description: Runs the directed probe and a parameter sweep of the DMA. Build files go to ./build.

set -u
cd "$(dirname "$0")"
R=${R:-$(cd ../rtl && pwd)}
HERE=$PWD
B=$HERE/build; rm -rf "$B"; mkdir -p "$B"
VFLAGS="-Wno-fatal -sv --timing --binary -j 4 -I$R/include -I$R/source"
echo "== RTL: $R"
echo "== $(verilator --version)"
echo
echo "== 1. dma_probe_tb.sv, 8 channels (spec claims marked 'sim')"
mkdir -p "$B/probe8" && ( cd "$B/probe8" && verilator $VFLAGS --top-module dma_probe_tb -Mdir obj \
  "$R/include/ahb_pkg.sv" "$HERE/dma_probe_tb.sv" >build.log 2>&1 && ./obj/Vdma_probe_tb 2>&1 | grep -E '^(PASS|FAIL|OBS|TABLE|DONE)' )
echo
echo "== 2. Parameter checks: each must stop elaboration"
for g in NUM_CHANNELS=1 NUM_CHANNELS=3 NUM_CHANNELS=64 NUM_SOURCES=3 FIFO_DEPTH=2 FIFO_DEPTH=6; do
  r=$(cd "$B" && verilator --lint-only -Wno-fatal -Wno-lint -Wno-style -Werror-USERERROR -I"$R/include" -I"$R/source" \
      -G$g --top-module dma_controller "$R/source/dma_controller.sv" 2>&1 | grep -m1 '%Error' | sed "s|$R/||")
  echo "$g: ${r:-NOT REJECTED}"
done
echo
echo "== 3. Parameter sweep (NUM_CHANNELS, FIFO_DEPTH): reset values + three copies with bursts"
for cfg in "2 16" "4 16" "32 16" "8 4" "8 8" "8 32"; do
  set -- $cfg; d=$B/p_$1_$2; mkdir -p "$d"
  ( cd "$d" && verilator $VFLAGS -DPARAM -DNCH=$1 -DFDEPTH=$2 --top-module dma_probe_tb -Mdir obj \
      "$R/include/ahb_pkg.sv" "$HERE/dma_probe_tb.sv" >build.log 2>&1 \
      || { echo "NUM_CHANNELS=$1 FIFO_DEPTH=$2: BUILD FAILED: $(grep -m1 '%Error' build.log | sed "s|$R/||")"; exit; }
    echo "NUM_CHANNELS=$1 FIFO_DEPTH=$2: $(./obj/Vdma_probe_tb 2>&1 | grep -E '^(FAIL|DONE)' | tr '\n' ' ')" )
done
[ "${KEEP:-0}" = 1 ] || rm -rf "$B"
