from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
from pathlib import Path
from typing import Any, Dict, Optional

from .explorer import SourceRecord, fetch_source_record, source_bundle
from .intake import active_target
from .io import read_json, safe_relative_path, write_json


def solc_version(value: str) -> str:
    match = re.search(r"(\d+\.\d+\.\d+)", value or "")
    return match.group(1) if match else "0.8.20"


def bool_setting(value: Any) -> bool:
    return bool(value) and str(value).lower() not in {"false", "0", "none"}


def inferred_remappings(sources: Dict[str, str]) -> list[str]:
    remappings: set[str] = set()
    for source_name in sources:
        parts = safe_relative_path(source_name).parts
        if not parts:
            continue
        if parts[0].startswith("@") and len(parts) >= 2:
            prefix = "/".join(parts[:2])
            remappings.add(f"{prefix}/=src/{prefix}/")
        elif len(parts) >= 2:
            remappings.add(f"{parts[0]}/=src/{parts[0]}/")
    return sorted(remappings)


def foundry_toml(record: SourceRecord, bundle: Dict[str, Any]) -> str:
    settings = bundle.get("settings") if isinstance(bundle.get("settings"), dict) else {}
    optimizer = settings.get("optimizer") if isinstance(settings.get("optimizer"), dict) else {}
    optimizer_enabled = optimizer.get("enabled", record.optimization_used)
    optimizer_runs = optimizer.get("runs", record.optimizer_runs or 200)
    evm_version = settings.get("evmVersion") or record.evm_version
    via_ir = settings.get("viaIR")
    configured_remappings = settings.get("remappings") if isinstance(settings.get("remappings"), list) else []
    remappings = list(dict.fromkeys([*configured_remappings, *inferred_remappings(bundle.get("sources", {}))]))

    lines = [
        "[profile.default]",
        'src = "src"',
        'out = "out"',
        'libs = ["lib"]',
        f'solc_version = "{solc_version(record.compiler_version)}"',
        f"optimizer = {str(bool_setting(optimizer_enabled)).lower()}",
        f"optimizer_runs = {int(optimizer_runs)}",
    ]
    if evm_version and evm_version != "Default":
        lines.append(f'evm_version = "{evm_version}"')
    if via_ir is not None:
        lines.append(f"via_ir = {str(bool_setting(via_ir)).lower()}")
    if remappings:
        lines.append("remappings = [")
        for remapping in remappings:
            lines.append(f'  "{remapping}",')
        lines.append("]")
    return "\n".join(lines) + "\n"


def source_output_path(project_dir: Path, source_name: str) -> Path:
    rel = safe_relative_path(source_name)
    if rel.parts and rel.parts[0] == "lib":
        return project_dir / rel
    return project_dir / "src" / rel


def write_sources(project_dir: Path, sources: Dict[str, str]) -> None:
    for source_name, content in sources.items():
        out = source_output_path(project_dir, source_name)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(content, encoding="utf-8")


def read_source_record_from_file(path: str | Path) -> SourceRecord:
    payload = read_json(path)
    return SourceRecord(
        chain=payload["chain"],
        address=payload["address"],
        verified=payload["verified"],
        contract_name=payload["contract_name"],
        compiler_version=payload["compiler_version"],
        optimization_used=payload["optimization_used"],
        optimizer_runs=payload.get("optimizer_runs"),
        evm_version=payload.get("evm_version") or "",
        source_code=payload["source_code"],
        abi=payload.get("abi") or "",
        constructor_arguments=payload.get("constructor_arguments") or "",
        proxy=payload.get("proxy", False),
        implementation=payload.get("implementation") or "",
        raw=payload.get("raw") or {},
    )


def source_record_from_standard_json(
    *,
    path: str | Path,
    target: Dict[str, Any],
    contract_name: str,
    compiler_version: str,
) -> SourceRecord:
    source_code = Path(path).read_text(encoding="utf-8")
    return SourceRecord(
        chain=target["chain"],
        address=target["address"],
        verified=True,
        contract_name=contract_name,
        compiler_version=compiler_version,
        optimization_used=True,
        optimizer_runs=None,
        evm_version="",
        source_code=source_code,
        abi="[]",
        constructor_arguments="",
        proxy=False,
        implementation="",
        raw={"source": str(path), "format": "standard-json"},
    )


def serializable_source_record(record: SourceRecord) -> Dict[str, Any]:
    return {
        "chain": record.chain,
        "address": record.address,
        "verified": record.verified,
        "contract_name": record.contract_name,
        "compiler_version": record.compiler_version,
        "optimization_used": record.optimization_used,
        "optimizer_runs": record.optimizer_runs,
        "evm_version": record.evm_version,
        "source_code": record.source_code,
        "abi": record.abi,
        "constructor_arguments": record.constructor_arguments,
        "proxy": record.proxy,
        "implementation": record.implementation,
        "raw": record.raw,
    }


def materialize_foundry_project(target: Dict[str, Any], source_record: SourceRecord) -> Path:
    project_dir = Path(target["paths"]["foundry_dir"])
    source_artifacts = project_dir / "source-artifacts"
    source_artifacts.mkdir(parents=True, exist_ok=True)
    (project_dir / "src").mkdir(parents=True, exist_ok=True)
    (project_dir / "test").mkdir(parents=True, exist_ok=True)
    (project_dir / "script").mkdir(parents=True, exist_ok=True)
    (project_dir / "aarc-audit").mkdir(parents=True, exist_ok=True)

    write_json(source_artifacts / "source_response.json", serializable_source_record(source_record))
    write_json(project_dir / "addresses.json", {
        "chain": target["chain"],
        "chain_id": target["chain_id"],
        "address": target["address"],
        "proxy": source_record.proxy,
        "implementation": source_record.implementation,
        "explorer_url": target["explorer_url"],
    })

    if not source_record.verified:
        incomplete = {
            "schema_version": "acte-source-incomplete-v1",
            "reason": "Explorer did not return verified Solidity source.",
            "chain": target["chain"],
            "address": target["address"],
        }
        write_json(source_artifacts / "source_incomplete.json", incomplete)
        raise RuntimeError(f"source is not verified for {target['chain']}:{target['address']}")

    bundle = source_bundle(source_record)
    write_sources(project_dir, bundle["sources"])
    if bundle.get("standard_json"):
        write_json(source_artifacts / "metadata-standard-input.json", bundle["standard_json"])
    write_json(source_artifacts / "source_bundle.json", {
        "format": bundle["format"],
        "source_count": len(bundle["sources"]),
        "sources": sorted(bundle["sources"]),
    })
    (project_dir / "foundry.toml").write_text(foundry_toml(source_record, bundle), encoding="utf-8")
    if source_record.abi and source_record.abi != "Contract source code not verified":
        (source_artifacts / "abi.json").write_text(source_record.abi + "\n", encoding="utf-8")

    readme = f"""# {target['label']} Foundry Target

- Chain: `{target['chain']}` ({target['chain_id']})
- Address: `{target['address']}`
- Explorer: {target['explorer_url']}
- Contract: `{source_record.contract_name}`
- Compiler: `{source_record.compiler_version}`
- Proxy: `{source_record.proxy}`
- Implementation: `{source_record.implementation or ''}`

## Gates

- Verified source fetched: yes
- Build check: run `forge build`
- Live context: run `python3 scripts/run_collect_live_context.py` from ACTE root
- Findings are not submission-ready until a local proof passes.
"""
    (project_dir / "README.md").write_text(readme, encoding="utf-8")
    return project_dir


def copy_package_for_deepwiki(target: Dict[str, Any]) -> Path:
    source = Path(target["paths"]["foundry_dir"])
    if not source.exists():
        raise FileNotFoundError(f"Foundry target does not exist: {source}")
    package_dir = Path("packages") / target["chain"] / target["address"]
    if package_dir.exists():
        shutil.rmtree(package_dir)
    package_dir.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source, package_dir)
    live_context = Path(target["paths"]["live_context"])
    if live_context.exists():
        shutil.copyfile(live_context, package_dir / "live_context.json")
    return package_dir


def verify_foundry_build(project_dir: str | Path) -> Dict[str, Any]:
    project = Path(project_dir)
    result = subprocess.run(["forge", "build"], cwd=project, text=True, capture_output=True)
    payload = {
        "schema_version": "acte-foundry-build-verification-v1",
        "project_dir": str(project),
        "command": "forge build",
        "returncode": result.returncode,
        "stdout_tail": result.stdout[-4000:],
        "stderr_tail": result.stderr[-4000:],
        "build_passed": result.returncode == 0,
    }
    write_json(project / "source-artifacts" / "build_verification.json", payload)
    if result.returncode != 0:
        raise RuntimeError("forge build failed; see source-artifacts/build_verification.json")
    return payload


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Fetch verified source and materialize a Foundry project.")
    parser.add_argument("--source-response", default="", help="Use a saved source_response.json instead of explorer.")
    parser.add_argument("--standard-json", default="", help="Use a saved compiler standard-json input as verified source.")
    parser.add_argument("--contract-name", default="", help="Contract name for --standard-json mode.")
    parser.add_argument("--compiler-version", default="", help="Compiler version for --standard-json mode.")
    args = parser.parse_args(argv)

    target = active_target()
    if args.source_response and args.standard_json:
        raise ValueError("use only one of --source-response or --standard-json")
    if args.source_response:
        source_record = read_source_record_from_file(args.source_response)
    elif args.standard_json:
        source_record = source_record_from_standard_json(
            path=args.standard_json,
            target=target,
            contract_name=args.contract_name or target["label"],
            compiler_version=args.compiler_version or "0.8.20",
        )
    else:
        source_record = fetch_source_record(target["chain"], target["address"])
    project = materialize_foundry_project(target, source_record)
    print(f"materialized: {project}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
