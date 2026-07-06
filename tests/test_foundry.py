import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from acte.explorer import SourceRecord, source_bundle
from acte.foundry import foundry_toml, materialize_foundry_project, resolve_source_record
from acte.intake import build_target_record


def sample_record(
    *,
    address: str = "0x0000000000000000000000000000000000001004",
    proxy: bool = False,
    implementation: str = "",
    contract_name: str = "Foo",
) -> SourceRecord:
    source_code = (
        "{{"
        '"language":"Solidity",'
        '"sources":{"contracts/Foo.sol":{"content":"// SPDX-License-Identifier: MIT\\npragma solidity ^0.8.20; contract Foo { function x() external pure returns (uint256) { return 1; } }"}},'
        '"settings":{"optimizer":{"enabled":true,"runs":999},"evmVersion":"paris","remappings":["@oz/=lib/oz/"]}'
        "}}"
    )
    return SourceRecord(
        chain="bsc",
        address=address,
        verified=True,
        contract_name=contract_name,
        compiler_version="v0.8.20+commit.a1b79de6",
        optimization_used=True,
        optimizer_runs=200,
        evm_version="",
        source_code=source_code,
        abi="[]",
        constructor_arguments="",
        proxy=proxy,
        implementation=implementation,
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
                addresses = (project / "addresses.json").read_text(encoding="utf-8")
                self.assertIn('"proxy": false', addresses)
            finally:
                os.chdir(old)

    def test_materialize_proxy_project_records_live_and_source_addresses(self):
        target = build_target_record(
            target="0x0000000000000000000000000000000000001004",
            chain="bsc",
            label="FooProxy",
            protocol="Foo",
            target_type="proxy",
            implementation_address="0x0000000000000000000000000000000000002005",
        )
        with tempfile.TemporaryDirectory() as tmp:
            old = os.getcwd()
            os.chdir(tmp)
            try:
                project = materialize_foundry_project(
                    target,
                    sample_record(address="0x0000000000000000000000000000000000002005", contract_name="FooImpl"),
                )
                addresses = (project / "addresses.json").read_text(encoding="utf-8")
                self.assertIn('"proxy": true', addresses)
                self.assertIn('"proxy_address": "0x0000000000000000000000000000000000001004"', addresses)
                self.assertIn('"implementation_address": "0x0000000000000000000000000000000000002005"', addresses)
                self.assertIn('"source_address": "0x0000000000000000000000000000000000002005"', addresses)
            finally:
                os.chdir(old)

    def test_resolve_source_record_uses_provided_implementation(self):
        target = build_target_record(
            target="0x0000000000000000000000000000000000001004",
            chain="bsc",
            label="FooProxy",
            protocol="Foo",
            target_type="proxy",
            implementation_address="0x0000000000000000000000000000000000002005",
        )
        impl = sample_record(address="0x0000000000000000000000000000000000002005")
        with patch("acte.foundry.fetch_source_record", return_value=impl) as fetch:
            record = resolve_source_record(target)
        self.assertEqual(record.address, "0x0000000000000000000000000000000000002005")
        fetch.assert_called_once_with("bsc", "0x0000000000000000000000000000000000002005")

    def test_resolve_source_record_uses_explorer_proxy_implementation(self):
        target = build_target_record(
            target="0x0000000000000000000000000000000000001004",
            chain="bsc",
            label="FooProxy",
            protocol="Foo",
            target_type="proxy",
        )
        proxy = sample_record(
            address="0x0000000000000000000000000000000000001004",
            proxy=True,
            implementation="0x0000000000000000000000000000000000002005",
        )
        impl = sample_record(address="0x0000000000000000000000000000000000002005")
        with patch("acte.foundry.fetch_source_record", side_effect=[proxy, impl]) as fetch:
            record = resolve_source_record(target)
        self.assertEqual(record.address, "0x0000000000000000000000000000000000002005")
        self.assertEqual(fetch.call_args_list[0].args, ("bsc", "0x0000000000000000000000000000000000001004"))
        self.assertEqual(fetch.call_args_list[1].args, ("bsc", "0x0000000000000000000000000000000000002005"))

    def test_resolve_source_record_uses_eip1967_when_explorer_has_no_implementation(self):
        target = build_target_record(
            target="0x0000000000000000000000000000000000001004",
            chain="bsc",
            label="FooProxy",
            protocol="Foo",
            target_type="proxy",
        )
        proxy = sample_record(address="0x0000000000000000000000000000000000001004", proxy=True)
        impl = sample_record(address="0x0000000000000000000000000000000000002005")
        with patch("acte.foundry.fetch_source_record", side_effect=[proxy, impl]), patch(
            "acte.foundry._resolve_eip1967_implementation",
            return_value="0x0000000000000000000000000000000000002005",
        ):
            record = resolve_source_record(target)
        self.assertEqual(record.address, "0x0000000000000000000000000000000000002005")

    def test_foundry_toml_infers_package_remappings(self):
        bundle = {
            "settings": {},
            "sources": {
                "@openzeppelin/contracts/utils/Address.sol": "",
                "contracts/Bridge.sol": "",
            },
        }
        toml = foundry_toml(sample_record(), bundle)
        self.assertIn('"@openzeppelin/contracts/=src/@openzeppelin/contracts/"', toml)
        self.assertIn('"contracts/=src/contracts/"', toml)


if __name__ == "__main__":
    unittest.main()
