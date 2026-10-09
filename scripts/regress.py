#!/usr/bin/env python3
# File:        regress.py
# Author:      Isaac Hagedorn
# Date:        2026-10-08
# Description: Runs every test over seeds and configurations and reports results and coverage. With --mutants, checks that each planted RTL bug is caught.

import argparse
import collections
import concurrent.futures as cf
import glob
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DMA = os.path.join(ROOT, "rtl")

DIRECTED = ["dma_smoke_test", "dma_reg_test", "dma_copy_test", "dma_channels_test", "dma_modes_test",
            "dma_bus_test", "dma_error_test", "dma_stop_test", "dma_bad_cfg_test", "dma_trigger_test",
            "dma_corner_test", "dma_restart_race_test", "dma_perf_test"]
RANDOM = ["dma_rand_test", "dma_rand_err_test", "dma_rand_stop_test", "dma_rand_reg_test"]
CONFIGS = {"C1": (8, 16), "C2": (2, 4), "C3": (32, 16), "C4": (8, 32)}
RTL_FILES = ["source/address_generator.sv", "source/ahb_read_manager.sv", "source/ahb_subordinate.sv",
             "source/ahb_write_manager.sv", "source/channel_csr.sv", "source/channel_manager.sv",
             "source/dma_arbiter.sv", "source/dma_controller.sv", "source/dma_engine.sv",
             "source/dma_fifo.sv", "source/trigger_controller.sv", "include/socetlib_counter.sv"]

def sh(cmd, **kw):
    return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, **kw)

def build(config, mutant=None):
    bug = mutant[1:] if mutant else "0"
    r = sh(["make", "-s", "-C", ROOT, "build", "SIM=verilator", f"CONFIG={config}", f"BUG={bug}"])
    if r.returncode:
        print(r.stdout[-3000:])
        if mutant:
            return None
        sys.exit(f"build failed: {config}")
    return os.path.join(ROOT, "build", f"verilator_{config}" + (f"_bug{bug}" if mutant else ""))

def run_one(bdir, test, seed, cov=True):
    rdir = os.path.join(bdir, "runs", f"{test}_s{seed}")
    os.makedirs(rdir, exist_ok=True)
    cmd = [os.path.join(bdir, "obj", "Vtb"), f"+UVM_TESTNAME={test}", f"+verilator+seed+{seed}",
           "+UVM_VERBOSITY=UVM_LOW"]
    if cov:
        cmd.append("+verilator+coverage+file+coverage.dat")
    try:
        r = sh(cmd, cwd=rdir, timeout=1800)
        log, rc = r.stdout, r.returncode
    except subprocess.TimeoutExpired:
        log, rc = "TIMEOUT", -1
    with open(os.path.join(rdir, "sim.log"), "w") as f:
        f.write(log)
    passed = "*** TEST PASSED ***" in log and rc == 0
    m = re.search(r"\[SCB\] compares: (\d+)", log)
    errs = re.findall(r"UVM_(?:ERROR|FATAL) \S+ @ \d+: \S+ \[(\w+)\] (.*)", log)
    if not errs and not passed:
        errs = [("CRASH", f"exit status {rc}: " + (log.strip().splitlines() or ["no output"])[-1])]
    return dict(test=test, seed=seed, passed=passed, compares=int(m.group(1)) if m else 0,
                ids=sorted({e[0] for e in errs}), first=(errs[0][1][:170] if errs else ""))

def run_matrix(bdir, jobs_list, jobs, cov=True):
    with cf.ThreadPoolExecutor(max_workers=jobs) as ex:
        return list(ex.map(lambda ts: run_one(bdir, *ts, cov=cov), jobs_list))

def read_cov(path):
    pts = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = re.match(r"C '(.*)' (\d+)$", line.rstrip("\n"))
            if not m:
                continue
            kv = dict(p.split("\x02", 1) for p in m.group(1).split("\x01") if "\x02" in p)
            kv["count"] = int(m.group(2))
            pts.append(kv)
    return pts

def merge_cov(bdir):
    files = sorted(glob.glob(os.path.join(bdir, "runs", "*", "coverage.dat")))
    out = os.path.join(bdir, "merged.dat")
    r = sh(["verilator_coverage", "--write", out] + files)
    if r.returncode:
        sys.exit("verilator_coverage failed:\n" + r.stdout[-2000:])
    for f in files:
        os.remove(f)
    return read_cov(out)

def not_applicable(name, nch, fdepth):
    if nch <= 3 and name.endswith("cg_conc.cp_active.SOME"):
        return True
    if fdepth < 6 and re.search(r"(cg_bus\.(cp_beat\.B[0-3]|port_x_burst\.\w+_x_INCR4|waits_x_beat\.\w+_x_B[0-3])"
                                r"|cg_error\.(cp_beat\.B[0-3]|port_x_beat\.\w+_x_B[0-3]))$", name):
        return True
    if re.search(r"cg_reg\.reg_x_rw_x_resp\.(SOURCE|DESTINATION|CONTROL|DESIRED|COMPLETED|REMAINING|ACTIVE|ERRADDR|TCFG|TSTAT)_x_READ_x_ERROR$", name):
        return True
    if name.endswith("cg_reg.reg_x_rw_x_resp.UNMAPPED_x_READ_x_OKAY") or name.endswith("cg_reg.reg_x_rw_x_resp.UNMAPPED_x_WRITE_x_OKAY"):
        return True
    if re.search(r"cg_stop\.kind_x_phase\.RESET_x_LAST_WRITES$", name):
        return False
    return False

def functional_report(pts, nch, fdepth):
    lines, holes, total, hit = [], [], 0, 0
    groups = collections.OrderedDict()
    for p in sorted((p for p in pts if p.get("t") == "covergroup"), key=lambda p: p["h"]):
        name = p["h"].replace("__vlAnonCG_", "")
        if not_applicable(name, nch, fdepth):
            continue
        g = name.split(".")[0]
        groups.setdefault(g, [0, 0])
        groups[g][0] += 1
        total += 1
        if p["count"] > 0:
            groups[g][1] += 1
            hit += 1
        else:
            holes.append(name)
    for g, (n, h) in groups.items():
        lines.append(f"    {g:13s} {h:4d}/{n:<4d} bins hit")
    for name in holes:
        lines.append(f"    HOLE: {name}")
    ok = not holes and total > 0
    lines.insert(0, f"  functional coverage: {hit}/{total} bins{'' if ok else '  <-- NOT CLOSED'}")
    return ok, lines

def code_report(pts):
    lines, by_file = [], collections.OrderedDict()
    for f in RTL_FILES:
        by_file[f] = {}
    for p in pts:
        fn = p.get("f", "")
        rel = next((f for f in RTL_FILES if fn.endswith(f)), None)
        if rel is None or p.get("t") not in ("line", "branch", "expr", "toggle"):
            continue
        key = (p["t"], p.get("l"), p.get("n", ""), p.get("o", ""))
        by_file[rel][key] = max(by_file[rel].get(key, 0), p["count"])
    if not any(by_file.values()):
        return False, ["  DUT code coverage: NO DATA (build without --coverage-line/-toggle/-expr?)"]
    tot = collections.Counter()
    lines.append(f"  DUT code coverage (merged over instances)      line        branch      expr        toggle")
    for f, pts_f in by_file.items():
        row = f"    {os.path.basename(f):24s}"
        for kind in ("line", "branch", "expr", "toggle"):
            ps = [c for (k, *_), c in pts_f.items() if k == kind]
            h = sum(1 for c in ps if c > 0)
            tot[kind + "_n"] += len(ps)
            tot[kind + "_h"] += h
            row += f"  {h:4d}/{len(ps):<5d}" if ps else "      -    "
        lines.append(row)
    row = f"    {'total':24s}"
    for kind in ("line", "branch", "expr", "toggle"):
        n, h = tot[kind + "_n"], tot[kind + "_h"]
        row += f"  {100.0 * h / n:5.1f} %   " if n else "      -    "
    lines.append(row)
    misses = []
    for f, pts_f in by_file.items():
        for (k, l, n, o), c in sorted(pts_f.items(), key=lambda kv: (kv[0][0], int(kv[0][1] or 0))):
            if c == 0 and k in ("line", "branch"):
                misses.append(f"      miss {k:6s} {os.path.basename(f)}:{l} {o}")
    lines.append(f"  line/branch holes: {len(misses)}")
    lines += misses
    return True, lines

def t43():
    out = []
    files = [os.path.join(DMA, f) for f in ["include/ahb_if.sv", "include/bus_protocol_if.sv",
                                             "include/socetlib_counter.sv"] + [f for f in RTL_FILES if f.startswith("source/")]]
    for n in (1, 3, 64):
        r = sh(["verilator", "--lint-only", "-Wno-fatal", "-Wno-lint", "-Wno-style", "-Werror-USERERROR",
                f"-GNUM_CHANNELS={n}", "--top-module", "dma_controller"] + files)
        rejected = r.returncode != 0
        why = ""
        if rejected:
            m = re.search(r"%Error(?:-\w+)?: (?:\S+?/)?([\w/.]+:\d+:\d+: .*)", r.stdout)
            why = f" ({m.group(1)[:90]})" if m else ""
        out.append(f"  T43 NUM_CHANNELS={n:<3d} {'rejected at elaboration' + why if rejected else 'NOT rejected  <-- FAIL'}")
    return all(o.find("NOT rejected") < 0 for o in out), out

def summarize(results):
    by_test = collections.OrderedDict()
    for r in results:
        by_test.setdefault(r["test"], []).append(r)
    lines, ok = [], True
    for t, rs in by_test.items():
        npass = sum(r["passed"] for r in rs)
        comp = sum(r["compares"] for r in rs)
        lines.append(f"    {t:26s} {npass}/{len(rs)} passed  {comp:9d} compares")
        for r in rs:
            if not r["passed"]:
                ok = False
                lines.append(f"      seed {r['seed']}: [{','.join(r['ids'])}] {r['first']}")
    return ok, lines

def regress(args):
    report, all_ok = [], True
    for c in args.configs:
        nch, fd = CONFIGS[c]
        bdir = build(c)
        for d in glob.glob(os.path.join(bdir, "runs", "*")):
            sh(["rm", "-rf", d])
        jobs_list = [(t, s) for t in DIRECTED for s in range(1, args.seeds + 1)]
        jobs_list += [(t, s) for t in RANDOM for s in range(1, args.rand_seeds + 1)]
        res = run_matrix(bdir, jobs_list, args.jobs)
        ok_t, lt = summarize(res)
        pts = merge_cov(bdir)
        ok_f, lf = functional_report(pts, nch, fd)
        ok_c, lc = code_report(pts)
        report += [f"== {c}: NUM_CHANNELS={nch} FIFO_DEPTH={fd}; {args.seeds} seed(s) per directed test, "
                   f"{args.rand_seeds} per random test",
                   f"  tests{'' if ok_t else '  <-- FAILURES'}"] + lt + lf + lc + [""]
        all_ok &= ok_t and ok_f
    ok_p, lp = t43()
    report += lp
    all_ok &= ok_p
    report.append(f"\nREGRESSION {'PASSED' if all_ok else 'FAILED'}")
    return all_ok, report

def mutants(args):
    report, all_caught = [], True
    c = args.configs[0]
    tests = DIRECTED + RANDOM
    jobs_list = [(t, s) for t in tests for s in range(1, args.seeds + 1)]
    base = build(c)
    res = run_matrix(base, jobs_list, args.jobs, cov=False)
    ok, _ = summarize(res)
    report.append(f"baseline (unmodified RTL), {c}: {'all tests pass' if ok else 'FAILS -- fix this first'}")
    all_caught &= ok
    for sed in sorted(glob.glob(os.path.join(ROOT, "mutants", "M*.sed")), key=lambda p: int(re.sub(r"\D", "", os.path.basename(p)))):
        m = os.path.basename(sed)[:-4]
        desc = open(sed).readline().lstrip("# ").strip()
        bdir = build(c, m)
        if bdir is None:
            all_caught = False
            report.append(f"\n{desc}\n  BUILD FAILED: fix the mutant's sed script")
            continue
        res = run_matrix(bdir, jobs_list, args.jobs, cov=False)
        failing = sorted({r["test"] for r in res if not r["passed"]})
        ids = sorted({i for r in res if not r["passed"] for i in r["ids"]})
        caught = bool(failing)
        all_caught &= caught
        report.append(f"\n{desc}\n  {'CAUGHT' if caught else 'MISSED'} by {len(failing)}/{len(tests)} tests: "
                      f"{', '.join(t.replace('dma_', '').replace('_test', '') for t in failing) or '-'}"
                      f"\n  reported by: {', '.join(ids) or '-'}")
        first = next((r for r in res if not r["passed"]), None)
        if first:
            report.append(f"  first message: {first['first']}")
        sh(["rm", "-rf", os.path.join(bdir, "obj"), os.path.join(bdir, "runs")])
        print(report[-1] if not first else "\n".join(report[-2:]), flush=True)
    report.append(f"\nMUTANTS {'ALL CAUGHT' if all_caught else 'NOT ALL CAUGHT'}")
    return all_caught, report

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--configs", nargs="+", default=["C1", "C2", "C3", "C4"])
    ap.add_argument("--seeds", type=int, default=3)
    ap.add_argument("--rand-seeds", type=int, default=0, help="seeds per random test (default: 2 x --seeds)")
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    ap.add_argument("--mutants", action="store_true")
    args = ap.parse_args()
    if not args.rand_seeds:
        args.rand_seeds = 2 * args.seeds
    ok, report = (mutants if args.mutants else regress)(args)
    text = "\n".join(report)
    print(text)
    name = "mutants.txt" if args.mutants else "regress.txt"
    os.makedirs(os.path.join(ROOT, "results"), exist_ok=True)
    with open(os.path.join(ROOT, "results", name), "w") as f:
        f.write(text + "\n")
    sys.exit(0 if ok else 1)

if __name__ == "__main__":
    main()
