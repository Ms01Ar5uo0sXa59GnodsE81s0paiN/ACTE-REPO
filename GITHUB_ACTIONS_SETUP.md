# GitHub Actions Setup

This controller repo is configured to run from `origin master`.

## Current Controller Repository

- Owner: `Ms01Ar5uo0sXa59GnodsE81s0paiN`
- Repository: `ACTE-REPO`
- Remote URL: `https://github.com/Ms01Ar5uo0sXa59GnodsE81s0paiN/ACTE-REPO.git`
- Branch: `master`

This is only the controller repository that runs the ACTE workflows. Workflow `5 Push To GitHub Account` deploys target packages to the separate account represented by `ACTE_DEPLOY_TOKEN`.

## Required Secrets

Create these under GitHub repository settings:

`Settings -> Secrets and variables -> Actions -> New repository secret`

| Secret | Required for | Format |
| --- | --- | --- |
| `ACTE_DEPLOY_TOKEN` | Workflow `5 Push To GitHub Account` | GitHub PAT string owned by the destination account; needs permission to create repositories and push contents |
| `BSCSCAN_API_KEY` | Workflow `1 Materialize Verified Foundry` for BSC targets | Etherscan API V2 key as a plain string, `["key1","key2"]`, or `{"api_keys":["key1","key2"]}`. BSC now uses `https://api.etherscan.io/v2/api?chainid=56`. |
| `BSC_RPC_URL` | Workflow `3 Collect Live Context` for BSC targets | Full HTTPS RPC URL as a plain string, `["https://rpc1","https://rpc2"]`, or `{"rpc_urls":["https://rpc1","https://rpc2"]}` |

## Required Variables

Create these under GitHub repository settings:

`Settings -> Secrets and variables -> Actions -> Variables -> New repository variable`

| Variable | Required for | Format |
| --- | --- | --- |
| `ACTE_TARGET_GITHUB_OWNER` | Workflow `5 Push To GitHub Account` | Exact GitHub login for the destination account that owns `ACTE_DEPLOY_TOKEN` |

## Optional Chain Secrets

Add these only when the active target is on that chain:

| Secret | Format |
| --- | --- |
| `ETHERSCAN_API_KEY` | Plain Etherscan API key string or JSON key list; also used as the fallback for BSC if `BSCSCAN_API_KEY` is empty |
| `ARBISCAN_API_KEY` | Plain Arbiscan API key string |
| `BASESCAN_API_KEY` | Plain BaseScan API key string |
| `OPTIMISTIC_ETHERSCAN_API_KEY` | Plain Optimism Etherscan API key string |
| `ETHEREUM_RPC_URL` | Full HTTPS Ethereum RPC URL |
| `ARBITRUM_RPC_URL` | Full HTTPS Arbitrum RPC URL |
| `BASE_RPC_URL` | Full HTTPS Base RPC URL |
| `OPTIMISM_RPC_URL` | Full HTTPS Optimism RPC URL |

## Smoke Test

Run locally before pushing:

```sh
python3 -m unittest discover -v
```

The GitHub workflow `Smoke Test` runs the same unit smoke gate on `master`.

## Workflow Order

Run these manually from the GitHub Actions tab:

1. `0 Intake Address`
2. `1 Materialize Verified Foundry`
3. `2 Verify Foundry Build`
4. `3 Collect Live Context`
5. `4 Package DeepWiki Corpus`
6. `5 Push To GitHub Account`

For workflow `5 Push To GitHub Account`, use:

| Input | Value |
| --- | --- |
| `expected_owner` | Destination GitHub login, or leave blank to use `ACTE_TARGET_GITHUB_OWNER` |
| `repo_name` | The new target package repository name |
| `private` | `true` or `false` |
| `dry_run` | `true` first, then `false` after verification |
| `branch` | `master` |
