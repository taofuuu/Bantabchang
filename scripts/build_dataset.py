"""synthesize bbox training data by pasting resized faces into backgrounds.
outputs data/bbox_dataset.npz with patches, confs, and bboxes arrays."""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
from PIL import Image


PATCH_SIZE = 24

# face target sizes; each face generates this many positive variants
POS_SIZES = (10, 12, 14, 16, 18, 20, 22, 24)

SCRIPT_DIR = Path(__file__).resolve().parent
DATA_DIR   = SCRIPT_DIR.parent / "data"


def resize_face(face_u8: np.ndarray, target: int) -> np.ndarray:
    img = Image.fromarray(face_u8)
    img = img.resize((target, target), Image.BILINEAR)
    return np.array(img, dtype=np.uint8)


def paste_with_alpha(
    bg: np.ndarray, face: np.ndarray, x0: int, y0: int, blend: float
) -> np.ndarray:
    """paste face into bg at (x0, y0) with edge blending to avoid sharp seam."""
    h, w = face.shape
    out  = bg.copy()
    region = out[y0:y0 + h, x0:x0 + w].astype(np.float32)
    f      = face.astype(np.float32)
    out[y0:y0 + h, x0:x0 + w] = (blend * f + (1.0 - blend) * region).clip(0, 255).astype(np.uint8)
    return out


def build_positive_samples(
    faces: np.ndarray, backgrounds: np.ndarray, rng: np.random.Generator
) -> tuple[list[np.ndarray], list[tuple[float, float, float, float]]]:
    patches: list[np.ndarray] = []
    bboxes:  list[tuple[float, float, float, float]] = []
    n_bg = len(backgrounds)
    for face in faces:
        for size in POS_SIZES:
            bg_idx = int(rng.integers(0, n_bg))
            bg = backgrounds[bg_idx]
            face_resized = resize_face(face, size)
            max_pos = PATCH_SIZE - size
            x0 = int(rng.integers(0, max_pos + 1)) if max_pos > 0 else 0
            y0 = int(rng.integers(0, max_pos + 1)) if max_pos > 0 else 0
            blend = float(rng.uniform(0.85, 1.0))
            patch = paste_with_alpha(bg, face_resized, x0, y0, blend)
            patches.append(patch)
            bboxes.append((float(x0), float(y0), float(size), float(size)))
    return patches, bboxes


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--pos-in",  type=Path, default=DATA_DIR / "crops_pos.npy")
    p.add_argument("--neg-in",  type=Path, default=DATA_DIR / "crops_neg.npy")
    p.add_argument("--out",     type=Path, default=DATA_DIR / "bbox_dataset.npz")
    p.add_argument("--seed",    type=int,  default=0)
    args = p.parse_args()

    rng = np.random.default_rng(args.seed)

    faces       = np.load(args.pos_in)
    backgrounds = np.load(args.neg_in)
    assert faces.shape[1:]       == (PATCH_SIZE, PATCH_SIZE), faces.shape
    assert backgrounds.shape[1:] == (PATCH_SIZE, PATCH_SIZE), backgrounds.shape
    print(f"loaded {len(faces)} face crops, {len(backgrounds)} background crops")

    pos_patches, pos_bboxes = build_positive_samples(faces, backgrounds, rng)
    print(f"synthesised {len(pos_patches)} positive (face, bbox) samples"
          f"  ({len(faces)} faces x {len(POS_SIZES)} sizes)")

    # balance classes with background negatives
    n_neg_target = len(pos_patches)
    if len(backgrounds) < n_neg_target:
        idx = rng.choice(len(backgrounds), n_neg_target, replace=True)
        neg_patches = backgrounds[idx]
    else:
        idx = rng.choice(len(backgrounds), n_neg_target, replace=False)
        neg_patches = backgrounds[idx]

    patches = np.concatenate([np.stack(pos_patches).astype(np.uint8),
                              neg_patches.astype(np.uint8)], axis=0)
    confs   = np.concatenate([np.ones(len(pos_patches),  dtype=np.float32),
                              np.zeros(len(neg_patches), dtype=np.float32)], axis=0)
    bboxes  = np.concatenate([np.array(pos_bboxes, dtype=np.float32),
                              np.zeros((len(neg_patches), 4), dtype=np.float32)], axis=0)

    args.out.parent.mkdir(parents=True, exist_ok=True)
    np.savez(args.out, patches=patches, confs=confs, bboxes=bboxes)
    print(f"saved bbox dataset -> {args.out}")
    print(f"  shapes: patches={patches.shape}  confs={confs.shape}  bboxes={bboxes.shape}")
    print(f"  positives: {int(confs.sum())}   negatives: {len(confs) - int(confs.sum())}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
