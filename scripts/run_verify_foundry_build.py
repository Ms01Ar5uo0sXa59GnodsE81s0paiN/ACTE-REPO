#!/usr/bin/env python3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from acte.foundry import verify_foundry_build
from acte.intake import active_target


if __name__ == "__main__":
    target = active_target()
    result = verify_foundry_build(target["paths"]["foundry_dir"])
    print(f"build_passed={result['build_passed']}")
