# ACTE-REPO

ACTE is a contract-address-to-audit-workspace machine.

The first supported path is intentionally narrow:

1. Accept only a chain and contract address.
2. Resolve the live deployment identity, including proxy metadata.
3. Fetch verified explorer source and materialize a Foundry project.
4. Collect live context for audit and DeepWiki prompts.
5. Push the target package to `origin master` using the GitHub account represented by `ACTE_DEPLOY_TOKEN`.

## Secret Model

`ACTE_DEPLOY_TOKEN` must be a GitHub PAT owned by the account that should deploy the target repository.

The deploy script checks GitHub `/user` with that token. If `--expected-owner` is provided and the token owner does not match, the script exits before creating a repo or pushing.

Explorer API keys are optional but recommended:

- `BSCSCAN_API_KEY`
- `ETHERSCAN_API_KEY`
- `ARBISCAN_API_KEY`
- `BASESCAN_API_KEY`
- `OPTIMISTIC_ETHERSCAN_API_KEY`

RPC secrets are required for live-context capture on the matching chain:

- `BSC_RPC_URL`
- `ETHEREUM_RPC_URL`
- `ARBITRUM_RPC_URL`
- `BASE_RPC_URL`
- `OPTIMISM_RPC_URL`

For this deployment account, create `ACTE_DEPLOY_TOKEN` from the GitHub account `Ms01Ar5uo0sXa59GnodsE81s0paiN` and run workflow `5 Push To GitHub Account` with:

- `expected_owner`: `Ms01Ar5uo0sXa59GnodsE81s0paiN`
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
python3 scripts/run_deploy_github.py --repo-name acte-target-example --expected-owner Ms01Ar5uo0sXa59GnodsE81s0paiN --branch master
```

The materializer requires verified source. If the explorer does not return verified source, ACTE writes a source-incomplete bundle and refuses to mark the Foundry project audit-ready.
