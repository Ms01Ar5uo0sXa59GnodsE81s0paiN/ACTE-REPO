import unittest

from acte.live_context import (
    candidate_args_for_inputs,
    decode_event_sample,
    encode_static_arg,
    infer_mapping_key_hints,
)


class LiveContextScannerTests(unittest.TestCase):
    def test_decode_event_sample_extracts_static_event_fields(self):
        event = {
            "name": "RoleGranted",
            "inputs": [
                {"name": "role", "type": "bytes32", "indexed": True},
                {"name": "account", "type": "address", "indexed": True},
                {"name": "sender", "type": "address", "indexed": True},
            ],
        }
        log = {
            "blockNumber": "0x10",
            "logIndex": "0x2",
            "transactionHash": "0xabc",
            "topics": [
                "0x" + ("1" * 64),
                "0x" + ("2" * 64),
                "0x" + ("0" * 24) + "0000000000000000000000000000000000001004",
                "0x" + ("0" * 24) + "0000000000000000000000000000000000002005",
            ],
            "data": "0x",
        }

        sample = decode_event_sample(log, event)

        self.assertEqual(sample["block_number"], 16)
        self.assertEqual(sample["decoded"]["role"], "0x" + ("2" * 64))
        self.assertEqual(sample["decoded"]["account"], "0x0000000000000000000000000000000000001004")
        self.assertEqual(sample["decoded"]["sender"], "0x0000000000000000000000000000000000002005")

    def test_mapping_key_hints_uses_event_decoded_keys(self):
        event_activity = {
            "FlapSaltLocked": {
                "sample_logs": [
                    {
                        "decoded": {
                            "locker": "0x0000000000000000000000000000000000001004",
                            "salt": "0x" + ("3" * 64),
                        },
                        "raw_words": {"salt": "0x" + ("3" * 64)},
                    }
                ]
            }
        }

        hints = infer_mapping_key_hints(event_activity)

        self.assertIn("locker", hints)
        self.assertIn("salt", hints)
        self.assertEqual(hints["locker"]["source_events"], ["FlapSaltLocked"])

    def test_static_arg_encoding_and_candidate_generation(self):
        self.assertEqual(
            encode_static_arg("0x0000000000000000000000000000000000001004", "address"),
            "0" * 24 + "0000000000000000000000000000000000001004",
        )
        candidates = candidate_args_for_inputs(
            [{"type": "bytes32"}, {"type": "address"}],
            {
                "bytes32": ["0x" + ("1" * 64)],
                "address": ["0x0000000000000000000000000000000000001004"],
            },
        )
        self.assertEqual(candidates, [["0x" + ("1" * 64), "0x0000000000000000000000000000000000001004"]])


if __name__ == "__main__":
    unittest.main()
