// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Vault} from "../../src/Vault.sol";
import {IVault} from "../../src/interfaces/IVault.sol";
import {IPoolManager} from "../../src/interfaces/IPoolManager.sol";
import {IHooks} from "../../src/interfaces/IHooks.sol";
import {Currency} from "../../src/types/Currency.sol";
import {PoolKey} from "../../src/types/PoolKey.sol";
import {BinPoolManager} from "../../src/pool-bin/BinPoolManager.sol";
import {IBinPoolManager} from "../../src/pool-bin/interfaces/IBinPoolManager.sol";
import {BinPoolParametersHelper} from "../../src/pool-bin/libraries/BinPoolParametersHelper.sol";
import {BinPool} from "../../src/pool-bin/libraries/BinPool.sol";
import {BinSwapHelper} from "./helpers/BinSwapHelper.sol";
import {BinLiquidityHelper} from "./helpers/BinLiquidityHelper.sol";
import {BinTestHelper} from "./helpers/BinTestHelper.sol";

contract BinPoolManagerHandler is BinTestHelper {
    uint256 public constant INITIAL_BALANCE = 1e30;

    Vault public vault;
    BinPoolManager public poolManager;
    MockERC20 public token0;
    MockERC20 public token1;
    PoolKey public key;
    BinSwapHelper public binSwapHelper;
    BinLiquidityHelper public binLiquidityHelper;
    address public feeRecipient;

    uint24[] public mintedBins;

    constructor(
        Vault _vault,
        BinPoolManager _poolManager,
        MockERC20 _token0,
        MockERC20 _token1,
        BinSwapHelper _binSwapHelper,
        BinLiquidityHelper _binLiquidityHelper,
        PoolKey memory _key
    ) {
        vault = _vault;
        poolManager = _poolManager;
        token0 = _token0;
        token1 = _token1;
        key = _key;
        binSwapHelper = _binSwapHelper;
        binLiquidityHelper = _binLiquidityHelper;
        feeRecipient = makeAddr("protocolFeeRecipient");

        _token0.mint(address(this), INITIAL_BALANCE);
        _token1.mint(address(this), INITIAL_BALANCE);
        _token0.approve(address(_binSwapHelper), type(uint256).max);
        _token1.approve(address(_binSwapHelper), type(uint256).max);
        _token0.approve(address(_binLiquidityHelper), type(uint256).max);
        _token1.approve(address(_binLiquidityHelper), type(uint256).max);
    }

    function addLiquidity(uint256 binSeed, uint256 amount0, uint256 amount1) public {
        // ID_ONE (2**23) does not fit int24, so the offset is applied in unsigned arithmetic
        uint24 binId = uint24(ID_ONE + (binSeed % 41) - 20);
        assert(binId > 0);

        (uint24 activeId,,) = poolManager.getSlot0(key.toId());
        // side bins only take one token; supplying the other trips CompositionFactorFlawed
        if (binId < activeId) {
            amount0 = 0;
        } else if (binId > activeId) {
            amount1 = 0;
        }

        amount0 = bound(amount0, 0, 1e18);
        amount1 = bound(amount1, 0, 1e18);
        // dust below 1e6 rounds to zero shares or zero amounts out on a later burn
        if (amount0 != 0) amount0 = bound(amount0, 1e6, 1e18);
        if (amount1 != 0) amount1 = bound(amount1, 1e6, 1e18);
        if (amount0 == 0 && amount1 == 0) return;

        IBinPoolManager.MintParams memory params = _getSingleBinMintParams(binId, amount0, amount1);
        binLiquidityHelper.mint(key, params, "");

        for (uint256 i; i < mintedBins.length; i++) {
            if (mintedBins[i] == binId) return;
        }
        mintedBins.push(binId);
    }

    function removeLiquidity(uint256 binSeed, uint256 sharePct) public {
        if (mintedBins.length == 0) return;

        uint24 binId = mintedBins[bound(binSeed, 0, mintedBins.length - 1)];
        uint256 share = poolManager.getPosition(key.toId(), address(this), binId, 0).share;
        if (share == 0) return;

        sharePct = bound(sharePct, 1, 100);
        IBinPoolManager.BurnParams memory params =
            _getSingleBinBurnLiquidityParams(key, poolManager, binId, address(this), sharePct);

        try binLiquidityHelper.burn(key, params, "") {}
        catch (bytes memory reason) {
            // expected only when swaps drained the bin to dust; anything else is a real failure
            bytes4 selector = bytes4(reason);
            if (
                selector != BinPool.BinPool__ZeroAmountsOut.selector
                    && selector != BinPool.BinPool__BurnZeroAmount.selector
            ) {
                assembly ("memory-safe") {
                    revert(add(reason, 0x20), mload(reason))
                }
            }
        }
    }

    function swap(uint256 seed, uint256 amount) public {
        bool swapForY = seed % 2 == 0;
        amount = bound(amount, 1e6, 1e18);
        int128 signedAmount = int128(int256(amount));
        int128 amountSpecified = seed % 4 < 2 ? -signedAmount : signedAmount;
        BinSwapHelper.TestSettings memory testSettings =
            BinSwapHelper.TestSettings({withdrawTokens: true, settleUsingTransfer: true});

        try binSwapHelper.swap(key, swapForY, amountSpecified, testSettings, "") {}
        catch (bytes memory reason) {
            // expected only when the swap walks past the last funded bin; anything else is a real failure
            bytes4 selector = bytes4(reason);
            if (
                selector != BinPool.BinPool__OutOfLiquidity.selector
                    && selector != BinPool.BinPool__InsufficientAmountUnSpecified.selector
            ) {
                assembly ("memory-safe") {
                    revert(add(reason, 0x20), mload(reason))
                }
            }
        }
    }
}

contract BinPoolManagerInvariant is Test {
    using BinPoolParametersHelper for bytes32;

    uint24 internal constant ID_ONE = 2 ** 23;

    Vault public vault;
    BinPoolManager public poolManager;
    MockERC20 public token0;
    MockERC20 public token1;
    PoolKey public key;
    BinPoolManagerHandler public handler;

    function setUp() public {
        vault = new Vault();
        poolManager = new BinPoolManager(IVault(address(vault)));
        vault.registerApp(address(poolManager));

        token0 = new MockERC20("TestA", "A", 18);
        token1 = new MockERC20("TestB", "B", 18);
        (token0, token1) = address(token0) < address(token1) ? (token0, token1) : (token1, token0);

        BinSwapHelper binSwapHelper = new BinSwapHelper(IBinPoolManager(address(poolManager)), IVault(address(vault)));
        BinLiquidityHelper binLiquidityHelper =
            new BinLiquidityHelper(IBinPoolManager(address(poolManager)), IVault(address(vault)));

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(address(poolManager)),
            fee: uint24(3000),
            parameters: bytes32(0).setBinStep(10)
        });
        poolManager.initialize(key, ID_ONE);

        handler = new BinPoolManagerHandler(vault, poolManager, token0, token1, binSwapHelper, binLiquidityHelper, key);

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](3);
        // keccak because BinTestHelper declares addLiquidity/removeLiquidity overloads
        selectors[0] = bytes4(keccak256("addLiquidity(uint256,uint256,uint256)"));
        selectors[1] = bytes4(keccak256("removeLiquidity(uint256,uint256)"));
        selectors[2] = bytes4(keccak256("swap(uint256,uint256)"));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_TokenConservation() public view {
        uint256 total = handler.INITIAL_BALANCE();
        // handler and vault are the only token holders; feeRecipient stays empty (protocol fee is 0)
        assertEq(
            token0.balanceOf(address(handler)) + token0.balanceOf(address(vault))
                + token0.balanceOf(handler.feeRecipient()),
            total
        );
        assertEq(
            token1.balanceOf(address(handler)) + token1.balanceOf(address(vault))
                + token1.balanceOf(handler.feeRecipient()),
            total
        );
    }

    function invariant_VaultSolvent() public view {
        assertGe(
            token0.balanceOf(address(vault)), vault.reservesOfApp(address(poolManager), Currency.wrap(address(token0)))
        );
        assertGe(
            token1.balanceOf(address(vault)), vault.reservesOfApp(address(poolManager), Currency.wrap(address(token1)))
        );
    }

    function invariant_LockCleared() public view {
        assertEq(vault.getLocker(), address(0));
        assertEq(vault.getUnsettledDeltasCount(), 0);
        assertEq(vault.getAppDeficitCount(), 0);
    }

    function invariant_PoolInitialized() public view {
        (uint24 activeId,,) = poolManager.getSlot0(key.toId());
        assertGt(activeId, 0);
    }
}
