"""extract face/background crops from the LFW dataset.
positive: centre 150x150 → 24x24. negative: two 70x70 corner crops → 24x24.
if sklearn cache is missing, run fetch_lfw_people first (see README)."""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
from PIL import Image


PATCH     = 24
FACE_CROP = 150   # centre square used as face region (px)
CORNER_SZ = 70    # corner square used as background (px)

SCRIPT_DIR = Path(__file__).resolve().parent
DATA_DIR   = SCRIPT_DIR.parent / "data"
RAW_DIR    = DATA_DIR / "raw"
LFW_DIR    = RAW_DIR / "lfw_home" / "lfw_funneled"


## helpers

def _to_patch(arr: np.ndarray) -> np.ndarray:
    return np.array(
        Image.fromarray(arr).resize((PATCH, PATCH), Image.BILINEAR),
        dtype=np.uint8,
    )


def extract_crops(
    lfw_dir: Path,
    rng: np.random.Generator,
) -> tuple[list[np.ndarray], list[np.ndarray]]:
    jpg_files = sorted(lfw_dir.rglob("*.jpg"))
    if not jpg_files:
        raise FileNotFoundError(
            f"No JPEG files found under {lfw_dir}.\n"
            "Run: python -c \"from sklearn.datasets import fetch_lfw_people; "
            "fetch_lfw_people(min_faces_per_person=1, color=False, data_home='data/raw')\""
        )

    print(f"Found {len(jpg_files)} images — extracting crops ...")
    rng.shuffle(jpg_files)

    pos_crops: list[np.ndarray] = []
    neg_crops: list[np.ndarray] = []

    for i, path in enumerate(jpg_files):
        if (i + 1) % 2000 == 0:
            print(f"  {i+1}/{len(jpg_files)}  pos={len(pos_crops)}  neg={len(neg_crops)}")
        try:
            img = Image.open(path).convert("L")
            arr = np.array(img, dtype=np.uint8)
        except Exception:
            continue

        h, w = arr.shape
        if h < FACE_CROP or w < FACE_CROP:
            continue

        # positive: centre crop
        cy, cx = h // 2, w // 2
        r = FACE_CROP // 2
        face = arr[cy - r : cy + r, cx - r : cx + r]
        pos_crops.append(_to_patch(face))

        # negatives: 2 random corner crops
        c = CORNER_SZ
        corners = [
            arr[:c,  :c ],   # top-left
            arr[:c,  -c:],   # top-right
            arr[-c:, :c ],   # bottom-left
            arr[-c:, -c:],   # bottom-right
        ]
        for idx in rng.choice(4, size=2, replace=False):
            neg_crops.append(_to_patch(corners[idx]))

    return pos_crops, neg_crops


## main

def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--max-pos", type=int, default=5000,
                   help="Max positive (face) crops to save (default 5000)")
    p.add_argument("--max-neg", type=int, default=5000,
                   help="Max negative (background) crops to save (default 5000)")
    p.add_argument("--lfw-dir", type=Path, default=LFW_DIR,
                   help="Path to the lfw_funneled directory")
    p.add_argument("--out-dir", type=Path, default=DATA_DIR)
    p.add_argument("--seed",    type=int,  default=0)
    args = p.parse_args()

    rng = np.random.default_rng(args.seed)

    pos_all, neg_all = extract_crops(args.lfw_dir, rng)
    print(f"Extracted: {len(pos_all)} positives, {len(neg_all)} negatives")

    rng.shuffle(pos_all)
    rng.shuffle(neg_all)
    crops_pos = np.stack(pos_all[: args.max_pos])
    crops_neg = np.stack(neg_all[: args.max_neg])

    args.out_dir.mkdir(parents=True, exist_ok=True)
    np.save(args.out_dir / "crops_pos.npy", crops_pos)
    np.save(args.out_dir / "crops_neg.npy", crops_neg)

    print(f"crops_pos : {crops_pos.shape}  -> {args.out_dir / 'crops_pos.npy'}")
    print(f"crops_neg : {crops_neg.shape}  -> {args.out_dir / 'crops_neg.npy'}")
    print()
    print("Next steps:")
    print("  python scripts/build_dataset.py")
    print("  python scripts/train.py --epochs 60")
    print("  python scripts/quantize.py")
    print("  python scripts/export_weights.py")
    print("  python scripts/dump_golden.py")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
