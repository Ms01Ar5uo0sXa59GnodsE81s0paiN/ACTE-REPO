from __future__ import annotations

from dataclasses import dataclass
from typing import Dict, Optional


@dataclass(frozen=True)
class ChainConfig:
    key: str
    chain_id: int
    native_symbol: str
    explorer_host: str
    explorer_api_url: str
    api_key_env: str
    rpc_env: str
    public_rpc: tuple[str, ...]
    etherscan_v2_chain_id: int | None = None

    def explorer_url(self, address: str) -> str:
        return f"https://{self.explorer_host}/address/{address}"


CHAINS: Dict[str, ChainConfig] = {
    "bsc": ChainConfig(
        key="bsc",
        chain_id=56,
        native_symbol="BNB",
        explorer_host="bscscan.com",
        explorer_api_url="https://api.bscscan.com/api",
        api_key_env="BSCSCAN_API_KEY",
        rpc_env="BSC_RPC_URL",
        public_rpc=("https://bsc-dataseed.binance.org", "https://bsc-rpc.publicnode.com"),
    ),
    "ethereum": ChainConfig(
        key="ethereum",
        chain_id=1,
        native_symbol="ETH",
        explorer_host="etherscan.io",
        explorer_api_url="https://api.etherscan.io/v2/api",
        api_key_env="ETHERSCAN_API_KEY",
        rpc_env="ETHEREUM_RPC_URL",
        public_rpc=("https://ethereum-rpc.publicnode.com",),
        etherscan_v2_chain_id=1,
    ),
    "arbitrum": ChainConfig(
        key="arbitrum",
        chain_id=42161,
        native_symbol="ETH",
        explorer_host="arbiscan.io",
        explorer_api_url="https://api.etherscan.io/v2/api",
        api_key_env="ARBISCAN_API_KEY",
        rpc_env="ARBITRUM_RPC_URL",
        public_rpc=("https://arbitrum-one-rpc.publicnode.com",),
        etherscan_v2_chain_id=42161,
    ),
    "base": ChainConfig(
        key="base",
        chain_id=8453,
        native_symbol="ETH",
        explorer_host="basescan.org",
        explorer_api_url="https://api.etherscan.io/v2/api",
        api_key_env="BASESCAN_API_KEY",
        rpc_env="BASE_RPC_URL",
        public_rpc=("https://mainnet.base.org", "https://base-rpc.publicnode.com"),
        etherscan_v2_chain_id=8453,
    ),
    "optimism": ChainConfig(
        key="optimism",
        chain_id=10,
        native_symbol="ETH",
        explorer_host="optimistic.etherscan.io",
        explorer_api_url="https://api.etherscan.io/v2/api",
        api_key_env="OPTIMISTIC_ETHERSCAN_API_KEY",
        rpc_env="OPTIMISM_RPC_URL",
        public_rpc=("https://mainnet.optimism.io", "https://optimism-rpc.publicnode.com"),
        etherscan_v2_chain_id=10,
    ),
}

ALIASES = {
    "bnb": "bsc",
    "binance": "bsc",
    "binance-smart-chain": "bsc",
    "eth": "ethereum",
    "arb": "arbitrum",
    "op": "optimism",
}


def chain_key(value: str) -> str:
    key = value.strip().lower()
    return ALIASES.get(key, key)


def get_chain(value: str) -> ChainConfig:
    key = chain_key(value)
    if key not in CHAINS:
        supported = ", ".join(sorted(CHAINS))
        raise ValueError(f"unsupported chain {value!r}; supported: {supported}")
    return CHAINS[key]


def chain_from_host(host: str) -> Optional[str]:
    h = host.lower()
    for key, config in CHAINS.items():
        if h == config.explorer_host or h.endswith("." + config.explorer_host):
            return key
    return None
