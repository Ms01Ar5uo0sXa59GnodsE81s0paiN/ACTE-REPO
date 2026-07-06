import unittest

from acte.chains import get_chain
from acte.intake import build_target_record, parse_target


class IntakeTests(unittest.TestCase):
    def test_parse_raw_bsc_address(self):
        chain, address = parse_target("0x0000000000000000000000000000000000001004", "bsc")
        self.assertEqual(chain, "bsc")
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

    def test_bsc_uses_native_bscscan_api_key(self):
        chain = get_chain("bsc")
        self.assertEqual(chain.explorer_api_url, "https://api.bscscan.com/api")
        self.assertEqual(chain.api_key_env, "BSCSCAN_API_KEY")
        self.assertIsNone(chain.etherscan_v2_chain_id)


if __name__ == "__main__":
    unittest.main()
