"""Build a face / no-face dataset of 24x24 grayscale uint8 patches.

Outputs:
  data/crops_pos.npy  (N_pos, 24, 24) uint8
  data/crops_neg.npy  (N_neg, 24, 24) uint8

Sources supported (any combination, mix and match):
  --pos-dir DIR     directory of face images (any size; will be resized to 24x24)
  --neg-dir DIR     directory of non-face images (random 24x24 crops sampled per image)
  --olivetti        also include sklearn's Olivetti faces (400 frontal faces, free)
  --synth-neg N     also generate N synthetic negatives (random noise + edges)

Augmentation is applied at training time (in train.py), NOT here, so this
script just produces clean canonical crops.

Usage:
  python build_dataset.py --olivetti --synth-neg 4000
  python build_dataset.py --pos-dir faces/ --neg-dir backgrounds/
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

import numpy as np
from PIL import Image


PATCH_SIZE = 24
SCRIPT_DIR = Path(__file__).resolve().parent
DATA_DIR = SCRIPT_DIR.parent / "data"


def load_image_gray(path: Path) -> np.ndarray | None:
    try:
        img = Image.open(path).convert("L")
        return np.array(img, dtype=np.uint8)
    except Exception:
        return None


def crops_from_face_dir(pos_dir: Path) -> list[np.ndarray]:
    crops: list[np.ndarray] = []
    exts = {".png", ".jpg", ".jpeg", ".bmp", ".pgm"}
    for path in sorted(pos_dir.rglob("*")):
        if path.suffix.lower() not in exts:
            continue
        img = load_image_gray(path)
        if img is None:
            continue
        # whole image is assumed to be a face crop already; resize to PATCH_SIZE
        resized = np.array(
            Image.fromarray(img).resize((PATCH_SIZE, PATCH_SIZE), Image.BILINEAR),
            dtype=np.uint8,
        )
        crops.append(resized)
    return crops


def random_crops_from_image(
    img: np.ndarray, n: int, rng: np.random.Generator
) -> list[np.ndarray]:
    h, w = img.shape
    if h < PATCH_SIZE or w < PATCH_SIZE:
        return []
    out = []
    for _ in range(n):
        y = rng.integers(0, h - PATCH_SIZE + 1)
        x = rng.integers(0, w - PATCH_SIZE + 1)
        out.append(img[y : y + PATCH_SIZE, x : x + PATCH_SIZE].copy())
    return out


def crops_from_neg_dir(
    neg_dir: Path, per_image: int, rng: np.random.Generator
) -> list[np.ndarray]:
    crops: list[np.ndarray] = []
    exts = {".png", ".jpg", ".jpeg", ".bmp", ".pgm"}
    for path in sorted(neg_dir.rglob("*")):
        if path.suffix.lower() not in exts:
            continue
        img = load_image_gray(path)
        if img is None:
            continue
        crops.extend(random_crops_from_image(img, per_image, rng))
    return crops


def crops_from_olivetti() -> list[np.ndarray]:
    # sklearn ships Olivetti at 64x64; 400 grayscale frontal faces.
    from sklearn.datasets import fetch_olivetti_faces

    ds = fetch_olivetti_faces()
    out = []
    for face in ds.images:
        face_u8 = (face * 255.0).clip(0, 255).astype(np.uint8)
        resized = np.array(
            Image.fromarray(face_u8).resize((PATCH_SIZE, PATCH_SIZE), Image.BILINEAR),
            dtype=np.uint8,
        )
        out.append(resized)
    return out


def synth_negatives(n: int, rng: np.random.Generator) -> list[np.ndarray]:
    # Mix of pure noise, lines, and gradients — gives the classifier easy negatives
    # and trains it to ignore non-face textures.
    out = []
    for _ in range(n):
        kind = rng.integers(0, 3)
        if kind == 0:
            patch = rng.integers(0, 256, (PATCH_SIZE, PATCH_SIZE), dtype=np.uint8)
        elif kind == 1:
            base = rng.integers(0, 256)
            patch = np.full((PATCH_SIZE, PATCH_SIZE), base, dtype=np.uint8)
            for _ in range(rng.integers(1, 5)):
                y = rng.integers(0, PATCH_SIZE)
                patch[y, :] = rng.integers(0, 256)
        else:
            v = np.linspace(
                rng.integers(0, 256), rng.integers(0, 256), PATCH_SIZE, dtype=np.float32
            )
            if rng.integers(0, 2) == 0:
                patch = np.tile(v, (PATCH_SIZE, 1)).astype(np.uint8)
            else:
                patch = np.tile(v[:, None], (1, PATCH_SIZE)).astype(np.uint8)
        out.append(patch)
    return out


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--pos-dir", type=Path)
    p.add_argument("--neg-dir", type=Path)
    p.add_argument("--neg-per-image", type=int, default=8)
    p.add_argument("--olivetti", action="store_true")
    p.add_argument("--synth-neg", type=int, default=0)
    p.add_argument("--seed", type=int, default=0)
    p.add_argument("--out-dir", type=Path, default=DATA_DIR)
    args = p.parse_args()

    rng = np.random.default_rng(args.seed)

    pos: list[np.ndarray] = []
    neg: list[np.ndarray] = []

    if args.pos_dir:
        pos.extend(crops_from_face_dir(args.pos_dir))
    if args.olivetti:
        pos.extend(crops_from_olivetti())
    if args.neg_dir:
        neg.extend(crops_from_neg_dir(args.neg_dir, args.neg_per_image, rng))
    if args.synth_neg > 0:
        neg.extend(synth_negatives(args.synth_neg, rng))

    if not pos:
        print("ERROR: no positive samples produced — pass --pos-dir or --olivetti", file=sys.stderr)
        return 1
    if not neg:
        print("ERROR: no negative samples produced — pass --neg-dir or --synth-neg N", file=sys.stderr)
        return 1

    pos_arr = np.stack(pos).astype(np.uint8)
    neg_arr = np.stack(neg).astype(np.uint8)

    args.out_dir.mkdir(parents=True, exist_ok=True)
    np.save(args.out_dir / "crops_pos.npy", pos_arr)
    np.save(args.out_dir / "crops_neg.npy", neg_arr)

    print(f"saved {pos_arr.shape} positives -> {args.out_dir / 'crops_pos.npy'}")
    print(f"saved {neg_arr.shape} negatives -> {args.out_dir / 'crops_neg.npy'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
