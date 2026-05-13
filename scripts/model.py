"""tiny CNN for 24x24 face detection with bounding-box regression.
outputs [conf_logit, x0, y0, w, h] in patch pixel coords [0, 24]."""
from __future__ import annotations

import torch
import torch.nn as nn
import torch.nn.functional as F


INPUT_SIZE = 24
FC_OUT     = 5          # 1 confidence + 4 bbox values
BBOX_DIMS  = 4          # cx, cy, w, h


class FaceBBoxCNN(nn.Module):
    def __init__(self) -> None:
        super().__init__()
        self.conv1 = nn.Conv2d(1, 8, kernel_size=3, stride=2, padding=0, bias=True)
        self.conv2 = nn.Conv2d(8, 16, kernel_size=3, stride=2, padding=0, bias=True)
        self.conv3 = nn.Conv2d(16, 16, kernel_size=3, stride=1, padding=0, bias=True)
        self.fc    = nn.Linear(3 * 3 * 16, FC_OUT, bias=True)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = F.relu(self.conv1(x))
        x = F.relu(self.conv2(x))
        x = F.relu(self.conv3(x))
        x = x.flatten(1)
        return self.fc(x)            # (N, 5)

    @torch.no_grad()
    def forward_with_activations(self, x: torch.Tensor) -> dict[str, torch.Tensor]:
        a = {"input": x}
        a["conv1_pre"] = self.conv1(x)
        a["conv1"]     = F.relu(a["conv1_pre"])
        a["conv2_pre"] = self.conv2(a["conv1"])
        a["conv2"]     = F.relu(a["conv2_pre"])
        a["conv3_pre"] = self.conv3(a["conv2"])
        a["conv3"]     = F.relu(a["conv3_pre"])
        a["flat"]      = a["conv3"].flatten(1)
        a["fc_out"]    = self.fc(a["flat"])
        return a


def split_outputs(fc_out: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
    """split the 5-vector into (conf_logit, bbox)."""
    return fc_out[:, 0], fc_out[:, 1:5]
