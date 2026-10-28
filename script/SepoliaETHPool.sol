// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

interface IMintableERC20 {
    function mint(address to, uint256 amount) external;
}

/// @dev Minimal v4-periphery PositionManager interface
interface IPositionManagerMinimal {
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96) external payable returns (int24);
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
}

/// @dev Minimal v4-periphery V4Quoter interface. Not a view: it simulates the swap and reverts.
interface IV4QuoterMinimal {
    struct QuoteExactSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        bytes hookData;
    }

    function quoteExactOutputSingle(QuoteExactSingleParams memory params) external returns (uint256 amountIn, uint256 gasEstimate);
}

/// @dev Minimal Permit2 AllowanceTransfer interface
interface IPermit2Minimal {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/**
 * @dev Creates and funds a hook-free native ETH/MockUSDC Uniswap v4 pool on Sepolia, since ENS's
 *      MockUSDC has no Uniswap liquidity. Shared by script/SetupSepoliaPool.s.sol and the fork
 *      tests. Fee and tick spacing match the mainnet ETH/USDC 0.05% pool the router uses.
 */
abstract contract SepoliaETHPool {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager constant SEPOLIA_POOL_MANAGER = IPoolManager(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543);
    IPositionManagerMinimal constant SEPOLIA_POSITION_MANAGER = IPositionManagerMinimal(0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4);
    address constant SEPOLIA_V4_QUOTER = 0x61B3f2011A92d183C7dbaDBdA940a7555Ccf9227;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant SEPOLIA_MOCK_USDC = 0x240b0316Df57887DBBE58b586508b19e633a14aa;

    uint24 constant POOL_FEE = 500;
    int24 constant POOL_TICK_SPACING = 10;

    // PositionManager action codes (v4-periphery Actions.sol)
    uint8 constant MINT_POSITION = 0x02;
    uint8 constant SETTLE_PAIR = 0x0d;
    uint8 constant SWEEP = 0x14;
    // PositionManager's ActionConstants.MSG_SENDER
    address constant MSG_SENDER = address(1);

    function _sepoliaPoolKey() internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(SEPOLIA_MOCK_USDC),
            fee: POOL_FEE,
            tickSpacing: POOL_TICK_SPACING,
            hooks: IHooks(address(0))
        });
    }

    /// @dev sqrt(price) in Q64.96, where price is USDC base units (6 dp) per wei
    function _sqrtPriceX96(uint256 usdcPerEth) internal pure returns (uint160) {
        return uint160(Math.sqrt((usdcPerEth * 1e6 << 192) / 1e18));
    }

    /**
     * @dev Initialize the pool at `usdcPerEth` if it isn't yet, then add full-range liquidity
     *      worth `ethAmount` ETH plus the matching MockUSDC (minted, it has a public mint).
     *      `lp` must be the address making these calls (the broadcaster in a script, the test
     *      contract in a test). It receives the position NFT and any excess ETH.
     */
    function _seedSepoliaPool(address lp, uint256 usdcPerEth, uint256 ethAmount) internal returns (uint128 liquidity, uint256 usdcAmount) {
        PoolKey memory key = _sepoliaPoolKey();
        (uint160 sqrtPriceX96,,,) = SEPOLIA_POOL_MANAGER.getSlot0(key.toId());
        if (sqrtPriceX96 == 0) {
            sqrtPriceX96 = _sqrtPriceX96(usdcPerEth);
            SEPOLIA_POSITION_MANAGER.initializePool(key, sqrtPriceX96);
        }

        int24 tickLower = TickMath.minUsableTick(POOL_TICK_SPACING);
        int24 tickUpper = TickMath.maxUsableTick(POOL_TICK_SPACING);
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);

        liquidity = LiquidityAmounts.getLiquidityForAmount0(sqrtPriceX96, sqrtUpper, ethAmount);
        usdcAmount = LiquidityAmounts.getAmount1ForLiquidity(sqrtLower, sqrtPriceX96, liquidity) + 1;

        IMintableERC20(SEPOLIA_MOCK_USDC).mint(lp, usdcAmount);
        IERC20(SEPOLIA_MOCK_USDC).approve(PERMIT2, usdcAmount);
        IPermit2Minimal(PERMIT2)
            .approve(SEPOLIA_MOCK_USDC, address(SEPOLIA_POSITION_MANAGER), uint160(usdcAmount), uint48(block.timestamp + 1 hours));

        bytes memory actions = abi.encodePacked(MINT_POSITION, SETTLE_PAIR, SWEEP);
        bytes[] memory params = new bytes[](3);
        params[0] =
            abi.encode(key, tickLower, tickUpper, uint256(liquidity), uint128(ethAmount), uint128(usdcAmount), MSG_SENDER, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(key.currency0, MSG_SENDER);
        SEPOLIA_POSITION_MANAGER.modifyLiquidities{value: ethAmount}(abi.encode(actions, params), block.timestamp + 1 hours);
    }
}
