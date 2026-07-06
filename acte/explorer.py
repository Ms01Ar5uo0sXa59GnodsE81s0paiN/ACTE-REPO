from __future__ import annotations

import json
import os
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any, Dict, Optional

from .chains import get_chain


class ExplorerError(RuntimeError):
    pass


@dataclass(frozen=True)
class SourceRecord:
    chain: str
    address: str
    verified: bool
    contract_name: str
    compiler_version: str
    optimization_used: bool
    optimizer_runs: Optional[int]
    evm_version: str
    source_code: str
    abi: str
    constructor_arguments: str
    proxy: bool
    implementation: str
    raw: Dict[str, Any]


def fetch_json(url: str, params: Dict[str, str], timeout: int = 30) -> Dict[str, Any]:
    query = urllib.parse.urlencode(params)
    request = urllib.request.Request(f"{url}?{query}", headers={"User-Agent": "acte/1.0"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        body = response.read().decode("utf-8")
    data = json.loads(body)
    if not isinstance(data, dict):
        raise ExplorerError("explorer response was not a JSON object")
    return data


def fetch_source_record(chain: str, address: str) -> SourceRecord:
    config = get_chain(chain)
    params = {
        "module": "contract",
        "action": "getsourcecode",
        "address": address,
        "apikey": os.environ.get(config.api_key_env, ""),
    }
    if config.etherscan_v2_chain_id is not None:
        params["chainid"] = str(config.etherscan_v2_chain_id)
    data = fetch_json(config.explorer_api_url, params)
    result = data.get("result")
    if not isinstance(result, list) or not result:
        raise ExplorerError(f"source response was not a contract list for {chain}:{address}: {result!r}")
    row = result[0]
    if not isinstance(row, dict):
        raise ExplorerError("source response row was not an object")
    source_code = str(row.get("SourceCode") or "")
    abi = str(row.get("ABI") or "")
    verified = bool(source_code.strip()) and abi != "Contract source code not verified"
    optimization = str(row.get("OptimizationUsed") or "0") == "1"
    runs = None
    try:
        if str(row.get("Runs") or ""):
            runs = int(str(row.get("Runs")))
    except ValueError:
        runs = None
    return SourceRecord(
        chain=config.key,
        address=address,
        verified=verified,
        contract_name=str(row.get("ContractName") or "Contract"),
        compiler_version=str(row.get("CompilerVersion") or ""),
        optimization_used=optimization,
        optimizer_runs=runs,
        evm_version=str(row.get("EVMVersion") or ""),
        source_code=source_code,
        abi=abi,
        constructor_arguments=str(row.get("ConstructorArguments") or ""),
        proxy=str(row.get("Proxy") or "0") == "1",
        implementation=str(row.get("Implementation") or ""),
        raw=row,
    )


def _load_source_json(source_code: str) -> Optional[Dict[str, Any]]:
    text = source_code.strip()
    if not text:
        return None
    candidates = [text]
    if text.startswith("{{") and text.endswith("}}"):
        candidates.append(text[1:-1])
    for candidate in candidates:
        try:
            parsed = json.loads(candidate)
        except json.JSONDecodeError:
            continue
        if isinstance(parsed, dict):
            return parsed
    return None


def source_bundle(record: SourceRecord) -> Dict[str, Any]:
    """Return normalized sources/settings from explorer SourceCode."""
    parsed = _load_source_json(record.source_code)
    if parsed and isinstance(parsed.get("sources"), dict):
        sources = {}
        for name, value in parsed["sources"].items():
            if isinstance(value, dict):
                content = value.get("content")
            else:
                content = value
            if isinstance(content, str):
                sources[str(name)] = content
        return {
            "format": "standard-json",
            "language": parsed.get("language", "Solidity"),
            "sources": sources,
            "settings": parsed.get("settings") if isinstance(parsed.get("settings"), dict) else {},
            "standard_json": parsed,
        }

    if parsed:
        sources = {}
        for name, value in parsed.items():
            if isinstance(value, dict) and isinstance(value.get("content"), str):
                sources[str(name)] = value["content"]
            elif isinstance(value, str):
                sources[str(name)] = value
        if sources:
            return {"format": "multi-file-json", "language": "Solidity", "sources": sources, "settings": {}}

    name = record.contract_name or "Contract"
    return {
        "format": "single-file",
        "language": "Solidity",
        "sources": {f"{name}.sol": record.source_code},
        "settings": {},
    }
