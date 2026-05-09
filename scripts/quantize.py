"""Post-training INT8 quantization with per-tensor symmetric power-of-two scales.

Why power-of-two: requantization between layers reduces to an arithmetic right
shift with rounding, no multiplier or divider needed in the Verilog datapath.

Numeric model:
  - Input pixel (uint8 in [0,255]) is mapped to int8 by subtracting 128, giving
    int8 in [-128,127]. The implied scale is s_input = 1/128 = 2^-7.
  - All weights and post-ReLU activations are int8 in [-128,127] (clamped to
    [0,127] after ReLU). Biases are stored as int32, pre-scaled to match
    s_w * s_a_prev so they slot into the int32 accumulator directly.
  - After each conv: int32 accumulator -> requantize (right-shift + round +
    relu clamp) -> int8 next-layer activation.
  - FC layer outputs are kept as int32 logits. Detection = (logit[1] - logit[0]) > thr.

Inputs:
  data/model_float.pt       trained float model (state_dict)
  data/crops_pos.npy        used as calibration set
  data/crops_neg.npy

Outputs:
  data/model_int8.json      everything Verilog needs:
                              - per-layer int8 weight tensors
                              - per-layer int32 bias tensors
                              - per-layer requant shifts (number of right-shift bits)
                              - input zero-point and scale exponent
                              - reference accuracy on calibration set
  data/model_int8.pt        a frozen torch reference that runs the integer math in
                              float, used for golden-vector dumps + accuracy check.

Usage:
  python quantize.py
"""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F

from model import FaceCNN, INPUT_SIZE


SCRIPT_DIR = Path(__file__).resolve().parent
DATA_DIR = SCRIPT_DIR.parent / "data"

INT8_MAX = 127
INT8_MIN = -128
W_MAX = 127  # symmetric: weights/biases use range [-127, 127]


def pow2_scale_exp(max_abs: float) -> int:
    """Return integer N such that scale = 2^-N quantizes max_abs into [-127, 127].

    We pick the smallest N (largest scale) that keeps round(max_abs * 2^N) <= 127.
    Equivalently: N = floor(log2(127 / max_abs)).
    """
    if max_abs <= 0:
        return 30  # arbitrary; tensor is all-zero, scale won't be used
    return int(math.floor(math.log2(W_MAX / max_abs)))


def quantize_tensor(t: torch.Tensor, scale_exp: int) -> torch.Tensor:
    """Quantize a float tensor with scale 2^-scale_exp to int8."""
    scale = 2.0 ** scale_exp
    q = torch.round(t * scale).clamp(INT8_MIN, INT8_MAX).to(torch.int8)
    return q


def dequantize_tensor(q: torch.Tensor, scale_exp: int) -> torch.Tensor:
    return q.to(torch.float32) / (2.0 ** scale_exp)


def calibrate_activation_max(
    model: FaceCNN, calib_x: torch.Tensor
) -> dict[str, float]:
    """Run float model on calibration set, capture max |activation| at each layer's
    post-ReLU output. Returns dict keyed by layer name."""
    model.eval()
    with torch.no_grad():
        a = model.forward_with_activations(calib_x)
    return {
        "input": float(calib_x.abs().max().item()),
        "conv1": float(a["conv1"].abs().max().item()),
        "conv2": float(a["conv2"].abs().max().item()),
        "conv3": float(a["conv3"].abs().max().item()),
    }


def round_half_up(x: torch.Tensor) -> torch.Tensor:
    """Banker-free rounding: round(x + 0.5) - matches Verilog 'add 0.5 then floor'."""
    return torch.floor(x + 0.5)


def arith_right_shift_round(x: torch.Tensor, n: int) -> torch.Tensor:
    """Simulate Verilog: y = (x + (1<<(n-1))) >>> n   (signed arithmetic shift).

    Implemented in float: divide by 2^n with round-half-up, then floor.
    """
    if n <= 0:
        return x * (2.0 ** (-n))
    bias = 0.5 * (2.0 ** n)
    return torch.floor((x + bias) / (2.0 ** n))


def relu_clip_int8(x: torch.Tensor) -> torch.Tensor:
    return x.clamp(0, INT8_MAX)


class IntegerFaceCNN:
    """Pure-integer reference of the quantized model. Operates on int8/int32
    tensors, reproduces what the Verilog will compute."""

    def __init__(
        self,
        w1_q: torch.Tensor, b1_q: torch.Tensor, shift1: int,
        w2_q: torch.Tensor, b2_q: torch.Tensor, shift2: int,
        w3_q: torch.Tensor, b3_q: torch.Tensor, shift3: int,
        wfc_q: torch.Tensor, bfc_q: torch.Tensor,
    ) -> None:
        self.w1_q, self.b1_q, self.shift1 = w1_q, b1_q, shift1
        self.w2_q, self.b2_q, self.shift2 = w2_q, b2_q, shift2
        self.w3_q, self.b3_q, self.shift3 = w3_q, b3_q, shift3
        self.wfc_q, self.bfc_q = wfc_q, bfc_q

    def _conv(
        self, x_int8: torch.Tensor, w_int8: torch.Tensor, b_int32: torch.Tensor, stride: int
    ) -> torch.Tensor:
        # F.conv2d in float, with int8 inputs cast up. Result is the integer accumulator.
        x = x_int8.to(torch.float32)
        w = w_int8.to(torch.float32)
        b = b_int32.to(torch.float32)
        y = F.conv2d(x, w, bias=b, stride=stride, padding=0)
        return y  # still integer-valued, kept as float for arithmetic convenience

    def forward(self, x_uint8: torch.Tensor) -> tuple[torch.Tensor, dict[str, torch.Tensor]]:
        # input: (N, 1, 24, 24) uint8 in [0,255] -> int8 by subtracting 128
        a0 = (x_uint8.to(torch.int16) - 128).clamp(INT8_MIN, INT8_MAX).to(torch.int8)

        acc1 = self._conv(a0, self.w1_q, self.b1_q, stride=2)
        a1 = relu_clip_int8(arith_right_shift_round(acc1, self.shift1)).to(torch.int8)

        acc2 = self._conv(a1, self.w2_q, self.b2_q, stride=2)
        a2 = relu_clip_int8(arith_right_shift_round(acc2, self.shift2)).to(torch.int8)

        acc3 = self._conv(a2, self.w3_q, self.b3_q, stride=1)
        a3 = relu_clip_int8(arith_right_shift_round(acc3, self.shift3)).to(torch.int8)

        flat = a3.reshape(a3.shape[0], -1).to(torch.float32)
        logits = flat @ self.wfc_q.to(torch.float32).t() + self.bfc_q.to(torch.float32)

        intermediates = {
            "input_int8": a0, "acc1": acc1, "a1": a1, "acc2": acc2, "a2": a2,
            "acc3": acc3, "a3": a3, "logits": logits,
        }
        return logits, intermediates

    def predict(self, x_uint8: torch.Tensor) -> torch.Tensor:
        logits, _ = self.forward(x_uint8)
        return logits.argmax(dim=1)


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--ckpt", type=Path, default=DATA_DIR / "model_float.pt")
    p.add_argument("--out-json", type=Path, default=DATA_DIR / "model_int8.json")
    p.add_argument("--out-pt", type=Path, default=DATA_DIR / "model_int8.pt")
    p.add_argument("--calib-size", type=int, default=512)
    p.add_argument("--seed", type=int, default=0)
    args = p.parse_args()

    torch.manual_seed(args.seed)
    rng = np.random.default_rng(args.seed)

    pos = np.load(DATA_DIR / "crops_pos.npy")
    neg = np.load(DATA_DIR / "crops_neg.npy")

    # Build a balanced calibration set
    n = min(args.calib_size // 2, len(pos), len(neg))
    pos_idx = rng.choice(len(pos), n, replace=False)
    neg_idx = rng.choice(len(neg), n, replace=False)
    calib_u8 = np.concatenate([pos[pos_idx], neg[neg_idx]], axis=0).astype(np.float32)
    # Float model trained on (uint8 - 128) / 128 -> matches integer model exactly.
    calib_x = torch.from_numpy((calib_u8 - 128.0) / 128.0).unsqueeze(1)
    calib_x_uint8 = torch.from_numpy(np.concatenate([pos[pos_idx], neg[neg_idx]], axis=0)).unsqueeze(1)
    calib_y = torch.cat([torch.ones(n, dtype=torch.long), torch.zeros(n, dtype=torch.long)])

    model = FaceCNN()
    model.load_state_dict(torch.load(args.ckpt, map_location="cpu"))
    model.eval()

    # Check float accuracy on calibration set
    with torch.no_grad():
        float_pred = model(calib_x).argmax(1)
    float_acc = (float_pred == calib_y).float().mean().item()
    print(f"float model accuracy on calibration set: {float_acc:.4f}")

    # ----- Choose activation scale exponents -----
    # The float model takes input in [0,1]. The integer model takes uint8 - 128 in
    # [-128, 127] which equals (float_input - 0.5) * 256 in scaled units. To make
    # the two equivalent we need to fold a /256 into the first conv weights (or
    # equivalently treat the int8 input as having scale 2^-7, since 128 = 2^7).
    #
    # We use scale_exp_input = 7 (int8 value v represents float v / 128).
    # Calibration was done in [0,1] float space, so we must scale max-abs
    # observations by 256 to express them in the integer model's domain.
    act_max = calibrate_activation_max(model, calib_x)
    print(f"calibration activation max (float space): {act_max}")

    # In integer space, post-ReLU activation 'a' represents float value
    # a / 2^scale_exp_a. We pick scale_exp_a so that max_int_value <= 127.
    # max_int = max_float * 2^scale_exp_a   ->   scale_exp_a = floor(log2(127/max_float))
    # Float space input here ranges 0..1, but our int input range is -128..127
    # representing float -1..~1, so the float-space activation maxes need scaling
    # by 2 (input was [0,1] but we feed [-1,1]-ish). Conservative: use the
    # float-space max directly with input represented as int8 / 128 (range -1..1).
    sa1 = pow2_scale_exp(act_max["conv1"])
    sa2 = pow2_scale_exp(act_max["conv2"])
    sa3 = pow2_scale_exp(act_max["conv3"])
    sa_in = 7  # input fixed at 2^-7

    # ----- Quantize weights -----
    w1, b1 = model.conv1.weight.detach(), model.conv1.bias.detach()
    w2, b2 = model.conv2.weight.detach(), model.conv2.bias.detach()
    w3, b3 = model.conv3.weight.detach(), model.conv3.bias.detach()
    wfc, bfc = model.fc.weight.detach(), model.fc.bias.detach()

    sw1 = pow2_scale_exp(float(w1.abs().max().item()))
    sw2 = pow2_scale_exp(float(w2.abs().max().item()))
    sw3 = pow2_scale_exp(float(w3.abs().max().item()))
    swfc = pow2_scale_exp(float(wfc.abs().max().item()))

    w1_q = quantize_tensor(w1, sw1)
    w2_q = quantize_tensor(w2, sw2)
    w3_q = quantize_tensor(w3, sw3)
    wfc_q = quantize_tensor(wfc, swfc)

    # Bias scale = scale_w * scale_a_prev = 2^-(sw + sa_prev). Bias is stored as int32.
    def quant_bias_int32(b: torch.Tensor, total_exp: int) -> torch.Tensor:
        scale = 2.0 ** total_exp
        q = torch.round(b * scale).to(torch.int32)
        return q

    b1_q = quant_bias_int32(b1, sw1 + sa_in)
    b2_q = quant_bias_int32(b2, sw2 + sa1)
    b3_q = quant_bias_int32(b3, sw3 + sa2)
    bfc_q = quant_bias_int32(bfc, swfc + sa3)

    # Requantization shift for each conv: acc has scale 2^-(sw + sa_prev),
    # next-layer activation has scale 2^-sa_next. shift = (sw + sa_prev) - sa_next.
    shift1 = (sw1 + sa_in) - sa1
    shift2 = (sw2 + sa1) - sa2
    shift3 = (sw3 + sa2) - sa3
    print(f"weight scale exps:  sw1={sw1} sw2={sw2} sw3={sw3} swfc={swfc}")
    print(f"act scale exps:     sa_in={sa_in} sa1={sa1} sa2={sa2} sa3={sa3}")
    print(f"requant shifts:     shift1={shift1} shift2={shift2} shift3={shift3}")
    if min(shift1, shift2, shift3) <= 0:
        print("WARNING: a requantization shift is <= 0; activation scales may be too tight.")

    int_model = IntegerFaceCNN(
        w1_q, b1_q, shift1,
        w2_q, b2_q, shift2,
        w3_q, b3_q, shift3,
        wfc_q, bfc_q,
    )

    # Evaluate integer model accuracy
    with torch.no_grad():
        int_pred = int_model.predict(calib_x_uint8.to(torch.float32))
    int_acc = (int_pred == calib_y).float().mean().item()
    print(f"int8 model accuracy on calibration set:  {int_acc:.4f}  (drop {float_acc-int_acc:+.4f})")

    # ----- Save -----
    out = {
        "input_scale_exp": sa_in,
        "input_zero_point": 128,
        "layers": {
            "conv1": {"weight_scale_exp": sw1, "weight_shape": list(w1_q.shape),
                       "weight": w1_q.flatten().tolist(),
                       "bias": b1_q.tolist(),
                       "requant_shift": shift1, "stride": 2},
            "conv2": {"weight_scale_exp": sw2, "weight_shape": list(w2_q.shape),
                       "weight": w2_q.flatten().tolist(),
                       "bias": b2_q.tolist(),
                       "requant_shift": shift2, "stride": 2},
            "conv3": {"weight_scale_exp": sw3, "weight_shape": list(w3_q.shape),
                       "weight": w3_q.flatten().tolist(),
                       "bias": b3_q.tolist(),
                       "requant_shift": shift3, "stride": 1},
            "fc":    {"weight_scale_exp": swfc, "weight_shape": list(wfc_q.shape),
                       "weight": wfc_q.flatten().tolist(),
                       "bias": bfc_q.tolist()},
        },
        "act_scale_exps": {"input": sa_in, "conv1": sa1, "conv2": sa2, "conv3": sa3},
        "calibration_accuracy": {"float": float_acc, "int8": int_acc},
    }
    args.out_json.parent.mkdir(parents=True, exist_ok=True)
    with open(args.out_json, "w") as f:
        json.dump(out, f, indent=2)
    print(f"saved quantized model -> {args.out_json}")

    torch.save(
        {
            "w1_q": w1_q, "b1_q": b1_q, "shift1": shift1,
            "w2_q": w2_q, "b2_q": b2_q, "shift2": shift2,
            "w3_q": w3_q, "b3_q": b3_q, "shift3": shift3,
            "wfc_q": wfc_q, "bfc_q": bfc_q,
            "sa_in": sa_in, "sa1": sa1, "sa2": sa2, "sa3": sa3,
            "sw1": sw1, "sw2": sw2, "sw3": sw3, "swfc": swfc,
        },
        args.out_pt,
    )
    print(f"saved integer reference -> {args.out_pt}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
