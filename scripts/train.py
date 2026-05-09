"""Train the float FaceCNN on the prepared crops.

Inputs:
  data/crops_pos.npy  (N_pos, 24, 24) uint8
  data/crops_neg.npy  (N_neg, 24, 24) uint8

Output:
  data/model_float.pt   state_dict of the trained model

Usage:
  python train.py --epochs 30
"""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.utils.data import DataLoader, Dataset

from model import FaceCNN, INPUT_SIZE


SCRIPT_DIR = Path(__file__).resolve().parent
DATA_DIR = SCRIPT_DIR.parent / "data"


def to_tensor(patch_u8: np.ndarray) -> torch.Tensor:
    # (H, W) uint8 -> (1, H, W) float32 in [-1, 127/128].
    # Matches integer-inference convention: int8_input = uint8_pixel - 128, scale 2^-7.
    return torch.from_numpy((patch_u8.astype(np.float32) - 128.0) / 128.0).unsqueeze(0)


class PatchDataset(Dataset):
    def __init__(self, patches: np.ndarray, label: int, augment: bool = False) -> None:
        self.patches = patches
        self.label = label
        self.augment = augment
        self.rng = np.random.default_rng()

    def __len__(self) -> int:
        return len(self.patches)

    def _augment(self, p: np.ndarray) -> np.ndarray:
        # horizontal flip
        if self.rng.random() < 0.5:
            p = p[:, ::-1]
        # brightness jitter
        if self.rng.random() < 0.7:
            delta = int(self.rng.integers(-30, 30))
            p = np.clip(p.astype(np.int16) + delta, 0, 255).astype(np.uint8)
        # gaussian noise (mimic OV7670 sensor noise)
        if self.rng.random() < 0.5:
            sigma = self.rng.uniform(2.0, 8.0)
            noise = self.rng.normal(0.0, sigma, p.shape)
            p = np.clip(p.astype(np.float32) + noise, 0, 255).astype(np.uint8)
        return np.ascontiguousarray(p)

    def __getitem__(self, idx: int) -> tuple[torch.Tensor, int]:
        p = self.patches[idx]
        if self.augment:
            p = self._augment(p)
        return to_tensor(p), self.label


def make_loaders(
    pos: np.ndarray, neg: np.ndarray, val_frac: float, batch: int
) -> tuple[DataLoader, DataLoader]:
    rng = np.random.default_rng(0)
    pos_idx = rng.permutation(len(pos))
    neg_idx = rng.permutation(len(neg))
    n_pos_val = int(len(pos) * val_frac)
    n_neg_val = int(len(neg) * val_frac)

    pos_train = pos[pos_idx[n_pos_val:]]
    pos_val = pos[pos_idx[:n_pos_val]]
    neg_train = neg[neg_idx[n_neg_val:]]
    neg_val = neg[neg_idx[:n_neg_val]]

    train = torch.utils.data.ConcatDataset(
        [PatchDataset(pos_train, 1, augment=True), PatchDataset(neg_train, 0, augment=True)]
    )
    val = torch.utils.data.ConcatDataset(
        [PatchDataset(pos_val, 1, augment=False), PatchDataset(neg_val, 0, augment=False)]
    )
    return (
        DataLoader(train, batch_size=batch, shuffle=True, num_workers=0),
        DataLoader(val, batch_size=batch, shuffle=False, num_workers=0),
    )


def evaluate(model: nn.Module, loader: DataLoader, device: str) -> tuple[float, float]:
    model.eval()
    correct = 0
    total = 0
    loss_sum = 0.0
    with torch.no_grad():
        for x, y in loader:
            x, y = x.to(device), y.to(device)
            logits = model(x)
            loss_sum += F.cross_entropy(logits, y, reduction="sum").item()
            correct += (logits.argmax(1) == y).sum().item()
            total += y.numel()
    return correct / max(total, 1), loss_sum / max(total, 1)


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--epochs", type=int, default=30)
    p.add_argument("--batch", type=int, default=128)
    p.add_argument("--lr", type=float, default=1e-3)
    p.add_argument("--val-frac", type=float, default=0.15)
    p.add_argument("--seed", type=int, default=0)
    p.add_argument("--out", type=Path, default=DATA_DIR / "model_float.pt")
    args = p.parse_args()

    torch.manual_seed(args.seed)
    np.random.seed(args.seed)

    pos = np.load(DATA_DIR / "crops_pos.npy")
    neg = np.load(DATA_DIR / "crops_neg.npy")
    assert pos.shape[1:] == (INPUT_SIZE, INPUT_SIZE), pos.shape
    assert neg.shape[1:] == (INPUT_SIZE, INPUT_SIZE), neg.shape
    print(f"loaded {len(pos)} positives, {len(neg)} negatives")

    train_loader, val_loader = make_loaders(pos, neg, args.val_frac, args.batch)

    device = "cuda" if torch.cuda.is_available() else "cpu"
    model = FaceCNN().to(device)
    opt = torch.optim.Adam(model.parameters(), lr=args.lr)

    best_acc = 0.0
    for epoch in range(args.epochs):
        model.train()
        for x, y in train_loader:
            x, y = x.to(device), y.to(device)
            logits = model(x)
            loss = F.cross_entropy(logits, y)
            opt.zero_grad()
            loss.backward()
            opt.step()
        acc, vloss = evaluate(model, val_loader, device)
        print(f"epoch {epoch+1:02d}/{args.epochs}  val_acc={acc:.4f}  val_loss={vloss:.4f}")
        if acc > best_acc:
            best_acc = acc
            torch.save(model.state_dict(), args.out)

    print(f"best val_acc={best_acc:.4f}  saved -> {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
