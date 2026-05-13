"""train FaceBBoxCNN on the bbox dataset.
loss = BCE-with-logits(conf) + lambda * SmoothL1(bbox, positives only).
reads data/bbox_dataset.npz, saves data/model_float.pt."""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.utils.data import DataLoader, Dataset

from model import FaceBBoxCNN, INPUT_SIZE, BBOX_DIMS, split_outputs


SCRIPT_DIR = Path(__file__).resolve().parent
DATA_DIR   = SCRIPT_DIR.parent / "data"


def to_tensor(patch_u8: np.ndarray) -> torch.Tensor:
    return torch.from_numpy((patch_u8.astype(np.float32) - 128.0) / 128.0).unsqueeze(0)


class BBoxDataset(Dataset):
    def __init__(
        self,
        patches: np.ndarray,
        confs:   np.ndarray,
        bboxes:  np.ndarray,
        augment: bool,
    ) -> None:
        self.patches = patches
        self.confs   = confs
        self.bboxes  = bboxes
        self.augment = augment
        self.rng     = np.random.default_rng()

    def __len__(self) -> int:
        return len(self.patches)

    def _augment(
        self, p: np.ndarray, conf: float, bbox: np.ndarray
    ) -> tuple[np.ndarray, np.ndarray]:
        # horizontal flip, mirror bbox x
        if self.rng.random() < 0.5:
            p = p[:, ::-1]
            if conf > 0.5:
                bbox = bbox.copy()
                bbox[0] = INPUT_SIZE - bbox[0] - bbox[2]
        # brightness jitter
        if self.rng.random() < 0.7:
            delta = int(self.rng.integers(-30, 30))
            p = np.clip(p.astype(np.int16) + delta, 0, 255).astype(np.uint8)
        # sensor noise
        if self.rng.random() < 0.5:
            sigma = self.rng.uniform(2.0, 8.0)
            noise = self.rng.normal(0.0, sigma, p.shape)
            p = np.clip(p.astype(np.float32) + noise, 0, 255).astype(np.uint8)
        return np.ascontiguousarray(p), bbox

    def __getitem__(self, idx: int) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
        p    = self.patches[idx]
        conf = float(self.confs[idx])
        bbox = self.bboxes[idx]
        if self.augment:
            p, bbox = self._augment(p, conf, bbox)
        return (
            to_tensor(p),
            torch.tensor(conf, dtype=torch.float32),
            torch.tensor(bbox, dtype=torch.float32),
        )


def split_dataset(
    patches: np.ndarray, confs: np.ndarray, bboxes: np.ndarray, val_frac: float
) -> tuple[BBoxDataset, BBoxDataset]:
    rng = np.random.default_rng(0)
    idx = rng.permutation(len(patches))
    n_val = int(len(patches) * val_frac)
    val_i = idx[:n_val]
    tr_i  = idx[n_val:]
    return (
        BBoxDataset(patches[tr_i], confs[tr_i], bboxes[tr_i], augment=True),
        BBoxDataset(patches[val_i], confs[val_i], bboxes[val_i], augment=False),
    )


def compute_loss(
    fc_out: torch.Tensor,
    confs:  torch.Tensor,
    bboxes: torch.Tensor,
    lambda_bbox: float,
) -> tuple[torch.Tensor, dict[str, float]]:
    conf_logit, bbox_pred = split_outputs(fc_out)
    conf_loss = F.binary_cross_entropy_with_logits(conf_logit, confs)

    # bbox loss only on positives
    pos_mask = confs > 0.5
    if pos_mask.any():
        bbox_loss = F.smooth_l1_loss(bbox_pred[pos_mask], bboxes[pos_mask])
    else:
        bbox_loss = torch.tensor(0.0, device=fc_out.device)

    total = conf_loss + lambda_bbox * bbox_loss
    return total, {
        "loss":      float(total.item()),
        "conf_loss": float(conf_loss.item()),
        "bbox_loss": float(bbox_loss.item()),
    }


def evaluate(model: nn.Module, loader: DataLoader, device: str, lambda_bbox: float) -> dict:
    model.eval()
    tot = {"loss": 0.0, "conf_loss": 0.0, "bbox_loss": 0.0}
    n_conf_correct = 0
    n_total        = 0
    bbox_err_l1    = 0.0
    bbox_n         = 0
    with torch.no_grad():
        for x, c, b in loader:
            x, c, b = x.to(device), c.to(device), b.to(device)
            out = model(x)
            _, info = compute_loss(out, c, b, lambda_bbox)
            for k in tot:
                tot[k] += info[k] * x.size(0)
            n_total += x.size(0)

            conf_logit, bbox_pred = split_outputs(out)
            pred_face = (torch.sigmoid(conf_logit) > 0.5).float()
            n_conf_correct += int((pred_face == c).sum().item())

            pos_mask = c > 0.5
            if pos_mask.any():
                bbox_err_l1 += float((bbox_pred[pos_mask] - b[pos_mask]).abs().sum().item())
                bbox_n      += int(pos_mask.sum().item()) * BBOX_DIMS

    n = max(n_total, 1)
    return {
        "loss":      tot["loss"]      / n,
        "conf_loss": tot["conf_loss"] / n,
        "bbox_loss": tot["bbox_loss"] / n,
        "conf_acc":  n_conf_correct   / n,
        "bbox_mae":  bbox_err_l1 / max(bbox_n, 1),
    }


def maybe_init_from_classifier(model: FaceBBoxCNN, classifier_pt: Path) -> bool:
    """copy conv weights from an old classifier checkpoint as warm start.
    fc layer shape differs so we skip it."""
    if not classifier_pt.exists():
        return False
    try:
        sd = torch.load(classifier_pt, map_location="cpu")
    except Exception:
        return False
    own = model.state_dict()
    copied = 0
    for k in ("conv1.weight", "conv1.bias",
              "conv2.weight", "conv2.bias",
              "conv3.weight", "conv3.bias"):
        if k in sd and sd[k].shape == own[k].shape:
            own[k] = sd[k]
            copied += 1
    if copied > 0:
        model.load_state_dict(own)
    return copied > 0


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--data",        type=Path,  default=DATA_DIR / "bbox_dataset.npz")
    p.add_argument("--epochs",      type=int,   default=50)
    p.add_argument("--batch",       type=int,   default=128)
    p.add_argument("--lr",          type=float, default=1e-3)
    p.add_argument("--val-frac",    type=float, default=0.15)
    p.add_argument("--lambda-bbox", type=float, default=0.05,
                   help="Weight on the bbox regression loss")
    p.add_argument("--warm-start-from", type=Path, default=DATA_DIR / "model_float_classifier.pt",
                   help="Optional path to an old classifier checkpoint whose "
                        "conv weights we copy over for initialisation")
    p.add_argument("--seed",        type=int,   default=0)
    p.add_argument("--out",         type=Path,  default=DATA_DIR / "model_float.pt")
    args = p.parse_args()

    torch.manual_seed(args.seed)
    np.random.seed(args.seed)

    blob   = np.load(args.data)
    patches = blob["patches"]
    confs   = blob["confs"]
    bboxes  = blob["bboxes"]
    print(f"dataset: patches={patches.shape}  pos={int(confs.sum())}  neg={int((1 - confs).sum())}")

    train_ds, val_ds = split_dataset(patches, confs, bboxes, args.val_frac)
    train_loader = DataLoader(train_ds, batch_size=args.batch, shuffle=True,  num_workers=0)
    val_loader   = DataLoader(val_ds,   batch_size=args.batch, shuffle=False, num_workers=0)

    device = "cuda" if torch.cuda.is_available() else "cpu"
    model  = FaceBBoxCNN().to(device)

    if maybe_init_from_classifier(model, args.warm_start_from):
        print(f"warm-started conv layers from {args.warm_start_from}")
    opt = torch.optim.Adam(model.parameters(), lr=args.lr)

    best_score = -float("inf")
    for epoch in range(args.epochs):
        model.train()
        for x, c, b in train_loader:
            x, c, b = x.to(device), c.to(device), b.to(device)
            out = model(x)
            loss, _ = compute_loss(out, c, b, args.lambda_bbox)
            opt.zero_grad()
            loss.backward()
            opt.step()

        m = evaluate(model, val_loader, device, args.lambda_bbox)
        # higher conf_acc and lower bbox_mae is better
        score = m["conf_acc"] - 0.02 * m["bbox_mae"]
        flag  = "  *" if score > best_score else ""
        print(
            f"epoch {epoch+1:02d}/{args.epochs}  "
            f"val_loss={m['loss']:.4f}  "
            f"conf_acc={m['conf_acc']:.4f}  "
            f"bbox_mae={m['bbox_mae']:.3f}px{flag}"
        )
        if score > best_score:
            best_score = score
            torch.save(model.state_dict(), args.out)

    print(f"best composite={best_score:.4f}  saved -> {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
