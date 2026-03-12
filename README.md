# Grails Contracts

Solidity contracts for [Grails](https://grails.wtf): batch ENS `.eth` name registration and Grails PRO subscriptions. Built with [Foundry](https://book.getfoundry.sh/).

## Features

### Bulk Registration
- **Batch registration** — register multiple `.eth` names in one transaction
- **Mixed-length support** — no same-price restriction; each name is priced individually
- **Referral tracking** — emits `NameRegistered` events with an immutable referrer
- **Automatic refunds** — excess ETH is returned in the same transaction
- **Batch utilities** — bulk availability checks, price quotes, commitment generation

### Subscriptions
- **Pay-per-day subscription** — subscribe to Grails PRO for any number of days
- **Extend active subscriptions** — additional days stack on current expiry
- **Owner-controlled pricing** — contract owner can update the daily rate
- **Owner withdrawal** — owner can withdraw collected funds
- **Ownable2Step** — safe two-step ownership transfers

## Contracts

| Contract | Description |
|----------|-------------|
| `src/BulkRegistration.sol` | Batch commit, register, and view functions for ENS names |
| `src/IETHRegistrarController.sol` | Interface for the wrapped ETHRegistrarController |
| `src/GrailsSubscription.sol` | Subscription contract for Grails PRO tier |
| `script/Deploy.s.sol` | Deployment script for BulkRegistration (mainnet + sepolia) |
| `script/DeploySubscription.s.sol` | Deployment script for GrailsSubscription |

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

Tests run against a mainnet fork (both registration and subscription suites):

```bash
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

1. **Check price** — read `pricePerDay()` for the current daily rate
2. **Subscribe** — call `subscribe{value: pricePerDay * days}(durationDays)`
3. **Check status** — call `getSubscription(address)` to view expiry timestamp
4. **Extend** — call `subscribe()` again; additional days extend from current expiry if still active
