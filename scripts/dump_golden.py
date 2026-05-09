"""Dump golden per-layer activations for bit-exact RTL verification.

For each test patch, runs the integer reference model and saves every layer's
input / accumulator / output as a hex file. The SystemVerilog testbenches
($readmemh + assert) read these to verify byte-for-byte equivalence with the
Python reference.

Reads:  data/model_int8.pt
        data/crops_pos.npy   data/crops_neg.npy
Writes: data/golden/inputs.hex          int8, N_test * 24 * 24
        data/golden/conv1_acc.hex       int32, N_test * 11 * 11 * 8
        data/golden/conv1_act.hex       int8,  N_test * 11 * 11 * 8
        data/golden/conv2_acc.hex       int32, N_test * 5 * 5 * 16
        data/golden/conv2_act.hex       int8,  N_test * 5 * 5 * 16
        data/golden/conv3_acc.hex       int32, N_test * 3 * 3 * 16
        data/golden/conv3_act.hex       int8,  N_test * 3 * 3 * 16
        data/golden/logits.hex          int32, N_test * 2
        data/golden/labels.hex          uint8, N_test (1=face, 0=non-face)
        data/golden/manifest.txt        shapes + counts so the TB can sanity-check

Tensor flatten order is C-order with channel-innermost, matching the conv
weight order in export_weights.py.

Usage:
  python dump_golden.py --n-test 50
"""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import torch

from quantize import IntegerFaceCNN


SCRIPT_DIR = Path(__file__).resolve().parent
DATA_DIR = SCRIPT_DIR.parent / "data"


def int8_hex(v: int) -> str:
    return f"{v & 0xFF:02x}"


def int32_hex(v: int) -> str:
    return f"{v & 0xFFFFFFFF:08x}"


def write_int_hex(path: Path, arr: np.ndarray, width: int, header: str) -> None:
    fmt = int8_hex if width == 8 else int32_hex
    with open(path, "w") as f:
        f.write(f"// {header}\n")
        f.write(f"// {arr.size} values\n")
        for v in arr.flatten().tolist():
            f.write(fmt(int(v)) + "\n")


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--in-pt", type=Path, default=DATA_DIR / "model_int8.pt")
    p.add_argument("--n-test", type=int, default=50)
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--out-dir", type=Path, default=DATA_DIR / "golden")
    args = p.parse_args()

    rng = np.random.default_rng(args.seed)

    pos = np.load(DATA_DIR / "crops_pos.npy")
    neg = np.load(DATA_DIR / "crops_neg.npy")
    n_per = args.n_test // 2
    pos_idx = rng.choice(len(pos), n_per, replace=False)
    neg_idx = rng.choice(len(neg), args.n_test - n_per, replace=False)
    test_u8 = np.concatenate([pos[pos_idx], neg[neg_idx]], axis=0).astype(np.uint8)
    labels = np.concatenate([np.ones(n_per, dtype=np.uint8),
                             np.zeros(args.n_test - n_per, dtype=np.uint8)])

    state = torch.load(args.in_pt, map_location="cpu", weights_only=True)
    int_model = IntegerFaceCNN(
        state["w1_q"], state["b1_q"], state["shift1"],
        state["w2_q"], state["b2_q"], state["shift2"],
        state["w3_q"], state["b3_q"], state["shift3"],
        state["wfc_q"], state["bfc_q"],
    )

    # Forward all test inputs at once
    x_uint8 = torch.from_numpy(test_u8).unsqueeze(1).to(torch.float32)
    logits, mids = int_model.forward(x_uint8)

    args.out_dir.mkdir(parents=True, exist_ok=True)

    write_int_hex(args.out_dir / "inputs.hex",
                  mids["input_int8"].to(torch.int32).numpy().astype(np.int32),
                  width=8, header="int8 inputs (uint8_pixel - 128), shape=(N,1,24,24)")
    write_int_hex(args.out_dir / "conv1_acc.hex",
                  mids["acc1"].to(torch.int32).numpy(),
                  width=32, header="conv1 int32 accumulator, shape=(N,8,11,11)")
    write_int_hex(args.out_dir / "conv1_act.hex",
                  mids["a1"].to(torch.int32).numpy(),
                  width=8, header="conv1 int8 post-ReLU activation, shape=(N,8,11,11)")
    write_int_hex(args.out_dir / "conv2_acc.hex",
                  mids["acc2"].to(torch.int32).numpy(),
                  width=32, header="conv2 int32 accumulator, shape=(N,16,5,5)")
    write_int_hex(args.out_dir / "conv2_act.hex",
                  mids["a2"].to(torch.int32).numpy(),
                  width=8, header="conv2 int8 post-ReLU activation, shape=(N,16,5,5)")
    write_int_hex(args.out_dir / "conv3_acc.hex",
                  mids["acc3"].to(torch.int32).numpy(),
                  width=32, header="conv3 int32 accumulator, shape=(N,16,3,3)")
    write_int_hex(args.out_dir / "conv3_act.hex",
                  mids["a3"].to(torch.int32).numpy(),
                  width=8, header="conv3 int8 post-ReLU activation, shape=(N,16,3,3)")
    write_int_hex(args.out_dir / "logits.hex",
                  logits.to(torch.int32).numpy(),
                  width=32, header="fc int32 logits, shape=(N,2)")
    write_int_hex(args.out_dir / "labels.hex",
                  labels.astype(np.int32),
                  width=8, header="ground-truth labels, shape=(N,)")

    with open(args.out_dir / "manifest.txt", "w") as f:
        f.write(f"n_test {args.n_test}\n")
        f.write("input_shape 1 24 24\n")
        f.write("conv1_shape 8 11 11\n")
        f.write("conv2_shape 16 5 5\n")
        f.write("conv3_shape 16 3 3\n")
        f.write("logits_shape 2\n")

    # Sanity report
    pred = logits.argmax(dim=1).numpy()
    acc = (pred == labels).mean()
    print(f"golden vectors written to {args.out_dir}")
    print(f"int8 model accuracy on {args.n_test} test patches: {acc:.4f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
