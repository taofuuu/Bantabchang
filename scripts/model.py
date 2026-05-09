"""Tiny CNN for 24x24 grayscale face / no-face classification.

Architecture matches /home/tofu/.claude/plans/eager-leaping-willow.md:
  Conv1: 1->8  ch, 3x3, stride 2, ReLU  -> 11x11x8
  Conv2: 8->16 ch, 3x3, stride 2, ReLU  -> 5x5x16
  Conv3: 16->16 ch, 3x3, stride 1, ReLU -> 3x3x16
  FC:    144 -> 2 logits
"""
from __future__ import annotations

import torch
import torch.nn as nn
import torch.nn.functional as F


INPUT_SIZE = 24
NUM_CLASSES = 2


class FaceCNN(nn.Module):
    def __init__(self) -> None:
        super().__init__()
        self.conv1 = nn.Conv2d(1, 8, kernel_size=3, stride=2, padding=0, bias=True)
        self.conv2 = nn.Conv2d(8, 16, kernel_size=3, stride=2, padding=0, bias=True)
        self.conv3 = nn.Conv2d(16, 16, kernel_size=3, stride=1, padding=0, bias=True)
        self.fc = nn.Linear(3 * 3 * 16, NUM_CLASSES, bias=True)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = F.relu(self.conv1(x))
        x = F.relu(self.conv2(x))
        x = F.relu(self.conv3(x))
        x = x.flatten(1)
        x = self.fc(x)
        return x

    @torch.no_grad()
    def forward_with_activations(self, x: torch.Tensor) -> dict[str, torch.Tensor]:
        """Returns intermediate activations — used by golden-vector dump."""
        a = {"input": x}
        a["conv1_pre"] = self.conv1(x)
        a["conv1"] = F.relu(a["conv1_pre"])
        a["conv2_pre"] = self.conv2(a["conv1"])
        a["conv2"] = F.relu(a["conv2_pre"])
        a["conv3_pre"] = self.conv3(a["conv2"])
        a["conv3"] = F.relu(a["conv3_pre"])
        a["flat"] = a["conv3"].flatten(1)
        a["logits"] = self.fc(a["flat"])
        return a
