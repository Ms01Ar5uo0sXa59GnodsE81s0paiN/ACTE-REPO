# ACTE-REPO

ACTE is a contract-address-to-audit-workspace machine.

The first supported path is intentionally narrow:

1. Accept only a chain and contract address.
2. Resolve the live deployment identity, including proxy metadata.
3. Fetch verified explorer source and materialize a Foundry project.
4. Collect live context for audit and DeepWiki prompts.
5. Push the target package to the GitHub account represented by `ACTE_DEPLOY_TOKEN`.

## Secret Model

`ACTE_DEPLOY_TOKEN` must be a GitHub PAT owned by the account that should receive the deployed target repository.

The deploy script checks GitHub `/user` with that token. If `--expected-owner` is provided and the token owner does not match, the script exits before creating a repo or pushing.

Explorer API keys are optional but recommended. GitHub secrets may be either a plain string or JSON such as `["key1", "key2"]` / `{"api_keys":["key1","key2"]}`; ACTE uses the first non-empty value.

- `BSCSCAN_API_KEY`
- `ETHERSCAN_API_KEY`
- `ARBISCAN_API_KEY`
- `BASESCAN_API_KEY`
- `OPTIMISTIC_ETHERSCAN_API_KEY`

Etherscan API V2 is used for BSC as well, with `chainid=56`. For BSC targets, `BSCSCAN_API_KEY` may contain an Etherscan V2 key; if it is empty, ACTE falls back to `ETHERSCAN_API_KEY`.

RPC secrets are required for live-context capture on the matching chain. GitHub secrets may be either a plain URL or JSON such as `["https://rpc1", "https://rpc2"]` / `{"rpc_urls":["https://rpc1","https://rpc2"]}`; ACTE tries configured URLs before public fallbacks.

- `BSC_RPC_URL`
- `ETHEREUM_RPC_URL`
- `ARBITRUM_RPC_URL`
- `BASE_RPC_URL`
- `OPTIMISM_RPC_URL`

For the deployment account, create `ACTE_DEPLOY_TOKEN` from the destination GitHub account. Repository variable `ACTE_TARGET_GITHUB_OWNER` is optional; when set, it must be the destination GitHub login, not a PAT. Workflow `5 Push To GitHub Account` also accepts an `expected_owner` input for one-off runs; if both are set, the workflow input wins.

- `expected_owner`: destination GitHub login, or leave blank to use the `ACTE_DEPLOY_TOKEN` owner
- `repo_name`: target package repository name, for example `acte-target-example`
- `private`: `true` or `false`
- `dry_run`: `true` first, then `false` after owner/package verification
- `branch`: `master`

## Local Commands

```sh
python3 -m unittest discover -s tests -v
python3 scripts/run_intake_address.py --chain bsc --address 0x0000000000000000000000000000000000001004 --label example
python3 scripts/run_materialize_verified_foundry.py
python3 scripts/run_collect_live_context.py
python3 scripts/run_deploy_github.py --repo-name acte-target-example --expected-owner DESTINATION_GITHUB_LOGIN --branch master
```

## Proxy Address Modes

ACTE supports BSC with `--chain bsc` and Ethereum mainnet with `--chain ethereum` or `--chain eth`.

Use one of these intake modes:

```sh
# Implementation/direct-only: source and live context use this address.
python3 scripts/run_intake_address.py --chain eth --address 0xIMPLEMENTATION --label example

# Proxy-only: live context uses the proxy address; materialization tries explorer
# proxy metadata first, then the EIP-1967 implementation slot before fetching source.
python3 scripts/run_intake_address.py --chain bsc --address 0xPROXY --label example

# Proxy plus known implementation: live balance/storage comes from the proxy,
# verified Solidity source is fetched from the implementation.
python3 scripts/run_intake_address.py --chain bsc --address 0xPROXY --implementation-address 0xIMPLEMENTATION --label example
```

Package paths stay under the live/proxy address. `addresses.json`, `audit_seed.json`, and `live_context.json` record `proxy_address`, `implementation_address`, and `source_address` so later proof steps know which address owns balances/storage and which address owns source code.

The materializer requires verified source. If the explorer does not return verified source, ACTE writes a source-incomplete bundle and refuses to mark the Foundry project audit-ready.
