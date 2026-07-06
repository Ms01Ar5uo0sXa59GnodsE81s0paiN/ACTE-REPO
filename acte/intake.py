from __future__ import annotations

import argparse
import re
from pathlib import Path
from typing import Any, Dict, Optional
from urllib.parse import urlparse

from .chains import chain_from_host, get_chain
from .io import read_json, write_json

ADDRESS_RE = re.compile(r"0x[a-fA-F0-9]{40}")
REGISTRY_SCHEMA = "acte-target-registry-v1"
TARGET_SCHEMA = "acte-target-v1"


def normalize_address(address: str) -> str:
    match = ADDRESS_RE.fullmatch(address.strip())
    if not match:
        raise ValueError(f"invalid EVM address: {address}")
    return "0x" + address[2:].lower()


def parse_target(target: str, default_chain: Optional[str]) -> tuple[str, str]:
    raw = target.strip()
    if raw.startswith("http://") or raw.startswith("https://"):
        parsed = urlparse(raw)
        chain = chain_from_host(parsed.netloc)
        match = ADDRESS_RE.search(raw)
        if not chain:
            raise ValueError(f"could not infer chain from explorer host: {parsed.netloc}")
        if not match:
            raise ValueError(f"no address found in target URL: {target}")
        return chain, normalize_address(match.group(0))

    chain = default_chain
    if not chain:
        raise ValueError("raw address input requires --chain")
    return get_chain(chain).key, normalize_address(raw)


def target_paths(chain: str, address: str) -> Dict[str, str]:
    target_dir = f"targets/{chain}/{address}"
    foundry_dir = f"foundry_targets/{chain}/{address}"
    return {
        "target_dir": target_dir,
        "foundry_dir": foundry_dir,
        "audit_seed": f"{target_dir}/audit_seed.json",
        "live_context": f"{target_dir}/live_context.json",
        "contract_graph": f"{target_dir}/contract_graph.json",
        "entrypoints": f"{target_dir}/entrypoints.json",
        "source_response": f"{foundry_dir}/source-artifacts/source_response.json",
        "deploy_manifest": f"{target_dir}/github_deploy.json",
    }


def build_target_record(
    *,
    target: str,
    chain: Optional[str],
    label: str,
    target_type: str,
    protocol: str,
) -> Dict[str, Any]:
    chain_key, address = parse_target(target, chain)
    config = get_chain(chain_key)
    display = label or protocol or address
    return {
        "schema_version": TARGET_SCHEMA,
        "active": True,
        "chain": config.key,
        "chain_id": config.chain_id,
        "native_symbol": config.native_symbol,
        "address": address,
        "label": display,
        "protocol": protocol or display,
        "target_type": target_type,
        "explorer_url": config.explorer_url(address),
        "paths": target_paths(config.key, address),
        "workflow": {
            "0_intake_address": "complete",
            "1_materialize_verified_foundry": "pending",
            "2_verify_foundry_build": "pending",
            "3_collect_live_context": "pending",
            "5_push_to_github_account": "pending",
        },
    }


def empty_registry() -> Dict[str, Any]:
    return {"schema_version": REGISTRY_SCHEMA, "active_target": "", "targets": []}


def load_registry(path: str | Path = "setup/target_registry.json") -> Dict[str, Any]:
    registry_path = Path(path)
    if not registry_path.exists():
        return empty_registry()
    data = read_json(registry_path)
    if data.get("schema_version") != REGISTRY_SCHEMA:
        raise ValueError(f"unsupported registry schema: {data.get('schema_version')}")
    if not isinstance(data.get("targets"), list):
        raise ValueError("registry targets must be a list")
    return data


def upsert_target(registry: Dict[str, Any], record: Dict[str, Any]) -> Dict[str, Any]:
    key = f"{record['chain']}:{record['address']}"
    targets = []
    replaced = False
    for item in registry.get("targets", []):
        if not isinstance(item, dict):
            continue
        if f"{item.get('chain')}:{item.get('address')}" == key:
            targets.append(record)
            replaced = True
        else:
            old = dict(item)
            old["active"] = False
            targets.append(old)
    if not replaced:
        targets.append(record)
    return {"schema_version": REGISTRY_SCHEMA, "active_target": key, "targets": targets}


def active_target(path: str | Path = "setup/target_registry.json") -> Dict[str, Any]:
    registry = load_registry(path)
    active = registry.get("active_target")
    for item in registry.get("targets", []):
        if isinstance(item, dict) and f"{item.get('chain')}:{item.get('address')}" == active:
            return item
    for item in registry.get("targets", []):
        if isinstance(item, dict) and item.get("active"):
            return item
    raise ValueError("no active target is registered")


def audit_seed(record: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "schema_version": "acte-audit-seed-v1",
        "chain": record["chain"],
        "chain_id": record["chain_id"],
        "address": record["address"],
        "label": record["label"],
        "explorer_url": record["explorer_url"],
        "foundry_dir": record["paths"]["foundry_dir"],
        "required_gates": [
            "verified source fetched",
            "Foundry project builds",
            "runtime identity checked against live deployment",
            "live context captured at a concrete block",
            "GitHub deploy owner verified from token",
        ],
    }


def write_target(record: Dict[str, Any]) -> Dict[str, Path]:
    registry = upsert_target(load_registry(), record)
    paths = {
        "registry": write_json("setup/target_registry.json", registry),
        "active_target": write_json("setup/active_target.json", record),
        "audit_seed": write_json(record["paths"]["audit_seed"], audit_seed(record)),
    }
    return paths


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Register a contract address for ACTE.")
    parser.add_argument("--address", required=True, help="Raw address or explorer URL.")
    parser.add_argument("--chain", default="", help="Required for raw addresses.")
    parser.add_argument("--label", default="")
    parser.add_argument("--protocol", default="")
    parser.add_argument("--target-type", default="contract")
    args = parser.parse_args(argv)

    record = build_target_record(
        target=args.address,
        chain=args.chain or None,
        label=args.label,
        protocol=args.protocol,
        target_type=args.target_type,
    )
    paths = write_target(record)
    print(f"registered {record['chain']}:{record['address']}")
    for name, path in paths.items():
        print(f"{name}: {path}")
    return 0

