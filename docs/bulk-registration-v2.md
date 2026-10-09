# BulkRegistrationV2 (ENSv2)

Batch registration and renewal of `.eth` names against the ENSv2 `ETHRegistrar` / `ETHRenewerV1`.
Source: `src/BulkRegistrationV2.sol`. Tests: `test/BulkRegistrationV2.t.sol` (Sepolia fork),
`test/BulkRegistrationV2.gas.t.sol`.

## What's different from v1

- **Payment is ERC20 (USDC, DAI), not ETH.** The registrar pulls each name's exact price from this
  contract. This contract pulls `maxAmount` from the caller once and refunds the remainder.
- **No per-name `prices[]`.** Pass one `maxAmount` (the `total` from a quote). The base price is
  fixed and the premium only decays, so the quote never undershoots unless ENS changes the oracle.
- **Two renewers.** `REGISTERED` names renew via `ETHRegistrar`; `RESERVED` (pre-migrated,
  unmigrated v1) names renew via `ETHRenewerV1`. `renewQuote` returns a `v1Bitmap` that routes each name.
- **Failures don't revert the batch.** Each failed name is skipped, its share is refunded, and it is
  reported (see below). If an inner call runs out of gas, the whole batch reverts with `InsufficientGas`.
- **No resolver records, no reverse record, no own success event.** Records are set by the client on
  the user's resolver. Successes are the registrar's `NameRegistered` / `NameRenewed`, which carry
  the indexed `referrer`.

## Client flow

### Register

1. `registerQuote(labels, durations, token)` → `(prices, total)`. `prices[i] == 0` means the name
   isn't registrable (taken, invalid, duration < `MIN_REGISTER_DURATION`, unsupported token).
2. `makeCommitments(labels, owner, durations, secret, subregistry, resolver)` → `multiCommit(commitments)`.
3. Wait at least `MIN_COMMITMENT_AGE` (60s), and register before `MAX_COMMITMENT_AGE` (1 day).
4. Either `token.approve(bulk, total)` + `multiRegister(..., token, total)`, or (USDC) sign an EIP-2612
   permit for `value = total, spender = bulk` and call `multiRegisterWithPermit(..., token, total, permit)`.
5. The return value is `tokenIds[]` with `0` for failed names. On-chain, read `NameRegistrationFailed(index, label, reason)`.

The `owner` must be able to receive ERC1155 tokens (an EOA, or a contract implementing `onERC1155Received`).
Otherwise that name fails.

### Renew

1. `renewQuote(labels, durations, token)` → `(prices, total, v1Bitmap)`. `prices[i] == 0` means not renewable.
2. `approve` + `multiRenew(labels, durations, v1Bitmap, token, total)`, or `multiRenewWithPermit(...)`.
3. The return value is `bool[] renewed`. On-chain, read `NameRenewalFailed(index, label, reason)`.

An empty `v1Bitmap` routes everything to `ETHRegistrar`.

## Migration timing

- ENS migration phase 3 freezes v1 registrations, so the v1 `BulkRegistration` / `BulkRenewalWithReferral` stop working there.
- From phase 4, `RESERVED` names renew via `ETHRenewerV1`, so bulk renewal is usable from then on.
- From phase 6, `ETHRegistrar` has registry roles, so registration and `REGISTERED` renewals open.

On Sepolia's current deployment phase 6 is done, but `ETHRenewerV1` is not yet a v1 `BaseRegistrar`
controller (phase 4). The fork tests simulate phase 4 in `setUp`.

## Gas (Sepolia fork, MockUSDC, 10-char names)

| Batch | multiRegister | per name | multiRenew (v2) | per name |
|------:|--------------:|---------:|----------------:|---------:|
|    10 |     1,629,952 |  162,995 |         369,482 |   36,948 |
|    50 |     7,918,545 |  158,370 |       1,703,031 |   34,060 |
|   100 |    15,780,342 |  157,803 |       3,371,452 |   33,714 |

Overhead compared with calling `ETHRegistrar` in a loop is roughly 0–6k gas per name, within measurement
noise of the in-test loop. A bulk transaction saves the 21k intrinsic cost per name compared with separate
transactions. Mainnet USDC (a FiatToken proxy) costs more per `transferFrom` than the mock, and
`ETHRenewerV1` renewals also extend the v1 `BaseRegistrar`, so expect higher absolute numbers there.

## Deploy

```sh
DEPLOYER=0x... REFERRER=0x000...<addr> forge script script/DeployV2.s.sol --rpc-url sepolia --broadcast --verify
# mainnet also needs ETH_REGISTRAR_V2 and ETH_RENEWER_V1 (no published addresses yet)
```

The constructor pre-approves USDC and DAI. If ENS adds a payment token later, anyone can call `approveToken(token)`.
