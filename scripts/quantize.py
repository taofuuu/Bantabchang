"""post-training INT8 quantization with power-of-two scales.
fc head has 5 outputs: conf logit + bbox (x0,y0,w,h) in patch pixels.
reads data/model_float.pt, writes data/model_int8.json and data/model_int8.pt."""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F

from model import FaceBBoxCNN, INPUT_SIZE


SCRIPT_DIR = Path(__file__).resolve().parent
DATA_DIR   = SCRIPT_DIR.parent / "data"

INT8_MAX = 127
INT8_MIN = -128
W_MAX    = 127


def pow2_scale_exp(max_abs: float) -> int:
    if max_abs <= 0:
        return 30
    return int(math.floor(math.log2(W_MAX / max_abs)))


def quantize_tensor(t: torch.Tensor, scale_exp: int) -> torch.Tensor:
    scale = 2.0 ** scale_exp
    return torch.round(t * scale).clamp(INT8_MIN, INT8_MAX).to(torch.int8)


def arith_right_shift_round(x: torch.Tensor, n: int) -> torch.Tensor:
    if n <= 0:
        return x * (2.0 ** (-n))
    bias = 0.5 * (2.0 ** n)
    return torch.floor((x + bias) / (2.0 ** n))


def relu_clip_int8(x: torch.Tensor) -> torch.Tensor:
    return x.clamp(0, INT8_MAX)


def calibrate_activation_max(model: FaceBBoxCNN, calib_x: torch.Tensor) -> dict[str, float]:
    model.eval()
    with torch.no_grad():
        a = model.forward_with_activations(calib_x)
    return {
        "input": float(calib_x.abs().max().item()),
        "conv1": float(a["conv1"].abs().max().item()),
        "conv2": float(a["conv2"].abs().max().item()),
        "conv3": float(a["conv3"].abs().max().item()),
    }


class IntegerFaceBBoxCNN:
    def __init__(
        self,
        w1_q, b1_q, shift1,
        w2_q, b2_q, shift2,
        w3_q, b3_q, shift3,
        wfc_q, bfc_q,
        fc_out_shift,
    ) -> None:
        self.w1_q, self.b1_q, self.shift1 = w1_q, b1_q, shift1
        self.w2_q, self.b2_q, self.shift2 = w2_q, b2_q, shift2
        self.w3_q, self.b3_q, self.shift3 = w3_q, b3_q, shift3
        self.wfc_q, self.bfc_q = wfc_q, bfc_q
        self.fc_out_shift = fc_out_shift

    def _conv(self, x_int8, w_int8, b_int32, stride):
        x = x_int8.to(torch.float32)
        w = w_int8.to(torch.float32)
        b = b_int32.to(torch.float32)
        return F.conv2d(x, w, bias=b, stride=stride, padding=0)

    def _forward_layers(self, x_uint8: torch.Tensor):
        a0 = (x_uint8.to(torch.int16) - 128).clamp(INT8_MIN, INT8_MAX).to(torch.int8)

        acc1 = self._conv(a0,  self.w1_q, self.b1_q, stride=2)
        a1   = relu_clip_int8(arith_right_shift_round(acc1, self.shift1)).to(torch.int8)

        acc2 = self._conv(a1,  self.w2_q, self.b2_q, stride=2)
        a2   = relu_clip_int8(arith_right_shift_round(acc2, self.shift2)).to(torch.int8)

        acc3 = self._conv(a2,  self.w3_q, self.b3_q, stride=1)
        a3   = relu_clip_int8(arith_right_shift_round(acc3, self.shift3)).to(torch.int8)

        flat     = a3.reshape(a3.shape[0], -1).to(torch.float32)
        fc_int32 = flat @ self.wfc_q.to(torch.float32).t() + self.bfc_q.to(torch.float32)
        fc_dequant = fc_int32 / (2.0 ** self.fc_out_shift)
        mids = {
            "input_int8": a0,
            "acc1": acc1, "a1": a1,
            "acc2": acc2, "a2": a2,
            "acc3": acc3, "a3": a3,
            "fc_int32": fc_int32,
        }
        return fc_dequant, mids

    def forward(self, x_uint8: torch.Tensor) -> torch.Tensor:
        # dequantize to pixel/logit units
        fc_dequant, _ = self._forward_layers(x_uint8)
        return fc_dequant

    def forward_with_intermediates(
        self, x_uint8: torch.Tensor
    ) -> tuple[torch.Tensor, dict[str, torch.Tensor]]:
        return self._forward_layers(x_uint8)


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--ckpt",       type=Path, default=DATA_DIR / "model_float.pt")
    p.add_argument("--dataset",    type=Path, default=DATA_DIR / "bbox_dataset.npz")
    p.add_argument("--out-json",   type=Path, default=DATA_DIR / "model_int8.json")
    p.add_argument("--out-pt",     type=Path, default=DATA_DIR / "model_int8.pt")
    p.add_argument("--calib-size", type=int,  default=512)
    p.add_argument("--seed",       type=int,  default=0)
    args = p.parse_args()

    torch.manual_seed(args.seed)
    rng = np.random.default_rng(args.seed)

    blob    = np.load(args.dataset)
    patches = blob["patches"]
    confs   = blob["confs"]
    bboxes  = blob["bboxes"]

    pos_idx = np.where(confs > 0.5)[0]
    neg_idx = np.where(confs < 0.5)[0]
    n = min(args.calib_size // 2, len(pos_idx), len(neg_idx))
    pos_pick = rng.choice(pos_idx, n, replace=False)
    neg_pick = rng.choice(neg_idx, n, replace=False)

    calib_u8 = np.concatenate([patches[pos_pick], patches[neg_pick]], axis=0).astype(np.float32)
    calib_x  = torch.from_numpy((calib_u8 - 128.0) / 128.0).unsqueeze(1)
    calib_x_uint8 = torch.from_numpy(np.concatenate([patches[pos_pick], patches[neg_pick]], axis=0)
                                     .astype(np.float32)).unsqueeze(1)
    calib_conf = torch.cat([
        torch.ones(n, dtype=torch.float32),
        torch.zeros(n, dtype=torch.float32),
    ])
    calib_bbox = torch.cat([
        torch.from_numpy(bboxes[pos_pick]).float(),
        torch.zeros(n, 4, dtype=torch.float32),
    ])

    model = FaceBBoxCNN()
    model.load_state_dict(torch.load(args.ckpt, map_location="cpu"))
    model.eval()

    # float accuracy on calibration set
    with torch.no_grad():
        float_out = model(calib_x)
    float_conf_correct = ((torch.sigmoid(float_out[:, 0]) > 0.5).float() == calib_conf).float().mean().item()
    pos_mask = calib_conf > 0.5
    float_bbox_mae = float((float_out[pos_mask, 1:5] - calib_bbox[pos_mask]).abs().mean().item())
    print(f"float  conf_acc={float_conf_correct:.4f}  bbox_mae={float_bbox_mae:.3f}px")

    act_max = calibrate_activation_max(model, calib_x)
    print(f"activation max (float space): {act_max}")

    sa1 = pow2_scale_exp(act_max["conv1"])
    sa2 = pow2_scale_exp(act_max["conv2"])
    sa3 = pow2_scale_exp(act_max["conv3"])
    sa_in = 7

    w1, b1 = model.conv1.weight.detach(), model.conv1.bias.detach()
    w2, b2 = model.conv2.weight.detach(), model.conv2.bias.detach()
    w3, b3 = model.conv3.weight.detach(), model.conv3.bias.detach()
    wfc, bfc = model.fc.weight.detach(), model.fc.bias.detach()

    sw1  = pow2_scale_exp(float(w1.abs().max().item()))
    sw2  = pow2_scale_exp(float(w2.abs().max().item()))
    sw3  = pow2_scale_exp(float(w3.abs().max().item()))
    swfc = pow2_scale_exp(float(wfc.abs().max().item()))

    w1_q  = quantize_tensor(w1,  sw1)
    w2_q  = quantize_tensor(w2,  sw2)
    w3_q  = quantize_tensor(w3,  sw3)
    wfc_q = quantize_tensor(wfc, swfc)

    def quant_bias_int32(b: torch.Tensor, total_exp: int) -> torch.Tensor:
        return torch.round(b * (2.0 ** total_exp)).to(torch.int32)

    b1_q  = quant_bias_int32(b1,  sw1  + sa_in)
    b2_q  = quant_bias_int32(b2,  sw2  + sa1)
    b3_q  = quant_bias_int32(b3,  sw3  + sa2)
    bfc_q = quant_bias_int32(bfc, swfc + sa3)

    shift1 = (sw1  + sa_in) - sa1
    shift2 = (sw2  + sa1)  - sa2
    shift3 = (sw3  + sa2)  - sa3
    fc_out_shift = swfc + sa3
    print(f"weight scales: sw1={sw1} sw2={sw2} sw3={sw3} swfc={swfc}")
    print(f"act scales:    sa_in={sa_in} sa1={sa1} sa2={sa2} sa3={sa3}")
    print(f"requant shifts: c1={shift1} c2={shift2} c3={shift3}  fc_out_shift={fc_out_shift}")
    if min(shift1, shift2, shift3) <= 0:
        print("WARNING: a requantization shift is <= 0 -- consider retraining.")

    int_model = IntegerFaceBBoxCNN(
        w1_q, b1_q, shift1,
        w2_q, b2_q, shift2,
        w3_q, b3_q, shift3,
        wfc_q, bfc_q,
        fc_out_shift,
    )

    with torch.no_grad():
        int_out = int_model.forward(calib_x_uint8)
    int_conf_correct = ((torch.sigmoid(int_out[:, 0]) > 0.5).float() == calib_conf).float().mean().item()
    int_bbox_mae = float((int_out[pos_mask, 1:5] - calib_bbox[pos_mask]).abs().mean().item())
    print(f"int8   conf_acc={int_conf_correct:.4f}  bbox_mae={int_bbox_mae:.3f}px"
          f"  (drops: conf {float_conf_correct-int_conf_correct:+.4f}, "
          f"bbox {int_bbox_mae-float_bbox_mae:+.3f}px)")

    out = {
        "input_scale_exp":   sa_in,
        "input_zero_point":  128,
        "fc_out_shift":      fc_out_shift,
        "layers": {
            "conv1": {"weight_scale_exp": sw1,  "weight_shape": list(w1_q.shape),
                       "weight": w1_q.flatten().tolist(),
                       "bias":   b1_q.tolist(), "requant_shift": shift1, "stride": 2},
            "conv2": {"weight_scale_exp": sw2,  "weight_shape": list(w2_q.shape),
                       "weight": w2_q.flatten().tolist(),
                       "bias":   b2_q.tolist(), "requant_shift": shift2, "stride": 2},
            "conv3": {"weight_scale_exp": sw3,  "weight_shape": list(w3_q.shape),
                       "weight": w3_q.flatten().tolist(),
                       "bias":   b3_q.tolist(), "requant_shift": shift3, "stride": 1},
            "fc":    {"weight_scale_exp": swfc, "weight_shape": list(wfc_q.shape),
                       "weight": wfc_q.flatten().tolist(),
                       "bias":   bfc_q.tolist()},
        },
        "act_scale_exps": {"input": sa_in, "conv1": sa1, "conv2": sa2, "conv3": sa3},
        "calibration": {
            "float_conf_acc": float_conf_correct,
            "int8_conf_acc":  int_conf_correct,
            "float_bbox_mae": float_bbox_mae,
            "int8_bbox_mae":  int_bbox_mae,
        },
    }
    args.out_json.parent.mkdir(parents=True, exist_ok=True)
    with open(args.out_json, "w") as f:
        json.dump(out, f, indent=2)
    print(f"saved -> {args.out_json}")

    torch.save(
        {
            "w1_q": w1_q, "b1_q": b1_q, "shift1": shift1,
            "w2_q": w2_q, "b2_q": b2_q, "shift2": shift2,
            "w3_q": w3_q, "b3_q": b3_q, "shift3": shift3,
            "wfc_q": wfc_q, "bfc_q": bfc_q,
            "sa_in": sa_in, "sa1": sa1, "sa2": sa2, "sa3": sa3,
            "sw1": sw1, "sw2": sw2, "sw3": sw3, "swfc": swfc,
            "fc_out_shift": fc_out_shift,
        },
        args.out_pt,
    )
    print(f"saved -> {args.out_pt}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
