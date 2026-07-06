import os
import unittest
from unittest.mock import patch

from acte.chains import get_chain
from acte.explorer import resolve_api_key, resolve_api_key_from_env
from acte.live_context import rpc_endpoints


class SecretParsingTests(unittest.TestCase):
    def test_api_key_accepts_json_list(self):
        self.assertEqual(resolve_api_key('["key-a", "key-b"]'), "key-a")

    def test_api_key_accepts_json_dict_list(self):
        self.assertEqual(resolve_api_key('{"api_keys": [{"key": "key-a"}, {"key": "key-b"}]}'), "key-a")

    def test_bsc_api_key_can_fallback_to_etherscan_secret(self):
        chain = get_chain("bsc")
        with patch.dict(os.environ, {"BSCSCAN_API_KEY": "", "ETHERSCAN_API_KEY": '["eth-key-a"]'}, clear=False):
            self.assertEqual(resolve_api_key_from_env(chain), "eth-key-a")

    def test_rpc_endpoints_accept_json_list(self):
        with patch.dict(os.environ, {"BSC_RPC_URL": '["https://rpc-a.example", "https://rpc-b.example"]'}, clear=False):
            endpoints = rpc_endpoints("bsc")
        self.assertEqual(endpoints[:2], ("https://rpc-a.example", "https://rpc-b.example"))
        self.assertIn("https://bsc-dataseed.binance.org", endpoints)

    def test_rpc_endpoints_accept_json_dict_list(self):
        with patch.dict(os.environ, {"BSC_RPC_URL": '{"rpc_urls": [{"url": "https://rpc-a.example"}]}'}, clear=False):
            endpoints = rpc_endpoints("bsc")
        self.assertEqual(endpoints[0], "https://rpc-a.example")


if __name__ == "__main__":
    unittest.main()
