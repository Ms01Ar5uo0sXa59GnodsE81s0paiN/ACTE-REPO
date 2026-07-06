import os
import tempfile
import unittest
from pathlib import Path

from acte.explorer import SourceRecord, source_bundle
from acte.foundry import materialize_foundry_project
from acte.intake import build_target_record


def sample_record() -> SourceRecord:
    source_code = (
        "{{"
        '"language":"Solidity",'
        '"sources":{"contracts/Foo.sol":{"content":"// SPDX-License-Identifier: MIT\\npragma solidity ^0.8.20; contract Foo { function x() external pure returns (uint256) { return 1; } }"}},'
        '"settings":{"optimizer":{"enabled":true,"runs":999},"evmVersion":"paris","remappings":["@oz/=lib/oz/"]}'
        "}}"
    )
    return SourceRecord(
        chain="bsc",
        address="0x0000000000000000000000000000000000001004",
        verified=True,
        contract_name="Foo",
        compiler_version="v0.8.20+commit.a1b79de6",
        optimization_used=True,
        optimizer_runs=200,
        evm_version="",
        source_code=source_code,
        abi="[]",
        constructor_arguments="",
        proxy=False,
        implementation="",
        raw={},
    )


class FoundryTests(unittest.TestCase):
    def test_source_bundle_handles_double_braced_standard_json(self):
        bundle = source_bundle(sample_record())
        self.assertEqual(bundle["format"], "standard-json")
        self.assertIn("contracts/Foo.sol", bundle["sources"])
        self.assertEqual(bundle["settings"]["optimizer"]["runs"], 999)

    def test_materialize_foundry_project(self):
        target = build_target_record(
            target="0x0000000000000000000000000000000000001004",
            chain="bsc",
            label="Foo",
            protocol="Foo",
            target_type="contract",
        )
        with tempfile.TemporaryDirectory() as tmp:
            old = os.getcwd()
            os.chdir(tmp)
            try:
                project = materialize_foundry_project(target, sample_record())
                self.assertTrue((project / "foundry.toml").exists())
                self.assertTrue((project / "src/contracts/Foo.sol").exists())
                toml = (project / "foundry.toml").read_text(encoding="utf-8")
                self.assertIn('solc_version = "0.8.20"', toml)
                self.assertIn("optimizer_runs = 999", toml)
                self.assertTrue((project / "source-artifacts/source_bundle.json").exists())
            finally:
                os.chdir(old)


if __name__ == "__main__":
    unittest.main()

