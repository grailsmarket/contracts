# ENS Bulk Registration

A smart contract for batch-registering ENS `.eth` names in a single transaction. Targets the current wrapped [ETHRegistrarController](https://etherscan.io/address/0x253553366Da8546fC250F225fe3d25d0C782303b) and supports mixed-length names (3, 4, 5+ chars) with different prices.

## Features

- **Batch registration** — register multiple `.eth` names in one transaction
- **Mixed-length support** — no same-price restriction; each name is priced individually
- **Referral tracking** — emits `NameRegistered` events with an immutable referrer
- **Automatic refunds** — excess ETH is returned in the same transaction
- **Batch utilities** — bulk availability checks, price quotes, commitment generation

## Contracts

| Contract | Description |
|----------|-------------|
| `src/BulkRegistration.sol` | Main contract with batch commit, register, and view functions |
| `src/IETHRegistrarController.sol` | Interface for the wrapped ETHRegistrarController |
| `script/Deploy.s.sol` | Deployment script (mainnet + sepolia) |

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

Tests run against a mainnet fork:

```bash
forge test --fork-url $MAINNET_RPC_URL -vvv
```

### Deploy

```bash
REFERRER=0x000000000000000000000000<your-address> \
forge script script/Deploy.s.sol --rpc-url $MAINNET_RPC_URL --broadcast --verify
```

## Registration Flow

1. **Check availability** — call `available(names)` to verify names are open
2. **Get pricing** — call `totalPrice(names, duration)` for the required ETH
3. **Commit** — call `makeCommitments(...)` then `multiCommit(commitments)`
4. **Wait** — wait at least 60 seconds for the commitment to mature
5. **Register** — call `multiRegister{value: totalPrice}(...)` with sufficient ETH; excess is refunded automatically
