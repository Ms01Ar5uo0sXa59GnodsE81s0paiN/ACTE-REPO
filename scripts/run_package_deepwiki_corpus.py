#!/usr/bin/env python3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from acte.foundry import copy_package_for_deepwiki
from acte.intake import active_target


if __name__ == "__main__":
    target = active_target()
    package_dir = copy_package_for_deepwiki(target)
    print(f"package_dir={package_dir}")
