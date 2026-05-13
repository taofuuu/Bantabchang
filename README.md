# Basys 3 Face Detection

Real-time face detection on a Basys 3 (Artix-7 XC7A35T) using an OV7670 camera and VGA output.
A tiny INT8 CNN classifier runs in hand-written RTL over a 24×24 sliding window on 160×120 grayscale frames; bounding boxes are drawn by the VGA stage and scaled ×4 to 640×480.

## Pipeline

```
OV7670 ── SCCB config ──► Image filter ──► NN face detector ──► VGA overlay
   │                          │                  │                  │
   └─ rtl/camera ─────────────┴─ rtl/filter ─────┴─ rtl/detector ───┴─ rtl/overlay
```

See [`docs/INTERFACES.md`](docs/INTERFACES.md) for the signal contract at every subsystem boundary.

## Network (detector subsystem)

| Layer  | Shape           | Notes                          |
|--------|-----------------|--------------------------------|
| Conv1  | 1 → 8, 3×3 s2   | INT8, per-tensor symmetric     |
| Conv2  | 8 → 16, 3×3 s2  | INT8                           |
| Conv3  | 16 → 16, 3×3 s1 | INT8                           |
| FC     | 144 → 2         | Logits (face / no-face)        |

~3.8K params, ~70K MACs/patch. Trained in PyTorch, post-training quantized, deployed via `$readmemh` ROMs with power-of-two requantization shifts.

## Repository layout

```
HWSynProject/
├── rtl/                          # Synthesizable Verilog, split by subsystem
│   ├── camera/                   # OV7670 capture + SCCB config           [owner: nooyz]
│   ├── filter/                   # Image preprocessing                    [owner: nooyz]
│   ├── detector/                 # NN face classifier                     [owner: toodz]
│   ├── overlay/                  # VGA + bounding-box draw                [owner: nooyz]
│   └── top/                      # system_top.v wiring all subsystems
│
├── tb/                           # Cocotb testbenches, mirroring rtl/
│   └── camera/  filter/  overlay/  top/  detector/
│
├── constraints/
│   └── basys3.xdc                # Pin map (clk, sw, led, OV7670, VGA)
│
├── vivado/
│   └── build.tcl                 # Regenerates Vivado project — .xpr is gitignored
│
├── scripts/                      # Detector training & weight-export pipeline
│   ├── build_dataset.py          # → data/crops_*.npy
│   ├── model.py                  # PyTorch model definition
│   ├── train.py                  # → data/model_float.pt
│   ├── quantize.py               # → data/model_int8.{pt,json}
│   ├── export_weights.py         # → weights/*.hex + scales.vh
│   ├── dump_golden.py            # → data/golden/*.hex
│   └── test_image.py             # End-to-end inference on one image
│
├── weights/                      # FPGA-deployable weight ROMs (committed)
│   ├── conv{1,2,3}_w.hex         # INT8 weights
│   ├── conv{1,2,3}_b.hex         # INT32 biases
│   ├── fc_{w,b}.hex
│   └── scales.vh                 # Per-layer requant shift constants
│
├── data/                         # Models + verification vectors
│   ├── model_float.pt
│   ├── model_int8.{pt,json}
│   ├── golden/                   # Bit-exact PyTorch reference vectors
│   ├── test_frame.hex            # 160×120 test frame for detector_top
│   ├── test_input.jpg
│   └── crops_*.npy               # Training crops (gitignored, regenerable)
│
├── requirements.txt              # Python deps
├── README.md
└── .gitignore
```


## Workflow

### Detector training (Python)

1. `python scripts/build_dataset.py`
2. `python scripts/train.py`
3. `python scripts/quantize.py`
4. `python scripts/export_weights.py` → populates `weights/`
5. `python scripts/dump_golden.py` → populates `data/golden/`

### RTL verification (cocotb)

```
cd tb/detector
make TEST=requantize
make TEST=conv1
make TEST=detector_top
# … etc.
```

### Synthesis (Vivado 2025.2)

```
vivado -source vivado/build.tcl       # GUI, regenerates the project
# or:  vivado -mode batch -source vivado/build.tcl
```

The `.xpr` is regenerated locally on each machine — only `vivado/build.tcl` lives in git.

## Hardware budget

Target FPGA: XC7A35T (33K LUT, 90 DSP, 225 KB BRAM). Estimated detector usage: ~3K LUT, ~8 DSP, ~28 KB BRAM at 100 MHz, 30 fps.

## Subsystem ownership

| Subsystem | RTL path        | TB path         | Owner |
|-----------|-----------------|-----------------|-------|
| Camera    | `rtl/camera/`   | `tb/camera/`    | Nooyz |
| Filter    | `rtl/filter/`   | `tb/filter/`    | Nooyz |
| Detector  | `rtl/detector/` | `tb/detector/`  | Toodz |
| Overlay   | `rtl/overlay/`  | `tb/overlay/`   | Nooyz |
| Top       | `rtl/top/`      | `tb/top/`       | Toodz |
