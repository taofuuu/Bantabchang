"""Add your own photos to the training data and retrain.

STEP 1 – collect photos (phone or any camera):
  • photos/pos/  put photos that contain a face (one main face per photo is fine)
  • photos/neg/  put photos of your room / background with NO faces

STEP 2 – run this script:
  python scripts/add_own_photos.py

STEP 3 – the script will:
  1. Simulate OV7670 degradation (downsample → 160x120 grayscale + noise)
  2. Auto-detect faces in pos/ with OpenCV Haar cascade
  3. Extract 24x24 face patches  (positives)
  4. Extract 24x24 background patches from non-face regions (negatives)
  5. Append both to data/crops_pos.npy / data/crops_neg.npy
  6. Run build_dataset → train → quantize → export automatically

Tips for taking photos:
  • Vary distance (face should be 20-80% of frame height)
  • Vary lighting (overhead, side-lit, dim)
  • Vary angles (straight, slight turn, slight up/down)
  • For neg/ : photograph the walls, furniture, shelves in your lab — especially
    anything that produced false positives on the FPGA
  • ~30-50 face photos and ~30-50 background photos make a noticeable difference
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

import cv2
import numpy as np
from PIL import Image

SCRIPT_DIR = Path(__file__).resolve().parent
DATA_DIR   = SCRIPT_DIR.parent / "data"

FRAME_W  = 160
FRAME_H  = 120
PATCH    = 24

# OpenCV Haar cascade bundled with opencv-python
CASCADE_PATH = Path(cv2.__file__).parent / "data" / "haarcascade_frontalface_default.xml"

# OV7670 noise simulation: Gaussian sigma typical for a cheap CMOS sensor
OV7670_NOISE_SIGMA = 4.0


# ---------- OV7670 simulation ------------------------------------------------

def sim_ov7670(img_path: Path, rng: np.random.Generator) -> np.ndarray:
    """Load any photo and simulate what the OV7670 would produce: 160x120 uint8 grayscale."""
    img = Image.open(img_path).convert("L")                      # grayscale
    img = img.resize((FRAME_W, FRAME_H), Image.BILINEAR)         # downsample
    arr = np.array(img, dtype=np.float32)
    noise = rng.normal(0.0, OV7670_NOISE_SIGMA, arr.shape)
    arr = np.clip(arr + noise, 0, 255).astype(np.uint8)
    return arr


# ---------- face detection ---------------------------------------------------

def detect_faces(frame_u8: np.ndarray) -> list[tuple[int, int, int, int]]:
    """Return list of (x, y, w, h) face bounding boxes in the 160x120 frame."""
    if not CASCADE_PATH.exists():
        print(f"WARNING: Haar cascade not found at {CASCADE_PATH}. "
              "Skipping face detection — treating whole image centre as face.")
        cx, cy = FRAME_W // 2, FRAME_H // 2
        s = min(FRAME_W, FRAME_H) // 2
        return [(cx - s // 2, cy - s // 2, s, s)]

    cascade = cv2.CascadeClassifier(str(CASCADE_PATH))
    faces = cascade.detectMultiScale(
        frame_u8,
        scaleFactor=1.05,
        minNeighbors=2,
        minSize=(10, 10),
    )
    if len(faces) == 0:
        return []
    return [(int(x), int(y), int(w), int(h)) for x, y, w, h in faces]


# ---------- patch extraction -------------------------------------------------

def extract_face_patches(
    frame_u8: np.ndarray,
    faces: list[tuple[int, int, int, int]],
) -> list[np.ndarray]:
    """For each detected face, crop a 24x24 patch centred on it."""
    patches = []
    for (fx, fy, fw, fh) in faces:
        cx = fx + fw // 2
        cy = fy + fh // 2
        # Place a PATCH-sized window centred on the face, clamped to frame
        x0 = max(0, min(cx - PATCH // 2, FRAME_W - PATCH))
        y0 = max(0, min(cy - PATCH // 2, FRAME_H - PATCH))
        crop = frame_u8[y0 : y0 + PATCH, x0 : x0 + PATCH]
        if crop.shape == (PATCH, PATCH):
            patches.append(crop.copy())
    return patches


def extract_background_patches(
    frame_u8: np.ndarray,
    faces: list[tuple[int, int, int, int]],
    n: int,
    rng: np.random.Generator,
) -> list[np.ndarray]:
    """Sample n random 24x24 patches from regions well away from detected faces."""
    face_mask = np.zeros((FRAME_H, FRAME_W), dtype=bool)
    margin = PATCH
    for (fx, fy, fw, fh) in faces:
        x0 = max(0, fx - margin)
        y0 = max(0, fy - margin)
        x1 = min(FRAME_W, fx + fw + margin)
        y1 = min(FRAME_H, fy + fh + margin)
        face_mask[y0:y1, x0:x1] = True

    # Build list of valid top-left corners
    valid = []
    for y in range(0, FRAME_H - PATCH + 1, 4):
        for x in range(0, FRAME_W - PATCH + 1, 4):
            if not face_mask[y : y + PATCH, x : x + PATCH].any():
                valid.append((x, y))

    if not valid:
        return []

    chosen = rng.choice(len(valid), size=min(n, len(valid)), replace=False)
    patches = []
    for idx in chosen:
        x, y = valid[idx]
        patches.append(frame_u8[y : y + PATCH, x : x + PATCH].copy())
    return patches


# ---------- main -------------------------------------------------------------

def process_folder(
    folder: Path,
    is_pos: bool,
    rng: np.random.Generator,
    negs_per_frame: int,
) -> tuple[list[np.ndarray], list[np.ndarray]]:
    exts = {".jpg", ".jpeg", ".png", ".bmp", ".webp"}
    images = [p for p in sorted(folder.iterdir()) if p.suffix.lower() in exts]
    if not images:
        print(f"  No images found in {folder}")
        return [], []

    pos_out, neg_out = [], []
    n_face_found = 0
    n_face_missed = 0

    for img_path in images:
        frame = sim_ov7670(img_path, rng)

        if is_pos:
            faces = detect_faces(frame)
            if not faces:
                print(f"  [no face detected] {img_path.name}  "
                      f"(treating image centre as face)")
                # Fall back: use image centre
                cx, cy = FRAME_W // 2, FRAME_H // 2
                x0 = max(0, cx - PATCH // 2)
                y0 = max(0, cy - PATCH // 2)
                faces = [(x0, y0, PATCH, PATCH)]
                n_face_missed += 1
            else:
                n_face_found += 1

            pos_out.extend(extract_face_patches(frame, faces))
            neg_out.extend(extract_background_patches(frame, faces, negs_per_frame, rng))
        else:
            # neg folder: treat entire frame as background
            neg_out.extend(extract_background_patches(frame, [], negs_per_frame, rng))

    if is_pos:
        print(f"  {len(images)} images: faces auto-detected in {n_face_found}, "
              f"centre-fallback in {n_face_missed}")
    else:
        print(f"  {len(images)} background images processed")

    return pos_out, neg_out


def run_pipeline(epochs: int) -> None:
    steps = [
        ([sys.executable, "scripts/build_dataset.py"],          "Building dataset ..."),
        ([sys.executable, "scripts/train.py", "--epochs", str(epochs)], f"Training ({epochs} epochs) ..."),
        ([sys.executable, "scripts/quantize.py"],               "Quantizing ..."),
        ([sys.executable, "scripts/export_weights.py"],         "Exporting weights ..."),
        ([sys.executable, "scripts/dump_golden.py"],            "Generating golden vectors ..."),
    ]
    for cmd, msg in steps:
        print(f"\n{msg}")
        result = subprocess.run(cmd, cwd=SCRIPT_DIR.parent)
        if result.returncode != 0:
            print(f"ERROR: step failed: {' '.join(cmd)}")
            sys.exit(1)


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--pos-dir",       type=Path, default=Path("photos/pos"),
                   help="Folder of face photos (default: photos/pos/)")
    p.add_argument("--neg-dir",       type=Path, default=Path("photos/neg"),
                   help="Folder of background photos (default: photos/neg/)")
    p.add_argument("--negs-per-frame", type=int, default=4,
                   help="Background patches to extract per image (default 4)")
    p.add_argument("--epochs",        type=int, default=60,
                   help="Training epochs for the retrain step (default 60)")
    p.add_argument("--no-pipeline",   action="store_true",
                   help="Only update crops_*.npy, do not retrain")
    p.add_argument("--seed",          type=int, default=42)
    args = p.parse_args()

    rng = np.random.default_rng(args.seed)

    # Resolve dirs relative to repo root so the script works from anywhere
    root     = SCRIPT_DIR.parent
    pos_dir  = (root / args.pos_dir) if not args.pos_dir.is_absolute() else args.pos_dir
    neg_dir  = (root / args.neg_dir) if not args.neg_dir.is_absolute() else args.neg_dir

    all_pos, all_neg = [], []

    if pos_dir.exists():
        print(f"\nProcessing face photos from {pos_dir} ...")
        p_pos, p_neg = process_folder(pos_dir, is_pos=True,  rng=rng,
                                      negs_per_frame=args.negs_per_frame)
        all_pos.extend(p_pos)
        all_neg.extend(p_neg)
    else:
        print(f"WARNING: pos dir not found: {pos_dir}")

    if neg_dir.exists():
        print(f"\nProcessing background photos from {neg_dir} ...")
        _, n_neg = process_folder(neg_dir, is_pos=False, rng=rng,
                                  negs_per_frame=args.negs_per_frame)
        all_neg.extend(n_neg)
    else:
        print(f"WARNING: neg dir not found: {neg_dir}")

    if not all_pos and not all_neg:
        print("\nNo crops extracted. Create photos/pos/ and photos/neg/ and add images.")
        return 1

    # Load existing crops and append
    crops_pos_path = DATA_DIR / "crops_pos.npy"
    crops_neg_path = DATA_DIR / "crops_neg.npy"

    def load_or_empty(path: Path) -> np.ndarray:
        if path.exists():
            return np.load(path)
        return np.zeros((0, PATCH, PATCH), dtype=np.uint8)

    existing_pos = load_or_empty(crops_pos_path)
    existing_neg = load_or_empty(crops_neg_path)

    new_pos = np.stack(all_pos).astype(np.uint8) if all_pos else np.zeros((0, PATCH, PATCH), dtype=np.uint8)
    new_neg = np.stack(all_neg).astype(np.uint8) if all_neg else np.zeros((0, PATCH, PATCH), dtype=np.uint8)

    merged_pos = np.concatenate([existing_pos, new_pos], axis=0)
    merged_neg = np.concatenate([existing_neg, new_neg], axis=0)

    np.save(crops_pos_path, merged_pos)
    np.save(crops_neg_path, merged_neg)

    print(f"\ncrops_pos: {len(existing_pos)} existing + {len(new_pos)} new = {len(merged_pos)} total")
    print(f"crops_neg: {len(existing_neg)} existing + {len(new_neg)} new = {len(merged_neg)} total")

    if args.no_pipeline:
        print("\nSkipping pipeline (--no-pipeline). Run manually when ready:")
        print("  python scripts/build_dataset.py")
        print(f"  python scripts/train.py --epochs {args.epochs}")
        print("  python scripts/quantize.py && python scripts/export_weights.py")
    else:
        run_pipeline(args.epochs)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
