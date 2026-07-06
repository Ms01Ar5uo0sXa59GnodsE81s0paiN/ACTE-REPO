import unittest

from acte.chains import get_chain
from acte.intake import build_target_record, parse_target


class IntakeTests(unittest.TestCase):
    def test_parse_raw_bsc_address(self):
        chain, address = parse_target("0x0000000000000000000000000000000000001004", "bsc")
        self.assertEqual(chain, "bsc")
        self.assertEqual(address, "0x0000000000000000000000000000000000001004")

    def test_parse_raw_eth_alias(self):
        chain, address = parse_target("0x0000000000000000000000000000000000001004", "eth")
        self.assertEqual(chain, "ethereum")
        self.assertEqual(address, "0x0000000000000000000000000000000000001004")

    def test_parse_explorer_url(self):
        chain, address = parse_target(
            "https://bscscan.com/address/0x0000000000000000000000000000000000001004",
            None,
        )
        self.assertEqual(chain, "bsc")
        self.assertEqual(address, "0x0000000000000000000000000000000000001004")

    def test_target_record_paths(self):
        record = build_target_record(
            target="0x0000000000000000000000000000000000001004",
            chain="bsc",
            label="TokenHub",
            protocol="BSC",
            target_type="contract",
        )
        self.assertEqual(record["chain_id"], 56)
        self.assertEqual(record["paths"]["foundry_dir"], "foundry_targets/bsc/0x0000000000000000000000000000000000001004")
        self.assertEqual(record["workflow"]["1_materialize_verified_foundry"], "pending")
        self.assertEqual(record["deployment_kind"], "implementation_or_direct")
        self.assertEqual(record["source_address"], "0x0000000000000000000000000000000000001004")

    def test_proxy_and_implementation_inputs_keep_proxy_as_live_address(self):
        record = build_target_record(
            target="0x0000000000000000000000000000000000001004",
            chain="bsc",
            label="ProxyTarget",
            protocol="ProxyTarget",
            target_type="proxy",
            implementation_address="0x0000000000000000000000000000000000002005",
        )
        self.assertEqual(record["address"], "0x0000000000000000000000000000000000001004")
        self.assertEqual(record["proxy_address"], "0x0000000000000000000000000000000000001004")
        self.assertEqual(record["implementation_address"], "0x0000000000000000000000000000000000002005")
        self.assertEqual(record["source_address"], "0x0000000000000000000000000000000000002005")
        self.assertEqual(record["deployment_kind"], "proxy")

    def test_bsc_uses_etherscan_v2_with_bsc_fallback_secret(self):
        chain = get_chain("bsc")
        self.assertEqual(chain.explorer_api_url, "https://api.etherscan.io/v2/api")
        self.assertEqual(chain.api_key_env, "BSCSCAN_API_KEY")
        self.assertEqual(chain.etherscan_v2_chain_id, 56)
        self.assertEqual(chain.api_key_fallback_envs, ("ETHERSCAN_API_KEY",))


if __name__ == "__main__":
    unittest.main()
