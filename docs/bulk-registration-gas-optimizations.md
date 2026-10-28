# BulkRegistration Gas Optimizations

## Summary

Reduced per-name gas in `BulkRegistration.multiRegister` by **~17.1k gas (~7.4%)** across all batch sizes. Measured on mainnet fork at `test/BulkRegistration.gas.t.sol` via the `vm.startSnapshotGas` / `vm.stopSnapshotGas` cheatcode pair, with results written to `snapshots/multiRegister.json` for branch-to-branch diffing.

| Batch | Baseline (main) | Optimized | Δ total | Δ per name |
|------:|----------------:|----------:|--------:|-----------:|
|    10 |       2,376,575 | 2,206,085 |  -170,490 |     -17,049 |
|    25 |       5,854,318 | 5,427,724 |  -426,594 |     -17,064 |
|    50 |      11,652,197 | 10,798,305 |  -853,892 |     -17,078 |
|    75 |      17,452,130 | 16,170,367 | -1,281,763 |    -17,090 |
|   100 |      23,254,116 | 21,543,906 | -1,710,210 |    -17,102 |

At a 36M block gas limit this raises the practical batch ceiling from ~149 to ~161 names (100% block fill) and from ~119 to ~128 at 80% fill.

## Optimizations

### 1. Pre-computed prices passed in as a parameter (biggest win)

**Change:** `multiRegister` now takes `uint256[] calldata prices` alongside `durations`. Callers fetch prices via the existing view `rentPrices()` before submitting.

**Why it saves gas:** Previously `multiRegister` called `_rentPrice(name, duration)` per name to determine how much ETH to forward to the controller. The controller then re-queried its own price oracle inside `register()` to validate `msg.value`. That's two price-oracle round-trips per name for work whose result the controller discards. By accepting the price as an input, we eliminate the wrapper's query entirely; the controller still validates internally, and if the caller underpays the controller reverts (safe), while overpayment is refunded back (see #4 below).

**Tradeoff — breaking API change:** The `prices` parameter is new. Callers/SDKs must pre-fetch prices. Price fetching is cheap off-chain (`eth_call`) and was already available via `rentPrices()`, so the integration cost is low.

### 2. Cache `keccak256(bytes(label))` once per iteration

**Change:** The label hash is computed once at the top of each loop iteration and threaded into both `_enrichData` (where it forms the namehash for `setAddr`) and the `NameRegistered` event.

**Why it saves gas:** Previously the label was hashed **three times** per name: once inside `_enrichData` to build the namehash, once in the event emit, and once again inside the controller's `register()`. We can't skip the controller's hash, but we can collapse our two into one.

Applied identically in `makeCommitments` so commitment hashes remain bit-for-bit identical to those produced at registration time. (The controller computes `commitment = keccak256(abi.encode(registration))` — any drift between commit-time and register-time inputs would trigger `CommitmentNotFound`.)

### 3. Fast path in `_enrichData` for empty caller data

**Change:** When `originalData.length == 0` (the common case — a caller that just wants `setAddr` prepended), `_enrichData` allocates a length-1 array with the `setAddr` entry and returns immediately, skipping the copy loop.

**Why it saves gas:** The original code always ran a copy loop `for (i = 0; i < originalData.length; i++) enriched[i + 1] = originalData[i]` even when there was nothing to copy. Skipping the loop saves ~200–500 gas per name in the empty-data case.

### 4. Added `receive() external payable`

**Change:** Added an empty `receive()` to `BulkRegistration`.

**Why it's necessary (correctness, not just gas):** The underlying controller refunds over-payment mid-loop via `payable(msg.sender).transfer(msg.value - totalPrice)`. If a caller-supplied `prices[i]` ever exceeds the controller's true rent (e.g. a stale oracle quote from a prior `eth_call`), that refund lands back on `BulkRegistration`. Without `receive()` the refund reverts, and the whole batch with it.

The contract sweeps its entire balance back to `msg.sender` at the end of `multiRegister`, so both the caller's overpayment and any controller mid-loop refund are forwarded together in one call.

### 5. Extracted `_registerOne` internal helper

**Change:** The per-name work (keccak, struct construction, `register` call, event emit) lives in an internal helper called once per iteration.

**Why:** Initially a compile-time fix — `multiRegister` has 8 parameters, and adding two more loop locals (`name`, `labelHash`, `cost`) pushed the Yul IR pipeline into "stack too deep" territory. Extracting to a helper gives each iteration a fresh stack frame and makes the caller loop trivially readable as a side effect.

## Measured and rejected

Two candidate optimizations were tried and reverted based on measurement.

### Manual `unchecked { ++i; }` + `.length` caching

```solidity
// The classic "gas-optimized" loop:
uint256 len = names.length;
for (uint256 i; i < len;) {
    _registerOne(...);
    unchecked { ++i; }
}
```

Swapping the idiomatic `for (uint256 i = 0; i < names.length; i++)` for this form measured **~176 gas per name worse** on the 100-name batch under `solc 0.8.28` with `via_ir = true`. The Yul optimizer already proves the loop counter cannot overflow and elides the checks; the "manual" form confuses it. Reverted — the idiomatic form is faster here.

### Refund via tracked `totalSpent` instead of `address(this).balance`

```solidity
// Proposed:
uint256 totalSpent;  // summed in the loop
uint256 refund = msg.value - totalSpent;
```

This was rejected for correctness, not gas. If the controller refunds mid-loop (see #4) because a `prices[i]` exceeded the true rent, that refund lands on the contract *after* we've already tracked `totalSpent` based on what we sent, not what the controller kept. Tracking `totalSpent` would strand the controller's refund in the contract. Using `address(this).balance` is the correct final-state accounting. The gas cost of the `SELFBALANCE` opcode is ~5 gas — not worth trading correctness for.

## How to measure

The gas benchmark lives at `test/BulkRegistration.gas.t.sol`. It runs against a mainnet fork (requires `MAINNET_RPC_URL`) and captures `multiRegister` gas via two mechanisms in parallel:

1. **`gasleft()` bracket** — feeds the `console.log` summary for immediate feedback. This excludes cheatcode overhead and is the "truer" execution cost.
2. **`vm.startSnapshotGas` / `vm.stopSnapshotGas`** — writes `snapshots/multiRegister.json` for cross-branch diffing. Slightly higher than the `gasleft()` number because the cheatcode itself contributes to the measurement, but consistent across branches so deltas are clean.

Run:

```bash
forge test --match-contract BulkRegistrationGasTest -vv
# console output shows per-batch numbers
# snapshots/multiRegister.json is updated

git diff snapshots/multiRegister.json  # cross-branch comparison
```

## Files changed

- `src/BulkRegistration.sol` — all five contract-level changes.
- `test/BulkRegistration.t.sol` — updated call sites to supply the new `prices` argument; added `test_multiRegister_overStatedPrice_refundsFully` covering the stale-oracle refund path.
- `test/BulkRegistration.gas.t.sol` — cheatcode-based gas capture into `snapshots/multiRegister.json`.
- `snapshots/multiRegister.json` — current per-batch `multiRegister` gas, tracked in git for branch comparison.
