// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {ENS} from "ens-contracts/registry/ENS.sol";
import {ReverseClaimer} from "ens-contracts/reverseRegistrar/ReverseClaimer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BulkRegistrationV2} from "./BulkRegistrationV2.sol";

/**
 * @custom:benediction DEVS BENEDICAT ET PROTEGAT CONTRACTVM MEVM
 * @title GrailsETHRouter
 * @author 0xthrpw
 * @notice Pay for ENSv2 bulk registrations and renewals with ETH.
 *
 *         Each call buys exactly the USDC the batch costs from one fixed, hook-free Uniswap v4
 *         ETH/USDC pool (an exact-output swap), passes it to `BulkRegistrationV2`, and sends the
 *         leftovers back: unused ETH, plus USDC for any names that failed.
 *
 *         The caller quotes off-chain: `BULK.renewQuote` / `BULK.registerQuote` for `usdcAmount`,
 *         then the v4 Quoter's `quoteExactOutputSingle` for the ETH cost, plus a little headroom
 *         sent as `msg.value`. The most a swap can cost is `msg.value`, so the headroom is also
 *         the most a sandwich can take.
 *
 *         The router holds no funds between transactions and has no admin. Commit through
 *         `BULK.multiCommit`, since commitments don't depend on the caller.
 */
contract GrailsETHRouter is IUnlockCallback, ReverseClaimer, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /**
     * @notice The Uniswap v4 PoolManager
     */
    IPoolManager public immutable POOL_MANAGER;

    /**
     * @notice The bulk registration contract that registers and renews with the USDC
     */
    BulkRegistrationV2 public immutable BULK;

    /**
     * @notice The stablecoin bought and paid to `BULK`
     */
    IERC20 public immutable USDC;

    /**
     * @notice LP fee of the ETH/USDC pool, in hundredths of a bip (500 = 0.05%)
     */
    uint24 public immutable POOL_FEE;

    /**
     * @notice Tick spacing of the ETH/USDC pool
     */
    int24 public immutable POOL_TICK_SPACING;

    /**
     * @notice Emitted once per call, after the batch and refunds
     * @param payer The caller
     * @param ethSpent ETH paid into the pool for the USDC
     * @param usdcBought USDC bought and passed to `BULK`
     * @param usdcRefunded USDC returned for failed names (and quote headroom)
     */
    event PaidWithETH(address indexed payer, uint256 ethSpent, uint256 usdcBought, uint256 usdcRefunded);

    /**
     * @notice Thrown when the call is mined after `deadline`
     */
    error DeadlineExpired();

    /**
     * @notice Thrown when `unlockCallback` is called by anything but the PoolManager
     */
    error NotPoolManager();

    /**
     * @notice Thrown at deploy when the pool has not been initialized
     */
    error PoolNotInitialized();

    /**
     * @notice Thrown when the swap needs more ETH than was sent
     * @param required ETH the swap needs
     * @param sent ETH sent with the call
     */
    error InsufficientETH(uint256 required, uint256 sent);

    /**
     * @notice Thrown when the pool could not fill the full USDC amount
     */
    error InsufficientLiquidity();

    /**
     * @notice Thrown when the ETH refund could not be delivered
     */
    error ETHRefundFailed();

    /**
     * @param poolManager The Uniswap v4 PoolManager
     * @param bulk The BulkRegistrationV2 contract
     * @param usdc The stablecoin `bulk` is paid in
     * @param poolFee LP fee of the native ETH/`usdc` pool (no hook)
     * @param poolTickSpacing Tick spacing of that pool
     * @param ens Address of the ENS registry (for reverse resolution)
     * @param owner Address to claim reverse ENS ownership for this contract
     */
    constructor(
        IPoolManager poolManager,
        BulkRegistrationV2 bulk,
        IERC20 usdc,
        uint24 poolFee,
        int24 poolTickSpacing,
        ENS ens,
        address owner
    ) ReverseClaimer(ens, owner) {
        POOL_MANAGER = poolManager;
        BULK = bulk;
        USDC = usdc;
        POOL_FEE = poolFee;
        POOL_TICK_SPACING = poolTickSpacing;

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey().toId());
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        // Safe for the same reason as in BulkRegistrationV2: no balance is held between calls
        usdc.forceApprove(address(bulk), type(uint256).max);
    }

    /**
     * @notice The ETH/USDC pool every swap goes through: native ETH, `USDC`, no hook
     */
    function poolKey() public view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(USDC)),
            fee: POOL_FEE,
            tickSpacing: POOL_TICK_SPACING,
            hooks: IHooks(address(0))
        });
    }

    // ------------------------------------------------------------------------------------
    // Writes
    // ------------------------------------------------------------------------------------

    /**
     * @notice Register multiple names, paying in ETH
     * @dev Same arguments as `BULK.multiRegister`, except the token is always `USDC`. Names must
     *      already be committed (`BULK.makeCommitments` + `BULK.multiCommit`) for `owner`.
     * @param usdcAmount USDC to buy and pass as `maxAmount`, e.g. `total` from `BULK.registerQuote`
     * @param deadline Latest block timestamp the call may be mined at
     * @param refundTo Receives unused ETH and refunded USDC; address(0) means msg.sender
     * @return tokenIds Registered token ID per name, 0 where registration failed
     */
    function multiRegisterWithETH(
        string[] calldata labels,
        address owner,
        uint64[] calldata durations,
        bytes32 secret,
        address subregistry,
        address resolver,
        uint256 usdcAmount,
        uint256 deadline,
        address refundTo
    ) external payable nonReentrant returns (uint256[] memory tokenIds) {
        uint256 ethSpent = _buyUSDC(usdcAmount, deadline);
        tokenIds = BULK.multiRegister(labels, owner, durations, secret, subregistry, resolver, USDC, usdcAmount);
        _refund(refundTo, ethSpent, usdcAmount);
    }

    /**
     * @notice Renew multiple names, paying in ETH
     * @dev Same arguments as `BULK.multiRenew`, except the token is always `USDC`.
     * @param usdcAmount USDC to buy and pass as `maxAmount`, e.g. `total` from `BULK.renewQuote`
     * @param deadline Latest block timestamp the call may be mined at
     * @param refundTo Receives unused ETH and refunded USDC; address(0) means msg.sender
     * @return renewed Per-name success flag
     */
    function multiRenewWithETH(
        string[] calldata labels,
        uint64[] calldata durations,
        uint256[] calldata v1Bitmap,
        uint256 usdcAmount,
        uint256 deadline,
        address refundTo
    ) external payable nonReentrant returns (bool[] memory renewed) {
        uint256 ethSpent = _buyUSDC(usdcAmount, deadline);
        renewed = BULK.multiRenew(labels, durations, v1Bitmap, USDC, usdcAmount);
        _refund(refundTo, ethSpent, usdcAmount);
    }

    /**
     * @notice Swap callback from the PoolManager. Buys exactly `usdcAmount` USDC with ETH.
     * @param data abi.encode(usdcAmount, ethAvailable)
     * @return abi.encode(ethSpent)
     */
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        (uint256 usdcAmount, uint256 ethAvailable) = abi.decode(data, (uint256, uint256));

        // Positive amountSpecified = exact output. ETH is currency0, so this is zeroForOne.
        BalanceDelta delta = POOL_MANAGER.swap(
            poolKey(),
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: SafeCast.toInt256(usdcAmount), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        // A swap that runs out of liquidity stops at the price limit and fills less
        if (uint256(int256(delta.amount1())) != usdcAmount) revert InsufficientLiquidity();

        uint256 ethSpent = uint256(-int256(delta.amount0()));
        if (ethSpent > ethAvailable) revert InsufficientETH(ethSpent, ethAvailable);

        POOL_MANAGER.settle{value: ethSpent}();
        POOL_MANAGER.take(Currency.wrap(address(USDC)), address(this), usdcAmount);
        return abi.encode(ethSpent);
    }

    // ------------------------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------------------------

    function _buyUSDC(uint256 usdcAmount, uint256 deadline) internal returns (uint256 ethSpent) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        return abi.decode(POOL_MANAGER.unlock(abi.encode(usdcAmount, msg.value)), (uint256));
    }

    /**
     * @dev Send this contract's whole USDC and ETH balance to `refundTo` (or msg.sender).
     *      Between calls both balances are zero, so this is exactly this call's leftovers.
     */
    function _refund(address refundTo, uint256 ethSpent, uint256 usdcBought) internal {
        address to = refundTo == address(0) ? msg.sender : refundTo;

        uint256 usdcRefund = USDC.balanceOf(address(this));
        if (usdcRefund > 0) USDC.safeTransfer(to, usdcRefund);

        uint256 ethRefund = address(this).balance;
        if (ethRefund > 0) {
            (bool ok,) = to.call{value: ethRefund}("");
            if (!ok) revert ETHRefundFailed();
        }

        emit PaidWithETH(msg.sender, ethSpent, usdcBought, usdcRefund);
    }
}
