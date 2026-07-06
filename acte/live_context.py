from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import urllib.request
from pathlib import Path
from typing import Any, Dict, Optional

from .chains import get_chain
from .intake import active_target
from .io import write_json
from .secrets import secret_values

EIP1967_IMPLEMENTATION_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
EIP1967_ADMIN_SLOT = "0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103"
EIP1967_BEACON_SLOT = "0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50"


class RpcError(RuntimeError):
    pass


def now_utc() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def hex_to_int(value: str) -> int:
    return int(value, 16)


def word_to_address(word: str) -> str:
    if not isinstance(word, str) or not word.startswith("0x"):
        return ""
    value = int(word, 16)
    if value == 0:
        return ""
    return "0x" + word[-40:].lower()


class RpcClient:
    def __init__(self, endpoints: tuple[str, ...], timeout: int = 20):
        self.endpoints = endpoints
        self.timeout = timeout
        self.last_endpoint = ""

    def request(self, method: str, params: list[Any]) -> Any:
        payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode("utf-8")
        last_error: Optional[Exception] = None
        for endpoint in self.endpoints:
            request = urllib.request.Request(endpoint, data=payload, headers={"Content-Type": "application/json"})
            try:
                with urllib.request.urlopen(request, timeout=self.timeout) as response:
                    data = json.loads(response.read().decode("utf-8"))
                if "error" in data:
                    raise RpcError(str(data["error"]))
                self.last_endpoint = endpoint
                return data.get("result")
            except Exception as exc:  # noqa: BLE001 - try the next configured endpoint.
                last_error = exc
        raise RpcError(f"all RPC endpoints failed: {last_error}")

    def block_number(self) -> int:
        return hex_to_int(self.request("eth_blockNumber", []))

    def get_code(self, address: str) -> str:
        return self.request("eth_getCode", [address, "latest"]) or "0x"

    def get_balance(self, address: str) -> int:
        return hex_to_int(self.request("eth_getBalance", [address, "latest"]) or "0x0")

    def get_storage_at(self, address: str, slot: str) -> str:
        return self.request("eth_getStorageAt", [address, slot, "latest"]) or "0x"

    def call(self, to: str, data: str) -> str:
        return self.request("eth_call", [{"to": to, "data": data}, "latest"]) or "0x"


def rpc_endpoints(chain: str) -> tuple[str, ...]:
    config = get_chain(chain)
    configured = secret_values(
        os.environ.get(config.rpc_env, ""),
        scalar_fields=("url", "rpc_url", "endpoint", "value"),
        list_fields=("urls", "rpc_urls", "endpoints", "items"),
    )
    if configured:
        return configured + config.public_rpc
    return config.public_rpc


def try_call(client: RpcClient, address: str, selector: str) -> str:
    try:
        return client.call(address, selector)
    except Exception:
        return ""


def decode_uint(word: str) -> Optional[int]:
    if isinstance(word, str) and word.startswith("0x") and len(word) >= 66:
        return int(word[:66], 16)
    return None


def decode_address_word(word: str) -> str:
    if isinstance(word, str) and len(word) >= 66:
        return word_to_address(word[:66])
    return ""


def collect_context(target: Dict[str, Any]) -> Dict[str, Any]:
    config = get_chain(target["chain"])
    client = RpcClient(rpc_endpoints(config.key))
    address = target["address"]
    latest_block = client.block_number()
    code = client.get_code(address)
    native_balance = client.get_balance(address)
    slots = {
        "eip1967_implementation": client.get_storage_at(address, EIP1967_IMPLEMENTATION_SLOT),
        "eip1967_admin": client.get_storage_at(address, EIP1967_ADMIN_SLOT),
        "eip1967_beacon": client.get_storage_at(address, EIP1967_BEACON_SLOT),
    }
    views = {
        "owner": decode_address_word(try_call(client, address, "0x8da5cb5b")),
        "admin": decode_address_word(try_call(client, address, "0xf851a440")),
        "totalSupply": decode_uint(try_call(client, address, "0x18160ddd")),
        "decimals": decode_uint(try_call(client, address, "0x313ce567")),
        "token0": decode_address_word(try_call(client, address, "0x0dfe1681")),
        "token1": decode_address_word(try_call(client, address, "0xd21220a7")),
        "factory": decode_address_word(try_call(client, address, "0xc45a0155")),
    }
    return {
        "schema_version": "acte-live-context-v1",
        "captured_at": now_utc(),
        "chain": config.key,
        "chain_id": config.chain_id,
        "rpc_endpoint_used": client.last_endpoint,
        "latest_block": latest_block,
        "target": {
            "address": address,
            "label": target["label"],
            "explorer_url": target["explorer_url"],
            "code_size_bytes": max((len(code) - 2) // 2, 0),
            "native_balance_wei": native_balance,
            "native_symbol": config.native_symbol,
        },
        "proxy_slots": {
            "implementation_raw": slots["eip1967_implementation"],
            "implementation": word_to_address(slots["eip1967_implementation"]),
            "admin_raw": slots["eip1967_admin"],
            "admin": word_to_address(slots["eip1967_admin"]),
            "beacon_raw": slots["eip1967_beacon"],
            "beacon": word_to_address(slots["eip1967_beacon"]),
        },
        "common_views": views,
        "audit_notes": [
            "Private mappings and structs are not globally enumerable without known keys.",
            "DeepWiki candidates must be checked against this block-specific live state before proof.",
        ],
    }


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Collect live state context for the active ACTE target.")
    parser.parse_args(argv)
    target = active_target()
    context = collect_context(target)
    write_json(target["paths"]["live_context"], context)
    write_json("setup/live_context.json", context)
    print(f"live_context: {target['paths']['live_context']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
