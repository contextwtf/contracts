# Context Markets Contracts

This repo contains the smart contracts for [Context Markets](http://context.markets/), a prediction market platform. See the [license](LICENSE) for details on using this code in non-production and production settings.

View the [documentation](https://contextwtf.notion.site/Context-Protocol-26fbcb14ec7f817db95bc10d9c24e915) for more information.

## Structure

```
├── src
│   ├── PredictionMarket.sol   # Create, trade and resolve markets
│   ├── OutcomeToken.sol       # ERC20 token representing a market outcome
│   ├── Vault.sol              # Stake and lock Context market tokens for rewards
│   └── RewardDistributor.sol  # Context reward distributor
```

## Deployments

### Base Mainnet

- `PredictionMarket`: [0x000000000000CE50e1e1F6f99B2E5e98e5b6c609](https://basescan.org/address/0x000000000000CE50e1e1F6f99B2E5e98e5b6c609)
- `OutcomeToken Implementation`: [0x70674cA9e35cca4E12926357Ed763844d276532C](https://basescan.org/address/0x70674cA9e35cca4E12926357Ed763844d276532C)
- `Vault`: [0xE8e5dc8C7C8Fd6BfCE5E614E02F42E9cf8B72276](https://basescan.org/address/0xE8e5dc8C7C8Fd6BfCE5E614E02F42E9cf8B72276)
- `RewardDistributor`: [0xc1dd1ea5b7a3e84c3EbADcc6A4f13a0F432e78a2](https://basescan.org/address/0xc1dd1ea5b7a3e84c3EbADcc6A4f13a0F432e78a2)

### Base Sepolia

- `PredictionMarket`: [0x000000000000CE50e1e1F6f99B2E5e98e5b6c609](https://sepolia.basescan.org/address/0x000000000000CE50e1e1F6f99B2E5e98e5b6c609)
- `OutcomeToken Implementation`: [0x70674cA9e35cca4E12926357Ed763844d276532C](https://sepolia.basescan.org/address/0x70674cA9e35cca4E12926357Ed763844d276532C)
- `Vault`: [0x98a272c0F97c32DF73b3cBed26A67b07a50F2AFd](https://sepolia.basescan.org/address/0x98a272c0F97c32DF73b3cBed26A67b07a50F2AFd)
- `RewardDistributor`: [0x37C9fbB5653F4DeE9b5177Fec23F600d4275001F](https://sepolia.basescan.org/address/0x37C9fbB5653F4DeE9b5177Fec23F600d4275001F)
