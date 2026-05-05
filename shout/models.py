"""Curated list of Parakeet models available via parakeet-mlx / HuggingFace."""

from dataclasses import dataclass


@dataclass(frozen=True)
class ModelInfo:
    hf_id: str
    label: str
    description: str


# Sourced from huggingface.co/mlx-community (search "parakeet")
# and huggingface.co/senstella. These are MLX-native ports.
MODELS: list[ModelInfo] = [
    ModelInfo(
        hf_id="mlx-community/parakeet-tdt-0.6b-v2",
        label="parakeet-tdt-0.6b-v2  (recommended, English, ~600M)",
        description=(
            "NVIDIA Parakeet TDT 0.6B v2. English-only. Top of the OpenASR "
            "leaderboard for its size class. Best speed/quality tradeoff. "
            "Default choice."
        ),
    ),
    ModelInfo(
        hf_id="mlx-community/parakeet-tdt-0.6b-v3",
        label="parakeet-tdt-0.6b-v3  (newer, multilingual ~600M)",
        description=(
            "v3 release of Parakeet TDT 0.6B. Multilingual; quality varies "
            "by language. For English-only dictation v2 is usually preferred."
        ),
    ),
    ModelInfo(
        hf_id="mlx-community/parakeet-tdt-1.1b",
        label="parakeet-tdt-1.1b  (larger, English, ~1.1B)",
        description=(
            "Larger 1.1B TDT model. Slightly better WER on hard audio at "
            "the cost of ~2x memory and ~2x latency vs 0.6b-v2."
        ),
    ),
    ModelInfo(
        hf_id="mlx-community/parakeet-rnnt-1.1b",
        label="parakeet-rnnt-1.1b  (RNN-T 1.1B, English)",
        description=(
            "RNN-T variant at 1.1B. Generally a hair behind TDT on speed "
            "and similar on accuracy. Useful for comparison."
        ),
    ),
    ModelInfo(
        hf_id="mlx-community/parakeet-tdt_ctc-110m",
        label="parakeet-tdt_ctc-110m  (tiny, fastest, English)",
        description=(
            "Tiny 110M hybrid TDT/CTC. Extremely fast and low memory, but "
            "noticeably worse WER. Good for ultra-short utterances or "
            "low-power scenarios."
        ),
    ),
]


def by_id(hf_id: str) -> ModelInfo | None:
    for m in MODELS:
        if m.hf_id == hf_id:
            return m
    return None
