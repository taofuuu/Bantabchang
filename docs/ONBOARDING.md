# Onboarding — first time pulling this repo

Welcome. This doc is for Nooyz, Donoz, and anyone else joining the project. It covers cloning, setting up your tools, bringing your existing Vivado work into the shared repo, and the day-to-day workflow.

If anything here is wrong or unclear, fix it and push — the doc lives with the code.

---

## 1. Tools you need

| Tool                | Required for         | Notes                                          |
|---------------------|----------------------|------------------------------------------------|
| **Vivado 2025.2**   | everyone             | Synthesis + bitstream                          |
| **Git**             | everyone             | Clone + push                                   |
| **Python 3.10+**    | detector owner only  | Train / quantize / export weights              |
| **iverilog + cocotb** | anyone writing tests | Module-level simulation                      |

Camera, filter, and overlay teammates do **not** need Python — `scripts/`, `weights/`, and `data/` are detector-only.

---

## 2. Clone the repo

```bash
git clone <repo-url> HWSynProject
cd HWSynProject
```

That's it. No submodules.

---

## 3. Read these two files before touching anything

1. [`README.md`](../README.md) — repo layout and where things live
2. [`INTERFACES.md`](INTERFACES.md) — the signal contract at every subsystem boundary. **Your module's port names must match this exactly.**

---

## 4. Bring your existing Vivado work into the repo

If you already built something in your own Vivado project, follow these steps to integrate it.

### 4a. Find your real source files

Your `.v` files live under:
```
<your_project>/<proj_name>.srcs/sources_1/new/        ← files you created in Vivado
<your_project>/<proj_name>.srcs/sources_1/imports/    ← files you added by reference
```

Everything else (`.xpr`, `.cache/`, `.runs/`, `.gen/`, `.sim/`) is generated — ignore it.

### 4b. Copy `.v` files to your subsystem folder

| You    | Copy your `.v` files into                     |
|--------|-----------------------------------------------|
| Nooyz  | `rtl/camera/` (capture, SCCB) and `rtl/filter/` (preprocessing) |
| Donoz  | `rtl/overlay/` (VGA + bbox draw)              |

Example:
```bash
cp /path/to/your_project/proj.srcs/sources_1/new/ov7670_capture.v rtl/camera/
cp /path/to/your_project/proj.srcs/sources_1/new/sccb_master.v    rtl/camera/
```

### 4c. Merge your `.xdc` lines into `constraints/basys3.xdc`

`constraints/basys3.xdc` is shared. Open it, find the section for your subsystem (it has a `# Owner:` comment), and **append your pin assignments there**. Do not overwrite the file or duplicate the `clk` / `CFGBVS` lines that are already at the top.

### 4d. Rename your top-level ports to match the interface contract

Your subsystem's top module must use the exact port names from [`INTERFACES.md`](INTERFACES.md). For example, if your camera module currently outputs `data_out` and `valid`, rename them to `pixel` and `pixel_valid`. This is what lets `rtl/top/system_top.v` be pure wiring instead of glue logic.

### 4e. Avoid module-name collisions

Filenames in different subsystem folders can repeat (`rtl/camera/frame_buffer.v` and `rtl/detector/frame_buffer.v` coexist), but **Verilog module names inside them must be unique**. Use a subsystem prefix:

| Subsystem | Prefix    | Example module name      |
|-----------|-----------|--------------------------|
| Camera    | `cam_`    | `cam_frame_buffer`       |
| Filter    | `flt_`    | `flt_gamma_correct`      |
| Detector  | `det_`    | `det_conv_layer`         |
| Overlay   | `vga_`    | `vga_bbox_draw`          |

### 4f. Discard your old `.xpr`

Don't copy your `.xpr` or build dirs in. From now on, everyone regenerates the project from `vivado/build.tcl`:

```bash
vivado -source vivado/build.tcl       # GUI mode
# or:
vivado -mode batch -source vivado/build.tcl
```

This script globs `rtl/**/*.v` + `constraints/*.xdc` and builds a fresh project on your machine. The `.xpr` it creates is gitignored.

### 4g. (If you used Vivado IP cores)

If your design uses the clocking wizard, BRAM, or any other Vivado IP, those aren't plain `.v` files. You have two options:

- **Recommended:** add `create_ip` calls to `vivado/build.tcl` so the IP regenerates from Tcl. Ask the team chat for help if you've never done this — it's straightforward but easy to get wrong the first time.
- **Quick:** copy the `.xci` files into `rtl/<subsystem>/ip/` and add a matching `add_files` line to `build.tcl`. Works, but the IP settings are now opaque XML in git.

---

## 5. Verify before you push

```bash
# 1. See what you're about to commit
git status

# 2. Confirm the project still elaborates
vivado -mode batch -source vivado/build.tcl

# 3. (If you wrote a cocotb test) run it
cd tb/<your_subsystem>
make TEST=<your_test>
```

If `vivado -mode batch` reports unresolved modules or syntax errors, fix them before pushing — don't make your teammates discover them.

---

## 6. Day-to-day git workflow

```bash
# Always work on a feature branch, never directly on main
git checkout -b camera/sccb-config

# … edit files …

git add rtl/camera/sccb_master.v constraints/basys3.xdc
git commit -m "camera: implement SCCB master FSM"
git push -u origin camera/sccb-config
```

Then open a pull request on GitHub. Review one each other's changes — at minimum, check that:
- New module ports match `INTERFACES.md`.
- No `.xpr` or `.cache/` got committed (the `.gitignore` should catch this, but double-check).
- Module names don't collide with existing ones.

---

## 7. Adding a testbench for your module

The detector subsystem already has a working cocotb setup — copy its pattern.

1. Drop your test in `tb/<your_subsystem>/test_<module>.py`.
2. Optionally write a thin Verilog wrapper at `tb/<your_subsystem>/wrap_<module>.v` if you need to expose internal signals.
3. Copy `tb/detector/Makefile` to `tb/<your_subsystem>/Makefile` and adjust the `TEST=` blocks.
4. Run with `cd tb/<your_subsystem> && make TEST=<name>`.

---

## 8. Who owns what

See the table in [`README.md`](../README.md#subsystem-ownership). If you need a signal or behavior change at a subsystem boundary, **talk to the owner first** and update [`INTERFACES.md`](INTERFACES.md) as part of the same PR — never silently change a contract.

---

## 9. Quick reference

| What                       | Where                                          |
|----------------------------|------------------------------------------------|
| My subsystem's RTL         | `rtl/<subsystem>/`                             |
| My subsystem's tests       | `tb/<subsystem>/`                              |
| Pin assignments            | `constraints/basys3.xdc`                       |
| Signal contract            | `docs/INTERFACES.md`                           |
| Regenerate Vivado project  | `vivado -source vivado/build.tcl`              |
| System top-level           | `rtl/top/system_top.v` (TBD owner)             |

Welcome aboard.
