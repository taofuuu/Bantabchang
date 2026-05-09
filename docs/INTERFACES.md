# Module Interfaces

Single source of truth for every signal that crosses a subsystem boundary. If you change a signal here, ping every owner before you push.

All modules share a single 100 MHz clock domain (`clk`) and active-high synchronous reset (`rst`).

---

## 1. Camera → Filter

**Owner:** camera

OV7670 capture block produces an 8-bit grayscale stream synced to `clk`.

| Signal        | Dir | Width | Description                                         |
|---------------|-----|-------|-----------------------------------------------------|
| `pixel`       | out | 8     | Grayscale pixel, valid when `pixel_valid` is high   |
| `pixel_valid` | out | 1     | One-cycle pulse per pixel                           |
| `frame_start` | out | 1     | One-cycle pulse on the very first pixel of a frame  |
| `line_start`  | out | 1     | One-cycle pulse on the first pixel of each row      |

**Resolution:** 160×120, scanned left-to-right, top-to-bottom.
**Backpressure:** none — downstream must consume in real time (≥30 fps × 19,200 px).

---

## 2. Filter → Detector

**Owner:** filter (upstream), detector (downstream)

Filter passes through the same handshake as Camera→Filter after preprocessing (e.g. gamma, contrast). Signal contract is identical.

| Signal        | Dir | Width | Description                          |
|---------------|-----|-------|--------------------------------------|
| `pixel`       | out | 8     | Filtered grayscale pixel             |
| `pixel_valid` | out | 1     | Valid strobe                         |
| `frame_start` | out | 1     | Frame boundary                       |
| `line_start`  | out | 1     | Line boundary                        |

If the filter has latency, it MUST still output exactly 19,200 pixels per frame and re-emit `frame_start` / `line_start` aligned to its own output stream.

---

## 3. Detector → Overlay

**Owner:** detector (upstream), overlay (downstream)

The detector latches a single bounding box per frame into a small register file. Overlay reads it asynchronously when drawing the VGA frame.

| Signal       | Dir | Width | Description                                          |
|--------------|-----|-------|------------------------------------------------------|
| `face_valid` | out | 1     | 1 if a face was detected this frame, 0 otherwise     |
| `face_x`     | out | 8     | Top-left X in 160×120 coords (0–159)                 |
| `face_y`     | out | 7     | Top-left Y in 160×120 coords (0–119)                 |
| `face_w`     | out | 8     | Box width in 160×120 coords                          |
| `face_h`     | out | 7     | Box height in 160×120 coords                         |

**Update timing:** all five signals update atomically on the cycle after the last patch of a frame is classified. They remain stable until the next frame's update.

**Coordinate space:** 160×120. Overlay scales ×4 to draw on 640×480 VGA.

**Simplifications (agreed):** single bounding box (no NMS), single scale, fixed score threshold.

---

## 4. Overlay → VGA

**Owner:** overlay

Standard 640×480 @ 60 Hz VGA timing. Pixel clock 25 MHz derived from `clk` via MMCM/clocking wizard.

| Signal       | Dir | Width | Description           |
|--------------|-----|-------|-----------------------|
| `vga_red`    | out | 4     | Red channel           |
| `vga_green`  | out | 4     | Green channel         |
| `vga_blue`   | out | 4     | Blue channel          |
| `vga_hsync`  | out | 1     | Horizontal sync       |
| `vga_vsync`  | out | 1     | Vertical sync         |

Overlay reads camera frame from a shared frame buffer (or re-uses upstream buffer; TBD by overlay owner) and superimposes the bounding box from the detector's register file.

---

## Top-level wiring (system_top.v)

```
camera ─► filter ─► detector ─┐
   │         │                ├─► overlay ─► VGA pins
   └─────────┴── frame buffer ┘
```

`rtl/top/system_top.v` instantiates one of each subsystem and connects them per the tables above. Each subsystem's port list MUST match the signal names here exactly so `system_top.v` is just wiring, not glue logic.
