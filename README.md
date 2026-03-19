# Grails Contracts

Solidity contracts for [Grails](https://grails.wtf): batch ENS `.eth` name registration and tiered subscriptions. Built with [Foundry](https://book.getfoundry.sh/).

## Features

### Bulk Registration
- **Batch registration** — register multiple `.eth` names in one transaction
- **Mixed-length support** — no same-price restriction; each name is priced individually
- **Referral tracking** — emits `NameRegistered` events with an immutable referrer
- **Automatic refunds** — excess ETH is returned in the same transaction
- **Batch utilities** — bulk availability checks, price quotes, commitment generation

### Subscriptions
- **Multi-tier subscriptions** — subscribe to Pro, Plus, or Gold for any number of days
- **Oracle-based USD pricing** — tier prices are set in attoUSD/second; ETH costs are derived at transaction time via a Chainlink ETH/USD oracle
- **Tier upgrades** — upgrade to a higher tier and convert remaining time proportionally based on tier price rates (no value lost)
- **Automatic refunds** — excess ETH is returned in the same transaction
- **Owner withdrawal** — owner can withdraw collected funds
- **Ownable2Step** — safe two-step ownership transfers

## Contracts

| Contract | Description |
|----------|-------------|
| `src/BulkRegistration.sol` | Batch commit, register, and view functions for ENS names |
| `src/IETHRegistrarController.sol` | Interface for the wrapped ETHRegistrarController |
| `src/GrailsSubscription.sol` | Subscription management — subscribe, upgrade, and query |
| `src/GrailsPricing.sol` | USD-based tier pricing with Chainlink oracle integration |
| `src/IGrailsPricing.sol` | Interface for the pricing contract |
| `script/Deploy.s.sol` | Deployment script for BulkRegistration (mainnet + sepolia) |
| `script/DeploySubscription.s.sol` | Deployment script for GrailsPricing + GrailsSubscription |

## Usage

### Setup

```bash
git clone <repo-url>
cd contracts
forge install
cp .env.example .env
# Fill in MAINNET_RPC_URL, SEPOLIA_RPC_URL, ETHERSCAN_API_KEY
```

### Build

```bash
forge build
```

### Test

Unit tests run without a fork. Fork tests (registration and subscription oracle integration) require a mainnet RPC:

```bash
# Unit tests only
forge test -vvv

# Including fork tests
forge test --fork-url $MAINNET_RPC_URL -vvv
```

### Deploy BulkRegistration

```bash
REFERRER=0x000000000000000000000000<your-address> \
forge script script/Deploy.s.sol --rpc-url $MAINNET_RPC_URL --broadcast --verify
```

### Deploy GrailsSubscription

```bash
DEPLOYER=0x<owner-address> \
forge script script/DeploySubscription.s.sol --rpc-url $MAINNET_RPC_URL --broadcast --verify
```

## Bulk Registration Flow

1. **Check availability** — call `available(names)` to verify names are open
2. **Get pricing** — call `totalPrice(names, duration)` for the required ETH
3. **Commit** — call `makeCommitments(...)` then `multiCommit(commitments)`
4. **Wait** — wait at least 60 seconds for the commitment to mature
5. **Register** — call `multiRegister{value: totalPrice}(...)` with sufficient ETH; excess is refunded automatically

## Subscription Flow

1. **Check price** — call `getPrice(tierId, durationDays)` to get the required ETH for a tier and duration
2. **Subscribe** — call `subscribe{value: cost}(tierId, durationDays)` to start a subscription (replaces any existing subscription from the current timestamp)
3. **Check status** — call `getSubscription(address)` to view expiry timestamp, or read `subscriptions(address)` for both expiry and tier ID
4. **Upgrade** — call `upgrade(newTierId, extraDays)` to move to a higher tier; remaining time is converted proportionally based on the tier price ratio, and `extraDays` can be purchased in the same transaction
5. **Preview upgrade** — call `previewUpgrade(address, newTierId)` to see the projected expiry before committing
