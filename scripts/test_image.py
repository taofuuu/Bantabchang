"""sliding-window face detection on a real image using the int8 reference model.
downsamples to 160x120, scans 24x24 patches, saves annotated 640x480 result.png."""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import torch
from PIL import Image, ImageDraw

from quantize import IntegerFaceBBoxCNN


SCRIPT_DIR = Path(__file__).resolve().parent
DATA_DIR = SCRIPT_DIR.parent / "data"

FRAME_W = 160
FRAME_H = 120
PATCH = 24
VGA_SCALE = 4  # FPGA pipeline upscales 160x120 -> 640x480 for VGA


def load_int_model(pt_path: Path) -> IntegerFaceBBoxCNN:
    state = torch.load(pt_path, map_location="cpu", weights_only=True)
    return IntegerFaceBBoxCNN(
        state["w1_q"], state["b1_q"], state["shift1"],
        state["w2_q"], state["b2_q"], state["shift2"],
        state["w3_q"], state["b3_q"], state["shift3"],
        state["wfc_q"], state["bfc_q"],
        state["fc_out_shift"],
    )


def slide_and_score(
    frame_u8: np.ndarray, model: IntegerFaceBBoxCNN, stride: int
) -> list[tuple[int, int, float]]:
    """run int8 model over all stride-spaced 24x24 windows; return (x, y, score) list."""
    patches = []
    coords: list[tuple[int, int]] = []
    for y in range(0, FRAME_H - PATCH + 1, stride):
        for x in range(0, FRAME_W - PATCH + 1, stride):
            patches.append(frame_u8[y : y + PATCH, x : x + PATCH])
            coords.append((x, y))
    batch = torch.from_numpy(np.stack(patches)).unsqueeze(1).to(torch.float32)
    out = model.forward(batch)   # (N, 5): [conf_logit, cx, cy, w, h]
    scores = out[:, 0].numpy()
    return [(coords[i][0], coords[i][1], float(scores[i])) for i in range(len(coords))]


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("image", type=Path, help="path to input image (any size, color or gray)")
    p.add_argument("--in-pt", type=Path, default=DATA_DIR / "model_int8.pt")
    p.add_argument("--stride", type=int, default=4,
                   help="sliding-window stride in 160x120 pixel units (default 4)")
    p.add_argument("--threshold", type=float, default=0.0,
                   help="minimum confidence logit to count as a hit (default 0.0)")
    p.add_argument("--top-k", type=int, default=0,
                   help="if >0, draw only the K strongest hits")
    p.add_argument("--out", type=Path, default=DATA_DIR / "review" / "result.png")
    args = p.parse_args()

    if not args.image.exists():
        print(f"ERROR: image not found: {args.image}")
        return 1

    # step 1: load and downsample to 160x120
    raw = Image.open(args.image).convert("L")
    resized = raw.resize((FRAME_W, FRAME_H), Image.BILINEAR)
    frame_u8 = np.array(resized, dtype=np.uint8)
    print(f"loaded {args.image.name} (orig {raw.size[0]}x{raw.size[1]}), "
          f"downsampled to {FRAME_W}x{FRAME_H}")

    # step 2: load int8 model
    model = load_int_model(args.in_pt)

    # step 3: sliding window scan
    hits_all = slide_and_score(frame_u8, model, args.stride)
    hits = [(x, y, s) for (x, y, s) in hits_all if s >= args.threshold]
    hits.sort(key=lambda h: -h[2])
    if args.top_k > 0:
        hits = hits[: args.top_k]

    score_min = min(s for _, _, s in hits_all)
    score_max = max(s for _, _, s in hits_all)
    print(f"scanned {len(hits_all)} patches  | "
          f"score range [{score_min}, {score_max}]  | "
          f"{len(hits)} above threshold {args.threshold}")
    for i, (x, y, s) in enumerate(hits[:10]):
        marker = "  <-- strongest" if i == 0 else ""
        print(f"  hit {i:2d}: x={x:3d} y={y:3d} score={s:6.2f}{marker}")

    # step 4: render 640x480 canvas
    out_w = FRAME_W * VGA_SCALE
    out_h = FRAME_H * VGA_SCALE
    canvas_gray = resized.resize((out_w, out_h), Image.NEAREST)
    canvas = canvas_gray.convert("RGB")
    draw = ImageDraw.Draw(canvas)
    for i, (x, y, _score) in enumerate(hits):
        x0 = x * VGA_SCALE
        y0 = y * VGA_SCALE
        x1 = (x + PATCH) * VGA_SCALE
        y1 = (y + PATCH) * VGA_SCALE
        # strongest hit is bright red and thick; others darker and thin
        if i == 0:
            draw.rectangle([x0, y0, x1, y1], outline=(255, 0, 0), width=3)
        else:
            draw.rectangle([x0, y0, x1, y1], outline=(160, 0, 0), width=1)

    args.out.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(args.out)
    print(f"wrote annotated result -> {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
