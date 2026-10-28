# GrailsETHRouter

Pay for ENSv2 bulk registrations and renewals with ETH. ENSv2 only takes ERC20s (USDC, DAI), so the
router buys exactly the USDC a batch costs from Uniswap v4 and hands it to `BulkRegistrationV2`.

Source: `src/GrailsETHRouter.sol`. Tests: `test/GrailsETHRouter.t.sol` (Sepolia fork),
`test/GrailsETHRouter.mainnet.t.sol` (mainnet fork, real pool, gas).

## How a call works

1. `_buyUSDC`: checks `deadline`, then `PoolManager.unlock`. In `unlockCallback` it runs an
   exact-output swap (ETH in, exactly `usdcAmount` USDC out) on one fixed pool, pays the ETH with
   `settle{value}` and takes the USDC.
2. Calls `BULK.multiRegister` / `BULK.multiRenew` with `USDC` and `usdcAmount`. The bulk contract
   refunds failed names' USDC to the router.
3. `_refund`: sends the router's whole USDC and ETH balance to `refundTo` (or `msg.sender`) and
   emits `PaidWithETH(payer, ethSpent, usdcBought, usdcRefunded)`.

The pool is fixed at deploy: native ETH / USDC, fee 500 (0.05%), tick spacing 10, **no hook**. The
constructor reverts if the pool isn't initialized. There is no admin, no `receive()`, and no balance
between transactions. If liquidity moves to another pool, deploy a new router.

Commitments still go through `BULK.makeCommitments` + `BULK.multiCommit`. ENSv2 commitments bind
the owner, not the caller, so the router can register them.

## Client flow

1. Get `usdcAmount`: `total` from `BULK.renewQuote(labels, durations, USDC)` (keep `v1Bitmap`) or
   `BULK.registerQuote(labels, durations, USDC)`.
2. Get the ETH cost: V4Quoter `quoteExactOutputSingle({poolKey: router.poolKey(), zeroForOne: true,
   exactAmount: usdcAmount, hookData: ""})` → `amountIn`. It's not a view; call it with `eth_call`.
3. Send `msg.value = amountIn * (1 + headroom)` (0.3–0.5% suggested) with `deadline` a few minutes
   ahead. Re-quote right before signing.
4. `multiRenewWithETH(labels, durations, v1Bitmap, usdcAmount, deadline, refundTo)` or
   `multiRegisterWithETH(labels, owner, durations, secret, subregistry, resolver, usdcAmount, deadline, refundTo)`.

The user pays exactly the swap cost. Unused ETH comes back as ETH. **Failed names come back as
USDC** (not swapped back to ETH), so say so in the UI.

## Risks for users

- **MEV.** A sandwich can raise the price up to `msg.value`, so the headroom is the most a user can
  lose. Keep it tight and suggest a private RPC (Flashbots Protect, MEV Blocker).
- **Reverts, not losses:** price moved past the headroom (`InsufficientETH`), `DeadlineExpired`,
  pool can't fill (`InsufficientLiquidity`), `refundTo` rejects ETH (`ETHRefundFailed`), USDC
  blacklist, or ENS removing USDC / pausing.
- **Stray balances.** ETH or USDC sent to the router by mistake is passed to the next caller.

## Addresses

|                 | Mainnet | Sepolia |
|-----------------|---------|---------|
| PoolManager     | `0x000000000004444c5dc75cB358380D2e3dE08A90` | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` |
| V4Quoter        | `0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203` | `0x61B3f2011A92d183C7dbaDBdA940a7555Ccf9227` |
| BulkRegistrationV2 | `0x438edcB58703dfB2e1D4Bb5E54a280E75A95ad90` | `0x3C549e0FFdD3951afB95B7be97bf4D844d8C3244` |
| USDC            | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | `0x240b0316Df57887DBBE58b586508b19e633a14aa` (MockUSDC) |
| ETH/USDC pool id (fee 500, ts 10, no hook) | `0x21c67e77068de97969ba93d4aab21826d33ca12bb9f565d8496e8fda8a82ca27` | `0x9da8ca8ce50c78b62c6b3b44227ce13267b64f79bdfd1ee4b12678e2017022cc` |
| GrailsETHRouter | `0x83827712Df81AF5A85A532a6Bf08c3F74d1fc707` (2026-10-28) | `0x9aF326d7ab5429744db5d7EcA6545BEC97490F3b` (2026-10-27) |

Mainnet pool choice (2026-10-27): the 0.05% pool beats 0.01% on depth, and beats 0.3% on fee for
typical batch sizes (well under $10k). The 0.3% pool has more in-range liquidity, so revisit if
very large batches become common.

## Gas (mainnet fork)

Renewing 2 names (one per renewer): `BULK.multiRenew` in USDC 245k, `multiRenewWithETH` 370k, so the
router adds about **124k** (swap, settle/take, refunds). Snapshot: `snapshots/ethRouter.json`.

## Sepolia

ENS's MockUSDC has no Uniswap liquidity, so create a pool first (MockUSDC has a public `mint`).

Forge simulates gas with its local EVM rules, and Sepolia charges roughly 2–2.6x more for new
storage slots and ~7x more for deploying contracts, so forge's gas limits run out (seen
2026-10-27). Pad them; unused gas isn't charged. Set the flags on their own line: as a prefix on
the same command, `$SEPOLIA_FLAGS` expands before it's set and silently becomes empty.

```bash
SEPOLIA_FLAGS="--slow --gas-estimate-multiplier 500"

# 1. Create + fund the ETH/MockUSDC 0.05% pool (default 0.3 ETH at 2500 USDC/ETH)
SENDER=0x... forge script script/SetupSepoliaPool.s.sol --rpc-url sepolia --account <keystore> --broadcast $SEPOLIA_FLAGS

# 2. Deploy the router
# Contract creation is repriced even harder (node: ~14M gas vs forge's ~2M), so use 750. Don't go
# above ~800: since Fusaka a transaction can't use more than 16,777,216 gas.
DEPLOYER=0x... forge script script/DeployETHRouter.s.sol --rpc-url sepolia --account <keystore> --broadcast --slow --gas-estimate-multiplier 750 --verify

# 3. Smoke test (commit, wait 60s, then pay with ETH)
export SENDER=0x... ROUTER=0x... LABELS=name1,name2 SECRET=0x...
forge script script/BulkV2Smoke.s.sol --sig "commit()" --rpc-url sepolia --account <keystore> --broadcast $SEPOLIA_FLAGS
forge script script/BulkV2Smoke.s.sol --sig "registerETH()" --rpc-url sepolia --account <keystore> --broadcast $SEPOLIA_FLAGS
forge script script/BulkV2Smoke.s.sol --sig "renewETH()" --rpc-url sepolia --account <keystore> --broadcast $SEPOLIA_FLAGS
```

Nobody arbitrages the Sepolia pool, so its price drifts up a little with every test purchase.
The owner (`SENDER`) must be able to receive ERC1155 tokens. Wallets with EIP-7702 delegated code
may not be, and registration then fails for that name (with a USDC refund).
