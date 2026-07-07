from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import urllib.request
from collections import Counter
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple

from .chains import get_chain
from .intake import active_target
from .io import write_json
from .secrets import secret_values

EIP1967_IMPLEMENTATION_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
EIP1967_ADMIN_SLOT = "0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103"
EIP1967_BEACON_SLOT = "0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50"
TRANSFER_EVENT_SIG = "Transfer(address,address,uint256)"

COMMON_TOKENS: Dict[str, List[Dict[str, Any]]] = {
    "bsc": [
        {"symbol": "BUSD", "address": "0xe9e7cea3dedca5984780bafc599bd69add087d56", "decimals": 18},
        {"symbol": "USDT", "address": "0x55d398326f99059ff775485246999027b3197955", "decimals": 18},
        {"symbol": "USDC", "address": "0x8ac76a51cc950d9822d68b83fe1ad97b32cd580d", "decimals": 18},
        {"symbol": "WBNB", "address": "0xbb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c", "decimals": 18},
    ],
    "ethereum": [
        {"symbol": "USDC", "address": "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48", "decimals": 6},
        {"symbol": "USDT", "address": "0xdac17f958d2ee523a2206206994597c13d831ec7", "decimals": 6},
        {"symbol": "DAI", "address": "0x6b175474e89094c44da98b954eedeac495271d0f", "decimals": 18},
        {"symbol": "WETH", "address": "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2", "decimals": 18},
    ],
    "arbitrum": [
        {"symbol": "USDC", "address": "0xaf88d065e77c8cc2239327c5edb3a432268e5831", "decimals": 6},
        {"symbol": "USDT", "address": "0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9", "decimals": 6},
        {"symbol": "WETH", "address": "0x82af49447d8a07e3bd95bd0d56f35241523fbab1", "decimals": 18},
    ],
    "base": [
        {"symbol": "USDC", "address": "0x833589fcD6eDb6E08f4c7C32D4f71b54bdA02913".lower(), "decimals": 6},
        {"symbol": "WETH", "address": "0x4200000000000000000000000000000000000006", "decimals": 18},
    ],
    "optimism": [
        {"symbol": "USDC", "address": "0x7f5c764cbc14f9669b88837ca1490cca17c31607", "decimals": 6},
        {"symbol": "USDT", "address": "0x94b008aa00579c1307b0ef2c499ad98a8ce58e58", "decimals": 6},
        {"symbol": "WETH", "address": "0x4200000000000000000000000000000000000006", "decimals": 18},
    ],
}

ROLE_OR_ADMIN_WORDS = (
    "admin",
    "role",
    "owner",
    "guardian",
    "moderator",
    "tax",
    "manager",
    "setter",
    "halt",
    "pause",
    "unpause",
    "set",
    "update",
    "register",
    "initialize",
    "recover",
    "burn",
    "block",
    "exclude",
    "change",
    "grant",
    "revoke",
    "renounce",
)

VALUE_FLOW_WORDS = (
    "buy",
    "sell",
    "swap",
    "redeem",
    "claim",
    "withdraw",
    "deposit",
    "mint",
    "burn",
    "recover",
    "collect",
    "lock",
    "newtoken",
    "launch",
    "migrate",
    "liquid",
    "fee",
)

EXTERNAL_DEPENDENCY_VIEW_NAMES = (
    "owner",
    "admin",
    "asset",
    "token",
    "quote",
    "router",
    "factory",
    "oracle",
    "registry",
    "controller",
    "strategy",
    "vault",
    "wallet",
    "receiver",
    "implementation",
)


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

    def get_logs(self, filter_params: Dict[str, Any]) -> list[Dict[str, Any]]:
        result = self.request("eth_getLogs", [filter_params]) or []
        return result if isinstance(result, list) else []

    def selector(self, signature: str) -> str:
        digest = self.request("web3_sha3", ["0x" + signature.encode("utf-8").hex()])
        if not isinstance(digest, str) or len(digest) < 10:
            raise RpcError(f"bad selector digest for {signature}")
        return digest[:10]


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


def try_selector(client: RpcClient, signature: str) -> str:
    try:
        return client.selector(signature)
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


def decode_bool(word: str) -> Optional[bool]:
    if isinstance(word, str) and word.startswith("0x") and len(word) >= 66:
        return bool(int(word[:66], 16))
    return None


def decode_string_or_bytes32(raw_hex: str) -> str:
    if not isinstance(raw_hex, str) or raw_hex in ("", "0x") or not raw_hex.startswith("0x"):
        return ""
    data = raw_hex[2:]
    try:
        if len(data) >= 128:
            offset = int(data[:64], 16)
            length_start = offset * 2
            length = int(data[length_start : length_start + 64], 16)
            value_start = length_start + 64
            value_end = value_start + length * 2
            return bytes.fromhex(data[value_start:value_end]).decode("utf-8", errors="ignore")
        return bytes.fromhex(data).rstrip(b"\x00").decode("utf-8", errors="ignore")
    except Exception:
        return ""


def decode_single_output(raw_hex: str, abi_type: str) -> Any:
    if raw_hex in ("", "0x") or not isinstance(raw_hex, str):
        return None
    if abi_type == "address":
        return decode_address_word(raw_hex)
    if abi_type == "bool":
        return decode_bool(raw_hex)
    if abi_type.startswith("uint") or abi_type.startswith("int"):
        return decode_uint(raw_hex)
    if abi_type == "string":
        return decode_string_or_bytes32(raw_hex)
    if abi_type == "bytes32":
        return raw_hex[:66]
    return raw_hex


def base_abi_type(abi_type: str) -> str:
    if abi_type.startswith("uint"):
        return "uint"
    if abi_type.startswith("int"):
        return "int"
    if abi_type == "bytes32":
        return "bytes32"
    if abi_type.startswith("bytes") and abi_type != "bytes":
        return "bytesn"
    return abi_type


def is_static_supported_type(abi_type: str) -> bool:
    return base_abi_type(abi_type) in {"address", "bool", "uint", "int", "bytes32", "bytesn"}


def decode_topic_word(topic: str, abi_type: str) -> Any:
    base_type = base_abi_type(abi_type)
    if base_type == "address":
        return word_to_address(topic)
    if base_type == "bool":
        return bool(int(topic, 16))
    if base_type == "uint":
        return int(topic, 16)
    if base_type == "int":
        value = int(topic, 16)
        return value - 2**256 if value >= 2**255 else value
    if base_type in ("bytes32", "bytesn"):
        return topic[:66]
    return topic


def decode_data_words(data_hex: str) -> List[str]:
    if not isinstance(data_hex, str) or not data_hex.startswith("0x"):
        return []
    data = data_hex[2:]
    return ["0x" + data[i : i + 64] for i in range(0, len(data), 64) if len(data[i : i + 64]) == 64]


def decode_event_sample(log: Dict[str, Any], event: Dict[str, Any]) -> Dict[str, Any]:
    inputs = [inp for inp in event.get("inputs", []) if isinstance(inp, dict)]
    topics = log.get("topics") if isinstance(log.get("topics"), list) else []
    data_words = decode_data_words(str(log.get("data", "0x")))
    indexed_pos = 1
    data_pos = 0
    decoded: Dict[str, Any] = {}
    raw_words: Dict[str, str] = {}
    for index, inp in enumerate(inputs):
        name = str(inp.get("name") or f"arg{index}")
        abi_type = str(inp.get("type", "bytes32"))
        if inp.get("indexed"):
            raw = str(topics[indexed_pos]) if indexed_pos < len(topics) else ""
            indexed_pos += 1
        else:
            raw = data_words[data_pos] if data_pos < len(data_words) else ""
            data_pos += 1
        if not raw:
            continue
        raw_words[name] = raw
        decoded[name] = decode_topic_word(raw, abi_type) if is_static_supported_type(abi_type) else raw
    return {
        "block_number": int(str(log.get("blockNumber", "0x0")), 16) if isinstance(log.get("blockNumber"), str) else None,
        "transaction_hash": log.get("transactionHash"),
        "log_index": int(str(log.get("logIndex", "0x0")), 16) if isinstance(log.get("logIndex"), str) else None,
        "decoded": decoded,
        "raw_words": raw_words,
    }


def to_uint_word(value: int) -> str:
    return hex(value % 2**256)[2:].rjust(64, "0")


def to_int_word(value: int) -> str:
    return to_uint_word(value)


def encode_static_arg(value: Any, abi_type: str) -> Optional[str]:
    base_type = base_abi_type(abi_type)
    try:
        if base_type == "address" and isinstance(value, str) and value.startswith("0x") and len(value) == 42:
            return ("0" * 24) + value[2:].lower()
        if base_type == "bool" and isinstance(value, bool):
            return to_uint_word(1 if value else 0)
        if base_type == "uint" and isinstance(value, int) and value >= 0:
            return to_uint_word(value)
        if base_type == "int" and isinstance(value, int):
            return to_int_word(value)
        if base_type in ("bytes32", "bytesn") and isinstance(value, str) and value.startswith("0x"):
            raw = value[2:]
            if len(raw) <= 64:
                return raw.ljust(64, "0")
    except Exception:
        return None
    return None


def encode_function_call_data(client: RpcClient, fn: Dict[str, Any], args: List[Any]) -> Optional[str]:
    inputs = [inp for inp in fn.get("inputs", []) if isinstance(inp, dict)]
    if len(inputs) != len(args):
        return None
    encoded: List[str] = []
    for inp, arg in zip(inputs, args):
        word = encode_static_arg(arg, str(inp.get("type", "")))
        if word is None:
            return None
        encoded.append(word)
    selector = try_selector(client, abi_function_signature(fn))
    if not selector:
        return None
    return selector + "".join(encoded)


def decode_multi_static_outputs(raw_hex: str, outputs: List[Dict[str, Any]]) -> Any:
    if raw_hex in ("", "0x") or not raw_hex.startswith("0x"):
        return None
    if any(not is_static_supported_type(str(out.get("type", ""))) for out in outputs):
        return raw_hex[:514]
    words = decode_data_words(raw_hex)
    if len(words) < len(outputs):
        return raw_hex[:514]
    decoded: Dict[str, Any] = {}
    for index, out in enumerate(outputs):
        name = str(out.get("name") or f"out{index}")
        decoded[name] = decode_topic_word(words[index], str(out.get("type", "bytes32")))
    return decoded if len(outputs) != 1 else next(iter(decoded.values()))


def normalize_name(value: str) -> str:
    return "".join(ch for ch in value.lower() if ch.isalnum())


def abi_function_signature(fn: Dict[str, Any]) -> str:
    inputs = ",".join(str(inp.get("type", "")) for inp in fn.get("inputs", []))
    return f"{fn.get('name')}({inputs})"


def abi_event_signature(event: Dict[str, Any]) -> str:
    inputs = ",".join(str(inp.get("type", "")) for inp in event.get("inputs", []))
    return f"{event.get('name')}({inputs})"


def read_json_if_exists(path: str | Path) -> Any:
    candidate = Path(path)
    if not candidate.exists():
        return None
    try:
        return json.loads(candidate.read_text(encoding="utf-8"))
    except Exception:
        return None


def target_foundry_dir(target: Dict[str, Any]) -> Path:
    return Path(str(target.get("paths", {}).get("foundry_dir", "")))


def load_target_abi(target: Dict[str, Any]) -> list[Dict[str, Any]]:
    foundry_dir = target_foundry_dir(target)
    candidates = [
        foundry_dir / "source-artifacts" / "abi.json",
        Path(str(target.get("paths", {}).get("target_dir", ""))) / "source-artifacts" / "abi.json",
    ]
    for candidate in candidates:
        data = read_json_if_exists(candidate)
        if isinstance(data, list):
            return [item for item in data if isinstance(item, dict)]
    return []


def load_source_identity(target: Dict[str, Any]) -> Dict[str, Any]:
    foundry_dir = target_foundry_dir(target)
    source_response = read_json_if_exists(foundry_dir / "source-artifacts" / "source_response.json")
    build_verification = read_json_if_exists(foundry_dir / "source-artifacts" / "build_verification.json")
    source_bundle = read_json_if_exists(foundry_dir / "source-artifacts" / "source_bundle.json")
    identity: Dict[str, Any] = {
        "contract_name": target.get("label") or "Contract",
        "compiler_version": "",
        "source_files": [],
        "verified": False,
        "source_address": target.get("source_address") or target_live_address(target),
    }
    if isinstance(source_response, dict):
        row = source_response.get("raw") if isinstance(source_response.get("raw"), dict) else source_response
        identity["contract_name"] = row.get("ContractName") or source_response.get("contract_name") or identity["contract_name"]
        identity["compiler_version"] = row.get("CompilerVersion") or source_response.get("compiler_version") or ""
        identity["verified"] = bool(row.get("SourceCode") or source_response.get("verified"))
    if isinstance(source_bundle, dict):
        sources = source_bundle.get("sources")
        if isinstance(sources, dict):
            identity["source_files"] = sorted(str(name) for name in sources.keys())
    if isinstance(build_verification, dict):
        identity["build"] = build_verification
    return identity


def function_inventory(abi: list[Dict[str, Any]]) -> Dict[str, Any]:
    functions = [item for item in abi if item.get("type") == "function" and item.get("name")]
    events = [item for item in abi if item.get("type") == "event" and item.get("name")]

    def function_row(fn: Dict[str, Any]) -> Dict[str, Any]:
        name = str(fn.get("name"))
        normalized = normalize_name(name)
        mutability = str(fn.get("stateMutability") or "")
        return {
            "name": name,
            "signature": abi_function_signature(fn),
            "state_mutability": mutability,
            "payable": mutability == "payable",
            "input_count": len(fn.get("inputs", [])),
            "output_count": len(fn.get("outputs", [])),
        }

    value_movement = [
        function_row(fn)
        for fn in functions
        if any(word in normalize_name(str(fn.get("name"))) for word in VALUE_FLOW_WORDS)
        or str(fn.get("stateMutability")) == "payable"
    ]
    privileged = [
        function_row(fn)
        for fn in functions
        if any(word in normalize_name(str(fn.get("name"))) for word in ROLE_OR_ADMIN_WORDS)
    ]
    write_functions = [
        function_row(fn)
        for fn in functions
        if str(fn.get("stateMutability")) not in ("view", "pure")
    ]
    return {
        "function_count": len(functions),
        "event_count": len(events),
        "write_function_count": len(write_functions),
        "payable_functions": [function_row(fn) for fn in functions if str(fn.get("stateMutability")) == "payable"],
        "value_movement_functions": value_movement[:80],
        "privileged_or_role_functions": privileged[:80],
        "write_functions": write_functions[:120],
        "events": [abi_event_signature(event) for event in events[:120]],
    }


def collect_zero_arg_views(client: RpcClient, address: str, abi: list[Dict[str, Any]], max_calls: int = 40) -> Tuple[Dict[str, Any], Dict[str, str]]:
    views: Dict[str, Any] = {}
    errors: Dict[str, str] = {}
    functions = [
        fn
        for fn in abi
        if fn.get("type") == "function"
        and fn.get("name")
        and fn.get("stateMutability") in ("view", "pure")
        and not fn.get("inputs")
    ]
    priority_words = ("role", "admin", "guardian", "tax", "fee", "salt", "vault", "portal", "router", "nonce", "version")
    functions.sort(key=lambda fn: (not any(word in str(fn.get("name", "")).lower() for word in priority_words), str(fn.get("name", "")).lower()))
    for fn in functions[:max_calls]:
        name = str(fn.get("name"))
        selector = try_selector(client, abi_function_signature(fn))
        if not selector:
            errors[name] = "selector unavailable"
            continue
        raw = try_call(client, address, selector)
        if not raw:
            errors[name] = "eth_call failed/reverted"
            continue
        outputs = fn.get("outputs", [])
        if len(outputs) == 1:
            views[name] = decode_single_output(raw, str(outputs[0].get("type", "bytes32")))
        else:
            views[name] = raw
    return views, errors


def pad_address_topic(address: str) -> str:
    return "0x" + ("0" * 24) + address[2:].lower()


def fetch_logs(client: RpcClient, base_filter: Dict[str, Any], from_block: int, to_block: int, max_logs: int = 20) -> list[Dict[str, Any]]:
    query = dict(base_filter)
    query["fromBlock"] = hex(max(0, from_block))
    query["toBlock"] = hex(max(0, to_block))
    try:
        return client.get_logs(query)[:max_logs]
    except Exception:
        return []


def discover_transfer_tokens(client: RpcClient, address: str, latest_block: int, window_blocks: int = 10_000) -> list[str]:
    transfer_topic = try_selector(client, TRANSFER_EVENT_SIG)
    if not transfer_topic:
        return []
    start = max(0, latest_block - window_blocks)
    to_topic = pad_address_topic(address)
    from_topic = pad_address_topic(address)
    logs = fetch_logs(client, {"topics": [transfer_topic, None, to_topic]}, start, latest_block)
    logs += fetch_logs(client, {"topics": [transfer_topic, from_topic]}, start, latest_block)
    counter: Counter[str] = Counter()
    for log in logs:
        token = log.get("address")
        if isinstance(token, str) and token.startswith("0x") and len(token) == 42:
            counter[token.lower()] += 1
    return [token for token, _ in counter.most_common(12)]


def try_token_call(client: RpcClient, token: str, signature: str, out_type: str) -> Any:
    selector = try_selector(client, signature)
    if not selector:
        return None
    raw = try_call(client, token, selector)
    if raw in ("", "0x"):
        return None
    return decode_string_or_bytes32(raw) if out_type == "string" else decode_single_output(raw, out_type)


def erc20_balances(client: RpcClient, chain: str, address: str, latest_block: int, max_tokens: int = 20) -> list[Dict[str, Any]]:
    candidates = [str(token["address"]).lower() for token in COMMON_TOKENS.get(chain, [])]
    candidates.extend(discover_transfer_tokens(client, address, latest_block))
    seen = set()
    balances: list[Dict[str, Any]] = []
    selector = try_selector(client, "balanceOf(address)")
    if not selector:
        return []
    for token in candidates:
        if token in seen or not token.startswith("0x") or len(token) != 42:
            continue
        seen.add(token)
        data = selector + ("0" * 24) + address[2:]
        raw_balance = decode_uint(try_call(client, token, data))
        if raw_balance is None or raw_balance == 0:
            continue
        decimals = try_token_call(client, token, "decimals()", "uint8")
        symbol = try_token_call(client, token, "symbol()", "string")
        name = try_token_call(client, token, "name()", "string")
        if not isinstance(decimals, int):
            decimals = next((int(t["decimals"]) for t in COMMON_TOKENS.get(chain, []) if str(t["address"]).lower() == token), 18)
        try:
            human = format(Decimal(raw_balance) / (Decimal(10) ** Decimal(decimals)), "f")
        except (InvalidOperation, ZeroDivisionError):
            human = str(raw_balance)
        balances.append(
            {
                "token": token,
                "symbol": symbol or next((t["symbol"] for t in COMMON_TOKENS.get(chain, []) if str(t["address"]).lower() == token), "unknown"),
                "name": name or "unknown",
                "decimals": decimals,
                "raw_balance": str(raw_balance),
                "human_balance": human,
                "usd_value": "unknown",
            }
        )
        if len(balances) >= max_tokens:
            break
    balances.sort(key=lambda item: int(item["raw_balance"]), reverse=True)
    return balances


def collect_event_activity(client: RpcClient, address: str, abi: list[Dict[str, Any]], latest_block: int, window_blocks: int = 10_000) -> Dict[str, Any]:
    interesting_words = ("buy", "sell", "swap", "claim", "token", "launch", "lock", "recover", "fee", "role", "halt", "grant", "revoke")
    events = [
        event
        for event in abi
        if event.get("type") == "event"
        and event.get("name")
        and any(word in str(event.get("name")).lower() for word in interesting_words)
    ][:12]
    out: Dict[str, Any] = {}
    start = max(0, latest_block - window_blocks)
    for event in events:
        signature = abi_event_signature(event)
        topic0 = try_selector(client, signature)
        if not topic0:
            continue
        logs = fetch_logs(client, {"address": address, "topics": [topic0]}, start, latest_block, max_logs=5)
        out[str(event.get("name"))] = {
            "signature": signature,
            "sample_window_blocks": window_blocks,
            "sample_count": len(logs),
            "sample_logs": [decode_event_sample(log, event) for log in logs[:3]],
        }
    return out


def infer_mapping_key_hints(event_activity: Dict[str, Any]) -> Dict[str, Any]:
    hints: Dict[str, Dict[str, Any]] = {}
    key_words = ("token", "account", "user", "owner", "beneficiary", "locker", "creator", "buyer", "seller", "role", "salt", "pool")
    for event_name, payload in event_activity.items():
        if not isinstance(payload, dict):
            continue
        for sample in payload.get("sample_logs", []):
            if not isinstance(sample, dict):
                continue
            decoded = sample.get("decoded") if isinstance(sample.get("decoded"), dict) else {}
            raw_words = sample.get("raw_words") if isinstance(sample.get("raw_words"), dict) else {}
            for name, value in decoded.items():
                normalized = normalize_name(str(name))
                if not any(word in normalized for word in key_words):
                    continue
                if isinstance(value, str) and value.startswith("0x"):
                    entry = hints.setdefault(normalized, {"field": name, "source_events": [], "sample_values": []})
                    if event_name not in entry["source_events"]:
                        entry["source_events"].append(event_name)
                    if value not in entry["sample_values"] and len(entry["sample_values"]) < 12:
                        entry["sample_values"].append(value)
                elif isinstance(value, int):
                    entry = hints.setdefault(normalized, {"field": name, "source_events": [], "sample_values": []})
                    if event_name not in entry["source_events"]:
                        entry["source_events"].append(event_name)
                    if value not in entry["sample_values"] and len(entry["sample_values"]) < 12:
                        entry["sample_values"].append(value)
            for name, raw in raw_words.items():
                if isinstance(raw, str) and raw.startswith("0x") and len(raw) == 66:
                    normalized = normalize_name(str(name))
                    if "salt" in normalized or "role" in normalized or "id" in normalized:
                        entry = hints.setdefault(normalized, {"field": name, "source_events": [], "sample_values": []})
                        if event_name not in entry["source_events"]:
                            entry["source_events"].append(event_name)
                        if raw not in entry["sample_values"] and len(entry["sample_values"]) < 12:
                            entry["sample_values"].append(raw)
    return hints


def collect_probe_values(
    address: str,
    dependencies: list[Dict[str, str]],
    event_activity: Dict[str, Any],
) -> Dict[str, List[Any]]:
    values: Dict[str, List[Any]] = {
        "address": [address],
        "uint": [0, 1],
        "int": [0, 1],
        "bool": [False, True],
        "bytes32": ["0x" + ("0" * 64)],
        "bytesn": ["0x" + ("0" * 64)],
    }

    def add(kind: str, value: Any) -> None:
        bucket = values.setdefault(kind, [])
        if value not in bucket and len(bucket) < 16:
            bucket.append(value)

    for dep in dependencies:
        dep_address = dep.get("address")
        if isinstance(dep_address, str) and dep_address.startswith("0x") and len(dep_address) == 42:
            add("address", dep_address)

    for payload in event_activity.values():
        if not isinstance(payload, dict):
            continue
        for sample in payload.get("sample_logs", []):
            if not isinstance(sample, dict):
                continue
            decoded = sample.get("decoded") if isinstance(sample.get("decoded"), dict) else {}
            raw_words = sample.get("raw_words") if isinstance(sample.get("raw_words"), dict) else {}
            for value in decoded.values():
                if isinstance(value, str) and value.startswith("0x") and len(value) == 42:
                    add("address", value.lower())
                elif isinstance(value, str) and value.startswith("0x") and len(value) == 66:
                    add("bytes32", value)
                    add("bytesn", value)
                elif isinstance(value, bool):
                    add("bool", value)
                elif isinstance(value, int):
                    add("uint", value)
                    add("int", value)
            for raw in raw_words.values():
                if isinstance(raw, str) and raw.startswith("0x") and len(raw) == 66:
                    add("bytes32", raw)
                    add("bytesn", raw)
    return values


def candidate_args_for_inputs(inputs: List[Dict[str, Any]], probe_values: Dict[str, List[Any]], max_per_input: int = 4) -> List[List[Any]]:
    candidates: List[List[Any]] = [[]]
    for inp in inputs:
        abi_type = str(inp.get("type", ""))
        base_type = base_abi_type(abi_type)
        values = probe_values.get(base_type, [])[:max_per_input]
        if not values:
            return []
        next_candidates: List[List[Any]] = []
        for prefix in candidates:
            for value in values:
                next_candidates.append(prefix + [value])
                if len(next_candidates) >= 24:
                    break
            if len(next_candidates) >= 24:
                break
        candidates = next_candidates
    return candidates


def collect_parameterized_views(
    client: RpcClient,
    address: str,
    abi: list[Dict[str, Any]],
    dependencies: list[Dict[str, str]],
    event_activity: Dict[str, Any],
    max_functions: int = 30,
) -> Dict[str, Any]:
    probe_values = collect_probe_values(address, dependencies, event_activity)
    functions = [
        fn
        for fn in abi
        if fn.get("type") == "function"
        and fn.get("name")
        and fn.get("stateMutability") in ("view", "pure")
        and 0 < len(fn.get("inputs", [])) <= 3
        and all(is_static_supported_type(str(inp.get("type", ""))) for inp in fn.get("inputs", []))
    ]
    priority_words = ("role", "token", "quote", "lock", "salt", "fee", "spammer", "beneficiary", "pool", "preview")
    functions.sort(key=lambda fn: (not any(word in str(fn.get("name", "")).lower() for word in priority_words), str(fn.get("name", "")).lower()))
    results: Dict[str, Any] = {}
    for fn in functions[:max_functions]:
        inputs = [inp for inp in fn.get("inputs", []) if isinstance(inp, dict)]
        outputs = [out for out in fn.get("outputs", []) if isinstance(out, dict)]
        samples = []
        for args in candidate_args_for_inputs(inputs, probe_values):
            data = encode_function_call_data(client, fn, args)
            if not data:
                continue
            raw = try_call(client, address, data)
            if raw in ("", "0x"):
                continue
            samples.append(
                {
                    "args": args,
                    "raw_output": raw[:514],
                    "decoded_output": decode_multi_static_outputs(raw, outputs) if outputs else raw[:514],
                }
            )
            if len(samples) >= 3:
                break
        if samples:
            results[str(fn.get("name"))] = {
                "signature": abi_function_signature(fn),
                "inputs": [{"name": inp.get("name", ""), "type": inp.get("type", "")} for inp in inputs],
                "sample_count": len(samples),
                "samples": samples,
            }
    return results


def dependency_addresses(views: Dict[str, Any], proxy_slots: Dict[str, Any], address: str) -> list[Dict[str, str]]:
    deps: Dict[str, str] = {}
    for name, value in views.items():
        if isinstance(value, str) and value.startswith("0x") and len(value) == 42:
            lower_name = name.lower()
            if any(word in lower_name for word in EXTERNAL_DEPENDENCY_VIEW_NAMES) and value.lower() != address.lower():
                deps[name] = value.lower()
    for name in ("implementation", "admin", "beacon"):
        value = proxy_slots.get(name)
        if isinstance(value, str) and value.startswith("0x") and len(value) == 42 and value.lower() != address.lower():
            deps[f"proxy_{name}"] = value.lower()
    return [{"name": name, "address": dep} for name, dep in sorted(deps.items())]


def collect_dependency_context(client: RpcClient, dependencies: list[Dict[str, str]], max_dependencies: int = 40) -> list[Dict[str, Any]]:
    context: list[Dict[str, Any]] = []
    for dep in dependencies[:max_dependencies]:
        dep_address = dep.get("address", "")
        if not dep_address.startswith("0x") or len(dep_address) != 42:
            continue
        try:
            code = client.get_code(dep_address)
        except Exception:
            code = "0x"
        token_symbol = try_token_call(client, dep_address, "symbol()", "string")
        token_name = try_token_call(client, dep_address, "name()", "string")
        token_decimals = try_token_call(client, dep_address, "decimals()", "uint8")
        try:
            native_balance = client.get_balance(dep_address)
        except Exception:
            native_balance = 0
        context.append(
            {
                "name": dep.get("name", ""),
                "address": dep_address,
                "code_size_bytes": max((len(code) - 2) // 2, 0) if isinstance(code, str) else 0,
                "native_balance_wei": native_balance,
                "erc20_identity": {
                    "symbol": token_symbol or "",
                    "name": token_name or "",
                    "decimals": token_decimals if isinstance(token_decimals, int) else None,
                },
            }
        )
    return context


def audit_focus_notes(inventory: Dict[str, Any], erc20: list[Dict[str, Any]], native_balance: int, native_symbol: str) -> list[str]:
    notes = [
        "Prioritize proof of unauthorized value extraction, excess token allocation, excess claim/reward, stuck-fund recovery abuse, and invariant-breaking swaps or migrations.",
        "Check each payable and value-movement function against balance deltas, reserve/circulating-supply accounting, delegatecall target selection, and min-output checks.",
        "Check privileged functions separately for externally reachable role bypass or misconfigured live roles; admin-key compromise alone is not a valid critical path.",
    ]
    if native_balance:
        notes.append(f"Live target holds native balance: {native_balance} wei {native_symbol}; every withdrawal/recovery/claim/swap path must reconcile against this custody.")
    if erc20:
        largest = erc20[0]
        notes.append(f"Live target holds ERC20 balance: largest observed {largest.get('symbol')} {largest.get('human_balance')}; include token-drain and accounting-liability checks.")
    if inventory.get("payable_functions"):
        notes.append("Payable entrypoints exist; test msg.value accounting, refund behavior, CREATE2/salt locking fees, and quote-token/native-token branch mismatches.")
    return notes


def target_live_address(target: Dict[str, Any]) -> str:
    return str(target.get("proxy_address") or target["address"]).lower()


def collect_context(target: Dict[str, Any]) -> Dict[str, Any]:
    config = get_chain(target["chain"])
    client = RpcClient(rpc_endpoints(config.key))
    address = target_live_address(target)
    latest_block = client.block_number()
    code = client.get_code(address)
    native_balance = client.get_balance(address)
    slots = {
        "eip1967_implementation": client.get_storage_at(address, EIP1967_IMPLEMENTATION_SLOT),
        "eip1967_admin": client.get_storage_at(address, EIP1967_ADMIN_SLOT),
        "eip1967_beacon": client.get_storage_at(address, EIP1967_BEACON_SLOT),
    }
    slot_implementation = word_to_address(slots["eip1967_implementation"])
    implementation_address = target.get("implementation_address") or slot_implementation
    implementation_code = ""
    implementation_balance = 0
    if implementation_address and implementation_address != address:
        implementation_code = client.get_code(implementation_address)
        implementation_balance = client.get_balance(implementation_address)
    views = {
        "owner": decode_address_word(try_call(client, address, "0x8da5cb5b")),
        "admin": decode_address_word(try_call(client, address, "0xf851a440")),
        "totalSupply": decode_uint(try_call(client, address, "0x18160ddd")),
        "decimals": decode_uint(try_call(client, address, "0x313ce567")),
        "token0": decode_address_word(try_call(client, address, "0x0dfe1681")),
        "token1": decode_address_word(try_call(client, address, "0xd21220a7")),
        "factory": decode_address_word(try_call(client, address, "0xc45a0155")),
    }
    abi = load_target_abi(target)
    identity = load_source_identity(target)
    zero_arg_views, view_errors = collect_zero_arg_views(client, address, abi) if abi else ({}, {})
    all_views = {**views, **zero_arg_views}
    inventory = function_inventory(abi)
    token_balances = erc20_balances(client, config.key, address, latest_block) if abi else []
    event_activity = collect_event_activity(client, address, abi, latest_block) if abi else {}
    proxy_slots = {
        "implementation_raw": slots["eip1967_implementation"],
        "implementation": slot_implementation,
        "admin_raw": slots["eip1967_admin"],
        "admin": word_to_address(slots["eip1967_admin"]),
        "beacon_raw": slots["eip1967_beacon"],
        "beacon": word_to_address(slots["eip1967_beacon"]),
    }
    dependencies = dependency_addresses(all_views, proxy_slots, address)
    parameterized_views = collect_parameterized_views(client, address, abi, dependencies, event_activity) if abi else {}
    return {
        "schema_version": "acte-live-context-v3",
        "captured_at": now_utc(),
        "chain": config.key,
        "chain_id": config.chain_id,
        "rpc_endpoint_used": client.last_endpoint,
        "latest_block": latest_block,
        "target": {
            "address": address,
            "input_address": target.get("input_address") or target["address"],
            "proxy_address": target.get("proxy_address") or "",
            "implementation_address": implementation_address or "",
            "source_address": target.get("source_address") or implementation_address or address,
            "deployment_kind": "proxy" if (target.get("proxy_address") or slot_implementation) else "implementation_or_direct",
            "label": target["label"],
            "explorer_url": target["explorer_url"],
            "code_size_bytes": max((len(code) - 2) // 2, 0),
            "native_balance_wei": native_balance,
            "native_symbol": config.native_symbol,
        },
        "proxy_slots": proxy_slots,
        "implementation": {
            "address": implementation_address or "",
            "provided": bool(target.get("implementation_address")),
            "resolved_from_eip1967": bool(slot_implementation and not target.get("implementation_address")),
            "code_size_bytes": max((len(implementation_code) - 2) // 2, 0) if implementation_code else 0,
            "native_balance_wei": implementation_balance,
        },
        "source_identity": identity,
        "abi_inventory": inventory,
        "common_views": all_views,
        "view_errors": view_errors,
        "balances": {
            "native": {
                "raw": str(native_balance),
                "human": str(Decimal(native_balance) / Decimal(10**18)),
                "symbol": config.native_symbol,
            },
            "erc20": token_balances,
        },
        "dependencies": dependencies,
        "dependency_context": collect_dependency_context(client, dependencies),
        "event_activity": event_activity,
        "mapping_key_hints": infer_mapping_key_hints(event_activity),
        "parameterized_views": parameterized_views,
        "deepwiki_audit_focus": audit_focus_notes(inventory, token_balances, native_balance, config.native_symbol),
        "audit_notes": [
            "Live balances, storage slots, and common view calls are captured from the proxy/live address when a proxy is present.",
            "Private mappings and structs are not globally enumerable without known keys.",
            "DeepWiki candidates must be checked against this block-specific live state before proof.",
            "ABI inventory and event samples are bounded hints for prioritization; proof must use source-level tests or fork probes.",
            "Parameterized view probes use event-derived keys and dependency addresses, so failures are hints rather than complete absence of state.",
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
