# OV7670 Real-Time Face Detector on FPGA

A fully pipelined real-time face detection system implemented in Verilog, targeting the **Digilent Basys 3** (Xilinx Artix-7). An OV7670 camera feeds a quantized convolutional neural network that performs sliding-window face detection, and the result is overlaid as a green bounding box on a live 640×480 VGA display.

---

## Table of Contents

- [Overview](#overview)
- [Hardware Requirements](#hardware-requirements)
- [Architecture](#architecture)
  - [System Block Diagram](#system-block-diagram)
  - [Clock Domains](#clock-domains)
  - [Neural Network Pipeline](#neural-network-pipeline)
- [File Reference](#file-reference)
- [I/O Pinout](#io-pinout)
- [Neural Network Details](#neural-network-details)
- [Building the Project](#building-the-project)
- [Weight Files](#weight-files)
- [LED Diagnostics](#led-diagnostics)
- [Image Filters](#image-filters)
- [Design Notes](#design-notes)

---

## Overview

Each video frame is processed as follows:

1. The OV7670 streams 640×480 RGB565 pixels over PCLK.
2. `ov7670_capture` decodes the byte pairs and writes a 2×2-downsampled **320×240 RGB444** image into a dual-port frame buffer for VGA display, and simultaneously produces a 4×4-downsampled **160×120 grayscale** stream for the neural network.
3. A **clock-domain crossing** bridges the grayscale stream from PCLK into the 25 MHz system domain.
4. `detector_top` buffers one complete 160×120 frame, then runs a sliding-window scan: for each window position it extracts a 24×24 patch (with dilation factor 3, covering a 72×72-pixel receptive field), runs it through a 3-layer CNN followed by a fully-connected head, and scores the result.
5. The highest-confidence detection above a configurable threshold is latched and scaled back to VGA coordinates.
6. `vga_controller` drives a standard 640×480 @ 60 Hz signal. The raw camera image (through a selectable filter) is shown on screen; a red bounding box is drawn over the best detection.

---

## Hardware Requirements

| Component | Details |
|---|---|
| FPGA board | Digilent Basys 3 (Xilinx Artix-7 35T) |
| Camera | OV7670 (no FIFO variant) |
| Display | Any VGA monitor (640×480 @ 60 Hz) |
| Switches | SW[2:0] — image filter selection |
| Push-button | BTNC — asynchronous reset |
| LEDs | 8 diagnostic LEDs (see below) |

---

## Architecture

### System Block Diagram

```
                  ┌─────────────┐    SCCB (I2C-like)
  100 MHz clk ──► │ ov7670_config│──────────────────► OV7670
                  └─────────────┘
                                         pclk
  OV7670 ──────────────────────────────────────────►│
  (camera_data / href / vsync)                       │ ov7670_capture
                                                     │ ├─► frame_addr/pixel/we
                                                     │ │       │
                                                     │ │   filter_frame_buffer  (320×240 RGB444, dual-port BRAM)
                                                     │ │       │ clkb = 25 MHz
                                                     │ │   image_filter ──► vga_controller ──► VGA
                                                     │ │
                                                     │ └─► stream_valid/pixel (grayscale, pclk domain)
                                                     │         │
                                                     │   pixel_stream_cdc  (toggle-sync CDC)
                                                     │         │ 25 MHz domain
                                                     │   detector_top
                                                     │   ├─ frame_buffer   (160×120 grayscale BRAM)
                                                     │   ├─ patch_extractor (24×24 with dilation)
                                                     │   ├─ conv_layer ×3  + act_buffer ×3
                                                     │   ├─ fc_layer        (144→5)
                                                     │   └─ face_valid / face_{x,y,w,h}
                                                     │         │
                                                     │   toggle-sync CDC ──► VGA bounding-box overlay
```

### Clock Domains

| Domain | Frequency | Source | Used by |
|---|---|---|---|
| `clk` | 100 MHz | Basys 3 oscillator | SCCB config, reset synchronizers |
| `clk_25mhz` | 25 MHz | `clk_wiz_0` | VGA controller, detector pipeline, CDC destination |
| `clk_24mhz` | 24 MHz | `clk_wiz_0` | OV7670 XCLK input |
| `camera_pclk` | ~24 MHz | OV7670 output | Pixel capture |

All cross-domain signals use textbook two-FF synchronizers with `(* ASYNC_REG = "TRUE" *)` attributes. The pixel stream uses the MCP (Mutually exclusive Clock Pulse) toggle-sync formulation. Face detection results cross back to the VGA domain via a toggle-sync with hold-off counter (8 frames) to prevent flicker.

### Neural Network Pipeline

The detector runs sequentially through these stages for every candidate patch:

```
<<<<<<< Updated upstream
HWSynProject/
├── rtl/                          # Synthesizable Verilog, split by subsystem
│   ├── camera/                   # OV7670 capture + SCCB config           [owner: ?]
│   ├── filter/                   # Image preprocessing                    [owner: ?]
│   ├── detector/                 # NN face classifier                     [owner: this user]
│   │   ├── detector_top.v        # Subsystem top — streaming → face_*
│   │   ├── frame_buffer.v
│   │   ├── patch_extractor.v
│   │   ├── conv_layer.v
│   │   ├── fc_layer.v
│   │   ├── act_buffer.v
│   │   ├── requantize.v
│   │   └── weight_rom.v
│   ├── overlay/                  # VGA + bounding-box draw                [owner: ?]
│   └── top/                      # system_top.v wiring all subsystems
│
├── tb/                           # Cocotb testbenches, mirroring rtl/
│   ├── camera/  filter/  overlay/  top/
│   └── detector/
│       ├── Makefile              # cocotb runner — `cd tb/detector && make TEST=…`
│       ├── test_*.py             # Cocotb tests
│       └── wrap_*.v              # Verilog wrappers exposing internal signals
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
├── docs/INTERFACES.md            # Signal contract at every subsystem boundary
├── requirements.txt              # Python deps
├── README.md
└── .gitignore
```

`scripts/`, `weights/`, `data/` are detector-only — teammates working on camera/filter/overlay don't need to touch them.
=======
 patch_extractor           24×24×1 int8
       │
 conv_layer (Conv1)    3×3, stride 2, 1→8 ch    ► 11×11×8   ReLU + requantize
       │ act_buffer
 conv_layer (Conv2)    3×3, stride 2, 8→16 ch   ► 5×5×16    ReLU + requantize
       │ act_buffer
 conv_layer (Conv3)    3×3, stride 1, 16→16 ch  ► 3×3×16    ReLU + requantize
       │ act_buffer (144 values)
 fc_layer              144→5 int32 outputs
       │
       ├─ out[0]  confidence logit
       ├─ out[1]  bbox x₀  (dequantized)
       ├─ out[2]  bbox y₀  (dequantized)
       ├─ out[3]  bbox w
       └─ out[4]  bbox h
```

All layers use one-MAC-per-cycle sequential execution. A full three-conv + FC inference takes on the order of tens of thousands of cycles; `detector_top` tiles these serially across the scan grid and picks the highest-confidence result per frame.
>>>>>>> Stashed changes

---

## File Reference

| File | Module | Description |
|---|---|---|
| `camera_vga_top.v` | `camera_vga_top` | **Top-level** — wires together all subsystems, clock generation, reset synchronizers, bounding-box overlay logic |
| `ov7670_config.v` | `ov7670_config` | SCCB (I2C-like) controller; sends 36 register writes to configure RGB565 VGA mode, color matrix, gamma, and AWB |
| `ov7670_capture.v` | `ov7670_capture` | RGB565 byte-pair decoder; writes 320×240 RGB444 to frame buffer and emits 160×120 grayscale stream on PCLK |
| `pixel_stream_cdc.v` | `pixel_stream_cdc` | Toggle-sync CDC: moves per-pixel valid/data from PCLK domain to 25 MHz domain |
| `filter_frame_buffer.v` | `filter_frame_buffer` | True dual-port BRAM, 320×240 × 12-bit (RGB444); write on PCLK, read on 25 MHz |
| `image_filter.v` | `image_filter` | Combinational RGB444 filter; 8 modes selected by SW[2:0] |
| `vga_controller.v` | `vga_controller` | Standard 640×480 @ 60 Hz VGA timing with pixel-doubled camera readout |
| `detector_top.v` | `detector_top` | Sliding-window scan FSM; orchestrates patch extraction and full NN inference per patch; latches best result |
| `frame_buffer.v` | `frame_buffer` | Single-port 160×120 grayscale BRAM; streams in from CDC output, random-read by patch extractor |
| `patch_extractor.v` | `patch_extractor` | Reads a 24×24 sub-image (with runtime dilation) from the frame buffer; converts uint8→int8 |
| `conv_layer.v` | `conv_layer` | Parameterized 2D convolution: bias load → sequential MAC → ReLU + requantize → write output |
| `fc_layer.v` | `fc_layer` | Fully-connected layer: 144 inputs → 5 int32 outputs (confidence + 4 bbox values) |
| `act_buffer.v` | `act_buffer` | Simple dual-port BRAM for inter-layer activations; parameterized width/depth |
| `weight_rom.v` | `weight_rom` | Synchronous ROM initialized from a hex file; used for both weights (int8) and biases (int32) |
| `requantize.v` | `requantize` | Combinational int32→int8: arithmetic right-shift with rounding bias, then ReLU and saturation to [0, 127] |

---

## I/O Pinout

| Signal | Direction | Basys 3 pin | Description |
|---|---|---|---|
| `clk` | In | W5 | 100 MHz system clock |
| `reset` | In | U18 (BTNC) | Async active-high reset |
| `camera_data[7:0]` | In | PMOD header | OV7670 D[7:0] |
| `camera_href` | In | PMOD header | OV7670 HREF |
| `camera_vsync` | In | PMOD header | OV7670 VSYNC |
| `camera_pclk` | In | PMOD header | OV7670 PCLK |
| `camera_xclk` | Out | PMOD header | 24 MHz clock to OV7670 |
| `camera_pwdn` | Out | PMOD header | Tied low (not in power-down) |
| `camera_reset` | Out | PMOD header | Tied high (active-low reset deasserted) |
| `camera_siod` | InOut | PMOD header | SCCB data (open-drain) |
| `camera_sioc` | Out | PMOD header | SCCB clock |
| `vga_red[3:0]` | Out | VGA connector | Red channel |
| `vga_green[3:0]` | Out | VGA connector | Green channel |
| `vga_blue[3:0]` | Out | VGA connector | Blue channel |
| `vga_hsync` | Out | VGA connector | Horizontal sync |
| `vga_vsync` | Out | VGA connector | Vertical sync |
| `filter_sel[2:0]` | In | SW[2:0] | Image filter select |
| `led[7:0]` | Out | LD[7:0] | Diagnostic LEDs |

---

## Neural Network Details

### Quantization

All weights and activations are **int8**. Biases are **int32**. After each convolution the 32-bit accumulator is right-shifted and rounded back to int8 by `requantize.v`. The shift amounts are defined in `scales.vh` (generated alongside the weight hex files by the training/export script).

The FC layer outputs raw int32 values. The confidence score is compared directly against the `THRESHOLD` parameter (default 500). The four bbox outputs are right-shifted by `FC_OUT_SHIFT` (from `scales.vh`) to recover patch-pixel coordinates, then scaled by the dilation factor to get frame coordinates.

<<<<<<< Updated upstream
| Subsystem | RTL path        | TB path         | Owner |
|-----------|-----------------|-----------------|-------|
| Camera    | `rtl/camera/`   | `tb/camera/`    | Nooyz |
| Filter    | `rtl/filter/`   | `tb/filter/`    | Nooyz |
| Detector  | `rtl/detector/` | `tb/detector/`  | Toodz |
| Overlay   | `rtl/overlay/`  | `tb/overlay/`   | Donoz |
| Top       | `rtl/top/`      | `tb/top/`       | TBD   |
=======
### Sliding Window Parameters (defaults)

| Parameter | Value | Meaning |
|---|---|---|
| `FRAME_W / FRAME_H` | 160 / 120 | Grayscale input frame size |
| `PATCH` | 24 | Network input patch size (pixels) |
| `STRIDE` | 16 | Scan stride in frame pixels |
| `DILATE` | 3 | Sub-sample stride when extracting patch |
| Effective receptive field | 72×72 px | `PATCH × DILATE` in the original frame |
| `THRESHOLD` | 500 | Minimum confidence to report a face |

---

## Building the Project

### Prerequisites

- Vivado 2020.x or later (for Artix-7 synthesis and `clk_wiz_0` IP)
- The weight hex files described below

### Steps

1. **Create a new Vivado project** targeting `xc7a35tcpg236-1` (Basys 3).

2. **Add all `.v` files** from this repository as design sources.

3. **Add `scales.vh`** (generated by training script) as a header source.

4. **Generate the Clock Wizard IP** (`clk_wiz_0`):
   - Input: 100 MHz
   - Output 1 (`clk_out1`): 25 MHz (VGA pixel clock)
   - Output 2 (`clk_out2`): 24 MHz (camera XCLK)

5. **Generate the Block Memory Generator IP** for `filter_frame_buffer` if you want to replace the behavioral model:
   - True Dual Port RAM, 12-bit width, 76800 depth (17-bit addressing)
   - See the comments inside `filter_frame_buffer.v`

6. **Add the weight hex files** to your project's working directory (see [Weight Files](#weight-files)).

7. **Apply the XDC constraints** file for Basys 3 pin assignments.

8. **Run Synthesis → Implementation → Generate Bitstream**, then program the board.

---

## Weight Files

The NN weight ROMs are loaded at synthesis time via `$readmemh`. The following files must be present in the project working directory (or the path given to `detector_top` parameters):

| File | Contents | Size |
|---|---|---|
| `conv1_w.hex` | Conv1 weights (int8) | 72 entries |
| `conv1_b.hex` | Conv1 biases (int32) | 8 entries |
| `conv2_w.hex` | Conv2 weights (int8) | 1152 entries |
| `conv2_b.hex` | Conv2 biases (int32) | 16 entries |
| `conv3_w.hex` | Conv3 weights (int8) | 2304 entries |
| `conv3_b.hex` | Conv3 biases (int32) | 16 entries |
| `fc_w.hex` | FC weights (int8) | 720 entries |
| `fc_b.hex` | FC biases (int32) | 5 entries |
| `scales.vh` | Requantization shifts | Verilog header |

These are generated by the companion Python training/export script. Each hex file contains one value per line in two's-complement hexadecimal (8-bit values as 2 hex digits; 32-bit values as 8 hex digits).

---

## LED Diagnostics

| LED | Signal | Meaning |
|---|---|---|
| LD0 | `config_done` | All 36 SCCB register writes completed |
| LD1 | `camera_vsync` | Live camera vertical sync |
| LD2 | `det_scan_done` | Pulses once per completed full-frame scan |
| LD3 | `det_face_valid` | A face is currently latched |
| LD4 | `sccb_busy` | SCCB transaction in progress |
| LD5 | `sccb_nak_seen` | A register write failed (not applicable in this open-loop driver) |
| LD6 | `cap_frame_format_ok` | Camera sending correct 640×480 VGA framing |
| LD7 | `cap_frame_heartbeat` | Toggles every camera frame (~30 Hz) |

**Expected power-on sequence:** LD4 blinks briefly as SCCB writes proceed, then LD0 lights permanently. LD7 should toggle steadily. LD6 should be high. If LD6 is low the camera is sending an unexpected resolution.

---

## Image Filters

Selected by SW[2:0] on the Basys 3:

| SW[2:0] | Filter |
|---|---|
| `000` | Pass-through (original color) |
| `001` | Grayscale — `Y ≈ (R + 2G + B) / 4` |
| `010` | Color inversion (negative) |
| `011` | Binary threshold — bright pixels → white, dark → black |
| `100` | Red channel only |
| `101` | Green channel only |
| `110` | Blue channel only |
| `111` | Brightness boost (+3 per channel, clamped at 15) |

Filters are applied to the display path only; the neural network always operates on the unfiltered grayscale stream.

---

## Design Notes

**SCCB / I2C:** The OV7670 uses Omnivision's SCCB protocol, which is I2C-compatible for writes. This implementation is open-loop (no ACK sampling) and sends 36 register writes covering: software reset, clock prescaler, PLL, RGB565 mode, color matrix, gamma curve, and AWB tuning.

**Pixel doubling:** The VGA output is 640×480 but the frame buffer holds 320×240. Each pixel is displayed in a 2×2 block by halving the VGA x/y coordinates when computing the read address, with one cycle of registered delay to absorb BRAM read latency.

**Bounding box hold:** When the detector finds no face in a scan, the last valid box is held for 8 subsequent scans before clearing. This prevents the overlay from flickering at the frame rate.

**Sequential MAC architecture:** Each `conv_layer` and `fc_layer` uses a single multiplier-accumulator running one multiply per clock cycle. This is resource-efficient on the Artix-7 but means each inference takes many thousands of cycles. Latency per patch: Conv1 ≈ 8×11×11×1×3×3 = 8712 cycles, Conv2 ≈ 16×5×5×8×3×3 = 28800 cycles, Conv3 ≈ 16×3×3×16×3×3 = 20736 cycles, FC ≈ 5×144 = 720 cycles.

**Synthesis tip:** The `filter_frame_buffer` behavioral model infers a block RAM correctly with Vivado's default settings. For tighter timing you can replace it with a Vivado Block Memory Generator IP instance as described in the file's comments.
>>>>>>> Stashed changes
