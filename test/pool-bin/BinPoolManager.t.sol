// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {LPFeeLibrary} from "../../src/libraries/LPFeeLibrary.sol";
import {IVault} from "../../src/interfaces/IVault.sol";
import {IProtocolFees} from "../../src/interfaces/IProtocolFees.sol";
import {IPoolManager} from "../../src/interfaces/IPoolManager.sol";
import {IBinPoolManager} from "../../src/pool-bin/interfaces/IBinPoolManager.sol";
import {IProtocolFeeController} from "../../src/interfaces/IProtocolFeeController.sol";
import {Vault} from "../../src/Vault.sol";
import {Currency} from "../../src/types/Currency.sol";
import {PoolKey} from "../../src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "../../src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "../../src/types/BalanceDelta.sol";
import {BinPoolManager} from "../../src/pool-bin/BinPoolManager.sol";
import {MockBinHooks} from "../../src/test/pool-bin/MockBinHooks.sol";
import {MockFeeManagerHook} from "../../src/test/fee/MockFeeManagerHook.sol";
import {MockProtocolFeeController} from "../../src/test/fee/MockProtocolFeeController.sol";
import {BinPool} from "../../src/pool-bin/libraries/BinPool.sol";
import {LiquidityConfigurations} from "../../src/pool-bin/libraries/math/LiquidityConfigurations.sol";
import {PackedUint128Math} from "../../src/pool-bin/libraries/math/PackedUint128Math.sol";
import {SafeCast} from "../../src/pool-bin/libraries/math/SafeCast.sol";
import {BinPoolParametersHelper} from "../../src/pool-bin/libraries/BinPoolParametersHelper.sol";
import {Constants} from "../../src/pool-bin/libraries/Constants.sol";
import {IBinHooks} from "../../src/pool-bin/interfaces/IBinHooks.sol";
import {BinFeeManagerHook} from "./helpers/BinFeeManagerHook.sol";
import {IHooks} from "../../src/interfaces/IHooks.sol";
import {IBinHooks} from "../../src/pool-bin/interfaces/IBinHooks.sol";
import {BinSwapHelper} from "./helpers/BinSwapHelper.sol";
import {BinLiquidityHelper} from "./helpers/BinLiquidityHelper.sol";
import {BinDonateHelper} from "./helpers/BinDonateHelper.sol";
import {BinTestHelper} from "./helpers/BinTestHelper.sol";
import {BinNoOpTestHook} from "./helpers/BinNoOpTestHook.sol";
import {Hooks} from "../../src/libraries/Hooks.sol";

contract BinPoolManagerTest is Test, GasSnapshot, BinTestHelper {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using PackedUint128Math for bytes32;
    using PackedUint128Math for uint128;
    using BinPoolParametersHelper for bytes32;

    error PoolAlreadyInitialized();
    error PoolNotInitialized();
    error CurrenciesInitializedOutOfOrder();
    error BinStepTooSmall();
    error BinStepTooLarge();
    error MaxBinStepTooSmall(uint16 maxBinStep);

    event Initialize(
        PoolId indexed id,
        Currency indexed currency0,
        Currency indexed currency1,
        uint24 fee,
        uint16 binStep,
        IBinHooks hooks
    );
    event Mint(
        PoolId indexed id,
        address indexed sender,
        uint256[] ids,
        bytes32[] amounts,
        bytes32 compositionFee,
        bytes32 pFees
    );
    event Burn(PoolId indexed id, address indexed sender, uint256[] ids, bytes32[] amounts);
    event Swap(
        PoolId indexed id,
        address indexed sender,
        int128 amount0,
        int128 amount1,
        uint24 activeId,
        uint24 fee,
        uint24 pFees
    );
    event Donate(PoolId indexed id, address indexed sender, int128 amount0, int128 amount1, uint24 binId);
    event ProtocolFeeUpdated(PoolId indexed id, uint24 protocolFees);
    event SetMaxBinStep(uint16 maxBinStep);
    event DynamicLPFeeUpdated(PoolId indexed id, uint24 dynamicSwapFee);

    Vault public vault;
    BinPoolManager public poolManager;
    BinSwapHelper public binSwapHelper;
    BinLiquidityHelper public binLiquidityHelper;
    BinDonateHelper public binDonateHelper;

    uint24 activeId = 2 ** 23; // where token0 and token1 price is the same

    PoolKey key;
    bytes32 poolParam;
    MockERC20 token0;
    MockERC20 token1;
    Currency currency0;
    Currency currency1;

    function setUp() public {
        vault = new Vault();
        poolManager = new BinPoolManager(IVault(address(vault)), 500000);

        vault.registerPoolManager(address(poolManager));

        token0 = new MockERC20("TestA", "A", 18);
        token1 = new MockERC20("TestB", "B", 18);
        (token0, token1) = token0 < token1 ? (token0, token1) : (token1, token0);
        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));

        IBinPoolManager iBinPoolManager = IBinPoolManager(address(poolManager));
        IVault iVault = IVault(address(vault));

        binSwapHelper = new BinSwapHelper(iBinPoolManager, iVault);
        binLiquidityHelper = new BinLiquidityHelper(iBinPoolManager, iVault);
        binDonateHelper = new BinDonateHelper(iBinPoolManager, iVault);

        token0.approve(address(binSwapHelper), 1000 ether);
        token1.approve(address(binSwapHelper), 1000 ether);
        token0.approve(address(binLiquidityHelper), 1000 ether);
        token1.approve(address(binLiquidityHelper), 1000 ether);
        token0.approve(address(binDonateHelper), 1000 ether);
        token1.approve(address(binDonateHelper), 1000 ether);

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(address(poolManager)),
            fee: uint24(3000), // 3000 = 0.3%
            parameters: poolParam.setBinStep(10) // binStep
        });
    }

    function test_FuzzInitializePool(uint16 binStep) public {
        binStep = uint16(bound(binStep, poolManager.MIN_BIN_STEP(), poolManager.MAX_BIN_STEP()));

        uint16 bitMap = 0x0008; // after mint call
        MockBinHooks mockHooks = new MockBinHooks();
        mockHooks.setHooksRegistrationBitmap(bitMap);

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            // hooks: hook,
            hooks: IHooks(address(mockHooks)),
            poolManager: IPoolManager(address(poolManager)),
            fee: uint24(3000), // 3000 = 0.3%
            parameters: bytes32(uint256(bitMap)).setBinStep(binStep)
        });

        vm.expectEmit();
        emit Initialize(key.toId(), key.currency0, key.currency1, key.fee, binStep, IBinHooks(address(mockHooks)));

        poolManager.initialize(key, activeId, new bytes(0));
    }

    function testInitializeSamePool() public {
        poolManager.initialize(key, 10, new bytes(0));

        vm.expectRevert(PoolAlreadyInitialized.selector);
        poolManager.initialize(key, 10, new bytes(0));
    }

    function testInitializeDynamicFeeTooLarge(uint24 dynamicSwapFee) public {
        dynamicSwapFee = uint24(bound(dynamicSwapFee, LPFeeLibrary.TEN_PERCENT_FEE + 1, type(uint24).max));

        uint16 bitMap = 0x0040; // 0000 0000 0100 0000 (before swap call)
        BinFeeManagerHook binFeeManagerHook = new BinFeeManagerHook(poolManager);
        binFeeManagerHook.setHooksRegistrationBitmap(bitMap);

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(binFeeManagerHook)),
            poolManager: IPoolManager(address(poolManager)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG + uint24(3000), // 3000 = 0.3%
            parameters: bytes32(uint256(bitMap)).setBinStep(10)
        });

        binFeeManagerHook.setFee(dynamicSwapFee);

        vm.prank(address(binFeeManagerHook));
        vm.expectRevert(IProtocolFees.FeeTooLarge.selector);
        poolManager.updateDynamicLPFee(key, dynamicSwapFee);
    }

    function testInitializeSwapFeeTooLarge() public {
        uint24 swapFee = LPFeeLibrary.TEN_PERCENT_FEE + 1;

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(address(poolManager)),
            fee: swapFee,
            parameters: poolParam.setBinStep(1) // binStep
        });

        vm.expectRevert(IProtocolFees.FeeTooLarge.selector);
        poolManager.initialize(key, activeId, "");
    }

    function testInitializeInvalidBinStep() public {
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(address(poolManager)),
            fee: uint24(3000), // 3000 = 0.3%
            parameters: poolParam.setBinStep(poolManager.MIN_BIN_STEP() - 1) // binStep
        });

        vm.expectRevert(BinStepTooSmall.selector);
        poolManager.initialize(key, activeId, "");

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(address(poolManager)),
            fee: uint24(3000), // 3000 = 0.3%
            parameters: poolParam.setBinStep(poolManager.MAX_BIN_STEP() + 1) // binStep
        });

        vm.expectRevert(BinStepTooLarge.selector);
        poolManager.initialize(key, activeId, "");
    }

    function testInitialize_NoOpMissingBeforeCall() public {
        // 0000 0100 0000 0000 // only noOp
        uint16 bitMap = 0x0400;

        BinNoOpTestHook noOpHook = new BinNoOpTestHook();
        noOpHook.setHooksRegistrationBitmap(bitMap);

        key = PoolKey({
            currency0: Currency.wrap(makeAddr("token0")),
            currency1: Currency.wrap(makeAddr("token1")),
            hooks: IHooks(address(noOpHook)),
            poolManager: IPoolManager(address(poolManager)),
            fee: uint24(3000),
            parameters: bytes32(uint256(bitMap)).setBinStep(1)
        });

        // no op permission set, but no before call
        vm.expectRevert(Hooks.NoOpHookMissingBeforeCall.selector);
        poolManager.initialize(key, activeId, "");
    }

    function testNoOp_Gas() public {
        // 0000 0101 0101 0100 // noOp, beforeMint, beforeBurn, beforeSwap, beforeDonate
        uint16 bitMap = 0x0554;

        // pre-req create pool
        BinNoOpTestHook noOpHook = new BinNoOpTestHook();
        noOpHook.setHooksRegistrationBitmap(bitMap);
        key = PoolKey({
            currency0: Currency.wrap(makeAddr("token0")),
            currency1: Currency.wrap(makeAddr("token1")),
            hooks: IHooks(address(noOpHook)),
            poolManager: IPoolManager(address(poolManager)),
            fee: uint24(3000),
            parameters: bytes32(uint256(bitMap)).setBinStep(1)
        });

        snapStart("BinPoolManagerTest#testNoOpGas_Initialize");
        poolManager.initialize(key, activeId, "");
        snapEnd();

        BalanceDelta delta;

        // Action 1: mint, params doesn't matter for noOp
        IBinPoolManager.MintParams memory mintParams;
        snapStart("BinPoolManagerTest#testNoOpGas_Mint");
        delta = binLiquidityHelper.mint{value: 1 ether}(key, mintParams, "");
        snapEnd();
        assertTrue(delta == BalanceDeltaLibrary.MAXIMUM_DELTA);

        // Action 2: Burn, params doesn't matter for noOp
        IBinPoolManager.BurnParams memory burnParams;
        snapStart("BinPoolManagerTest#testNoOpGas_Burn");
        delta = binLiquidityHelper.burn(key, burnParams, "");
        snapEnd();
        assertTrue(delta == BalanceDeltaLibrary.MAXIMUM_DELTA);

        // Action 3: Swap
        BinSwapHelper.TestSettings memory testSettings;
        snapStart("BinPoolManagerTest#testNoOpGas_Swap");
        delta = binSwapHelper.swap(key, false, 1e17, testSettings, "");
        snapEnd();
        assertTrue(delta == BalanceDeltaLibrary.MAXIMUM_DELTA);

        // Action 4: Donate
        snapStart("BinPoolManagerTest#testNoOpGas_Donate");
        delta = binDonateHelper.donate(key, 10 ether, 10 ether, "");
        snapEnd();
        assertTrue(delta == BalanceDeltaLibrary.MAXIMUM_DELTA);
    }

    function testGasMintOneBin() public {
        poolManager.initialize(key, activeId, new bytes(0));

        token0.mint(address(this), 2 ether);
        token1.mint(address(this), 2 ether);
        IBinPoolManager.MintParams memory mintParams = _getSingleBinMintParams(activeId, 1 ether, 1 ether);

        uint256[] memory ids = new uint256[](1);
        bytes32[] memory amounts = new bytes32[](1);
        ids[0] = activeId;
        amounts[0] = uint128(1e18).encode(uint128(1e18));
        vm.expectEmit();
        bytes32 compositionFee = uint128(0).encode(uint128(0));
        bytes32 pFee = uint128(0).encode(uint128(0));
        emit Mint(key.toId(), address(binLiquidityHelper), ids, amounts, compositionFee, pFee);

        snapStart("BinPoolManagerTest#testGasMintOneBin-1");
        binLiquidityHelper.mint(key, mintParams, "");
        snapEnd();

        // mint on same pool again
        snapStart("BinPoolManagerTest#testGasMintOneBin-2");
        binLiquidityHelper.mint(key, mintParams, "");
        snapEnd();
    }

    function testGasMintNneBins() public {
        poolManager.initialize(key, activeId, new bytes(0));

        token0.mint(address(this), 10 ether);
        token1.mint(address(this), 10 ether);
        (IBinPoolManager.MintParams memory mintParams,) = _getMultipleBinMintParams(activeId, 2 ether, 2 ether, 5, 5);

        snapStart("BinPoolManagerTest#testGasMintNneBins-1");
        binLiquidityHelper.mint(key, mintParams, "");
        snapEnd();

        snapStart("BinPoolManagerTest#testGasMintNneBins-2");
        binLiquidityHelper.mint(key, mintParams, ""); // cheaper in gas as TreeMath initialized
        snapEnd();
    }

    function testMintNativeCurrency() public {
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(address(poolManager)),
            fee: uint24(3000), // 3000 = 0.3%
            parameters: poolParam.setBinStep(10) // binStep
        });
        poolManager.initialize(key, activeId, new bytes(0));

        token1.mint(address(this), 1 ether);
        IBinPoolManager.MintParams memory mintParams = _getSingleBinMintParams(activeId, 1 ether, 1 ether);

        uint256[] memory ids = new uint256[](1);
        bytes32[] memory amounts = new bytes32[](1);
        ids[0] = activeId;
        amounts[0] = uint128(1e18).encode(uint128(1e18));
        bytes32 compositionFee = uint128(0).encode(uint128(0));
        bytes32 pFee = uint128(0).encode(uint128(0));
        vm.expectEmit();
        emit Mint(key.toId(), address(binLiquidityHelper), ids, amounts, compositionFee, pFee);

        // 1 ether as add 1 ether in native currency
        snapStart("BinPoolManagerTest#testMintNativeCurrency");
        binLiquidityHelper.mint{value: 1 ether}(key, mintParams, "");
        snapEnd();
    }

    function testGasBurnOneBin() public {
        // initialize
        poolManager.initialize(key, activeId, new bytes(0));

        // mint
        token0.mint(address(this), 2 ether);
        token1.mint(address(this), 2 ether);
        IBinPoolManager.MintParams memory mintParams = _getSingleBinMintParams(activeId, 1 ether, 1 ether);
        binLiquidityHelper.mint(key, mintParams, "");

        // burn
        IBinPoolManager.BurnParams memory burnParams =
            _getSingleBinBurnLiquidityParams(key, poolManager, activeId, address(binLiquidityHelper), 100);

        uint256[] memory ids = new uint256[](1);
        bytes32[] memory amounts = new bytes32[](1);
        ids[0] = activeId;
        amounts[0] = uint128(1e18).encode(uint128(1e18));
        vm.expectEmit();
        emit Burn(key.toId(), address(binLiquidityHelper), ids, amounts);

        snapStart("BinPoolManagerTest#testGasBurnOneBin");
        binLiquidityHelper.burn(key, burnParams, "");
        snapEnd();
    }

    function testGasBurnHalfBin() public {
        // initialize
        poolManager.initialize(key, activeId, new bytes(0));

        // mint
        token0.mint(address(this), 2 ether);
        token1.mint(address(this), 2 ether);
        IBinPoolManager.MintParams memory mintParams = _getSingleBinMintParams(activeId, 1 ether, 1 ether);
        binLiquidityHelper.mint(key, mintParams, "");

        // burn
        IBinPoolManager.BurnParams memory burnParams =
            _getSingleBinBurnLiquidityParams(key, poolManager, activeId, address(binLiquidityHelper), 50);

        snapStart("BinPoolManagerTest#testGasBurnHalfBin");
        binLiquidityHelper.burn(key, burnParams, "");
        snapEnd();
    }

    function testGasBurnNineBins() public {
        poolManager.initialize(key, activeId, new bytes(0));

        // mint on 9 bins
        token0.mint(address(this), 10 ether);
        token1.mint(address(this), 10 ether);
        (IBinPoolManager.MintParams memory mintParams, uint24[] memory binIds) =
            _getMultipleBinMintParams(activeId, 10 ether, 10 ether, 5, 5);
        binLiquidityHelper.mint(key, mintParams, "");

        // burn on 9 binds
        IBinPoolManager.BurnParams memory burnParams =
            _getMultipleBinBurnLiquidityParams(key, poolManager, binIds, address(binLiquidityHelper), 100);
        snapStart("BinPoolManagerTest#testGasBurnNineBins");
        binLiquidityHelper.burn(key, burnParams, "");
        snapEnd();
    }

    function testBurnNativeCurrency() public {
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(address(poolManager)),
            fee: uint24(3000), // 3000 = 0.3%
            parameters: poolParam.setBinStep(10) // binStep
        });
        poolManager.initialize(key, activeId, new bytes(0));

        // mint
        token1.mint(address(this), 1 ether);
        IBinPoolManager.MintParams memory mintParams = _getSingleBinMintParams(activeId, 1 ether, 1 ether);
        binLiquidityHelper.mint{value: 1 ether}(key, mintParams, "");

        // burn
        IBinPoolManager.BurnParams memory burnParams =
            _getSingleBinBurnLiquidityParams(key, poolManager, activeId, address(binLiquidityHelper), 100);

        uint256[] memory ids = new uint256[](1);
        bytes32[] memory amounts = new bytes32[](1);
        ids[0] = activeId;
        amounts[0] = uint128(1e18).encode(uint128(1e18));
        vm.expectEmit();
        emit Burn(key.toId(), address(binLiquidityHelper), ids, amounts);

        snapStart("BinPoolManagerTest#testBurnNativeCurrency");
        binLiquidityHelper.burn(key, burnParams, "");
        snapEnd();
    }

    function testGasSwapSingleBin() public {
        // initialize
        poolManager.initialize(key, activeId, new bytes(0));

        // mint
        token0.mint(address(this), 10 ether);
        token1.mint(address(this), 10 ether);
        IBinPoolManager.MintParams memory mintParams = _getSingleBinMintParams(activeId, 10 ether, 10 ether);
        binLiquidityHelper.mint(key, mintParams, "");

        // swap 1 ether of tokenX for tokenY
        token0.mint(address(this), 1 ether);
        BinSwapHelper.TestSettings memory testSettings =
            BinSwapHelper.TestSettings({withdrawTokens: true, settleUsingTransfer: true});
        vm.expectEmit();
        emit Swap(key.toId(), address(binSwapHelper), 1 ether, -((1 ether * 997) / 1000), activeId, key.fee, 0);

        snapStart("BinPoolManagerTest#testGasSwapSingleBin");
        binSwapHelper.swap(key, true, 1 ether, testSettings, "");
        snapEnd();
    }

    function testGasSwapMultipleBins() public {
        poolManager.initialize(key, activeId, new bytes(0));

        // mint on 9 bins, around 2 eth worth on each bin. eg. 4 binY || activeBin || 4 binX
        token0.mint(address(this), 10 ether);
        token1.mint(address(this), 10 ether);
        (IBinPoolManager.MintParams memory mintParams,) = _getMultipleBinMintParams(activeId, 10 ether, 10 ether, 5, 5);
        binLiquidityHelper.mint(key, mintParams, "");

        // swap 8 ether of tokenX for tokenY
        token0.mint(address(this), 8 ether);
        BinSwapHelper.TestSettings memory testSettings =
            BinSwapHelper.TestSettings({withdrawTokens: true, settleUsingTransfer: true});
        snapStart("BinPoolManagerTest#testGasSwapMultipleBins");
        binSwapHelper.swap(key, true, 8 ether, testSettings, ""); // traverse over 4 bin
        snapEnd();
    }

    function testGasSwapOverBigBinIdGate() public {
        poolManager.initialize(key, activeId, new bytes(0));

        // mint on 9 bins, around 2 eth worth on each bin. eg. 4 binY || activeBin || 4 binX
        token0.mint(address(this), 1 ether);
        token1.mint(address(this), 6 ether);

        IBinPoolManager.MintParams memory mintParams;

        // add 1 eth of tokenX and 1 eth of tokenY liquidity at activeId
        mintParams = _getSingleBinMintParams(activeId, 1 ether, 1 ether);
        binLiquidityHelper.mint(key, mintParams, "");

        // add 5 eth of tokenY liquidity.
        for (uint256 i = 1; i < 6; i++) {
            mintParams = _getCustomSingleSidedBinMintParam(activeId - uint24(300 * i), 1 ether, true);
            binLiquidityHelper.mint(key, mintParams, "");
        }

        // swap 6 ether of tokenX for tokenY. crossing over 5
        token0.mint(address(this), 6 ether);
        BinSwapHelper.TestSettings memory testSettings =
            BinSwapHelper.TestSettings({withdrawTokens: true, settleUsingTransfer: true});
        snapStart("BinPoolManagerTest#testGasSwapOverBigBinIdGate");
        binSwapHelper.swap(key, true, 6 ether, testSettings, "");
        snapEnd();
    }

    function testGasDonate() public {
        poolManager.initialize(key, activeId, new bytes(0));

        token0.mint(address(this), 11 ether);
        token1.mint(address(this), 11 ether);

        // add 1 eth of tokenX and 1 eth of tokenY liquidity at activeId
        IBinPoolManager.MintParams memory mintParams = _getSingleBinMintParams(activeId, 1 ether, 1 ether);
        binLiquidityHelper.mint(key, mintParams, "");

        vm.expectEmit();
        emit Donate(key.toId(), address(binDonateHelper), 10 ether, 10 ether, activeId);

        snapStart("BinPoolManagerTest#testGasDonate");
        binDonateHelper.donate(key, 10 ether, 10 ether, "");
        snapEnd();
    }

    function testSwapUseSurplusTokenAsInput() public {
        BinSwapHelper.TestSettings memory testSettings;

        // initialize the pool
        poolManager.initialize(key, activeId, new bytes(0));

        // mint
        token0.mint(address(this), 10 ether);
        token1.mint(address(this), 10 ether);
        IBinPoolManager.MintParams memory mintParams = _getSingleBinMintParams(activeId, 10 ether, 10 ether);
        binLiquidityHelper.mint(key, mintParams, "");

        // step 1: swap from currency0 to currency1 -- take tokenOut as NFT
        token0.mint(address(this), 1 ether);
        testSettings = BinSwapHelper.TestSettings({withdrawTokens: false, settleUsingTransfer: true});
        binSwapHelper.swap(key, true, 1 ether, testSettings, "");

        // step 2: verify surplus token balance
        uint256 surplusTokenAmount = vault.balanceOf(address(this), currency1);
        assertEq(surplusTokenAmount, 997 * 1e15); // 0.3% fee. amt: 997 * 1e15

        // Step 3: swap from currency1 to currency0, take takenIn from existing NFT
        vault.approve(address(binSwapHelper), currency1, type(uint256).max);
        testSettings = BinSwapHelper.TestSettings({withdrawTokens: true, settleUsingTransfer: false});
        binSwapHelper.swap(key, false, 1e17, testSettings, "");

        // Step 4: Verify surplus token balance used as input
        surplusTokenAmount = vault.balanceOf(address(this), currency1);
        assertEq(surplusTokenAmount, 897 * 1e15);
    }

    function testMintPoolNotInitialized() public {
        token0.mint(address(this), 10 ether);
        token1.mint(address(this), 10 ether);
        IBinPoolManager.MintParams memory mintParams = _getSingleBinMintParams(activeId, 10 ether, 10 ether);

        vm.expectRevert(PoolNotInitialized.selector);
        binLiquidityHelper.mint(key, mintParams, "");
    }

    function testBurnPoolNotInitialized() public {
        // burn
        IBinPoolManager.BurnParams memory burnParams =
            _getSingleBinBurnLiquidityParams(key, poolManager, activeId, address(binLiquidityHelper), 100);

        vm.expectRevert(PoolNotInitialized.selector);
        binLiquidityHelper.burn(key, burnParams, "");
    }

    function testSwapPoolNotInitialized() public {
        BinSwapHelper.TestSettings memory testSettings;

        token0.mint(address(this), 1 ether);
        testSettings = BinSwapHelper.TestSettings({withdrawTokens: false, settleUsingTransfer: true});

        vm.expectRevert(PoolNotInitialized.selector);
        binSwapHelper.swap(key, true, 1 ether, testSettings, "");

        vm.expectRevert(PoolNotInitialized.selector);
        poolManager.getSwapIn(key, true, 1 ether);

        vm.expectRevert(PoolNotInitialized.selector);
        poolManager.getSwapOut(key, true, 1 ether);
    }

    function testDonatePoolNotInitialized() public {
        token0.mint(address(this), 10 ether);
        token1.mint(address(this), 10 ether);

        vm.expectRevert(PoolNotInitialized.selector);
        binDonateHelper.donate(key, 10 ether, 10 ether, "");
    }

    function testExtLoadPoolActiveId() public {
        // verify owner at slot 0
        bytes32 owner = poolManager.extsload(0x00);
        assertEq(abi.encode(owner), abi.encode(address(this)));

        // initialize
        poolManager.initialize(key, activeId, new bytes(0));

        // verify poolId.
        uint256 POOL_SLOT = 4;
        snapStart("BinPoolManagerTest#testExtLoadPoolActiveId");
        bytes32 slot0Bytes = poolManager.extsload(keccak256(abi.encode(key.toId(), POOL_SLOT)));
        snapEnd();

        uint24 ativeIdExtsload;
        assembly {
            // slot0Bytes: 0x0000000000000000000000000000000000000000000000000000000000800000
            ativeIdExtsload := slot0Bytes
        }
        (uint24 activeIdLoad,,) = poolManager.getSlot0(key.toId());

        // assert that extsload loads the correct storage slot which matches the true slot0
        assertEq(ativeIdExtsload, activeIdLoad);
    }

    function testSetProtocolFeePoolNotOwner() public {
        MockProtocolFeeController feeController = new MockProtocolFeeController();
        poolManager.setProtocolFeeController(IProtocolFeeController(address(feeController)));

        uint24 protocolFee = feeController.protocolFeeForPool(key);

        vm.expectRevert(IProtocolFees.InvalidCaller.selector);
        poolManager.setProtocolFee(key, protocolFee);
    }

    function testSetProtocolFeePoolNotInitialized() public {
        MockProtocolFeeController feeController = new MockProtocolFeeController();
        poolManager.setProtocolFeeController(IProtocolFeeController(address(feeController)));

        uint24 protocolFee = feeController.protocolFeeForPool(key);

        vm.expectRevert(PoolNotInitialized.selector);
        vm.prank(address(feeController));
        poolManager.setProtocolFee(key, protocolFee);
    }

    function testSetProtocolFee() public {
        // initialize the pool and asset protocolFee is 0
        poolManager.initialize(key, activeId, new bytes(0));
        (, uint24 protocolFee,) = poolManager.getSlot0(key.toId());
        assertEq(protocolFee, 0);

        // set up feeController
        MockProtocolFeeController feeController = new MockProtocolFeeController();
        uint24 newProtocolFee = _getSwapFee(1000, 1000); // 0.1%
        poolManager.setProtocolFeeController(IProtocolFeeController(address(feeController)));

        // Call setProtocolFee, verify event and state updated
        vm.expectEmit();
        emit ProtocolFeeUpdated(key.toId(), newProtocolFee);
        snapStart("BinPoolManagerTest#testSetProtocolFee");
        vm.prank(address(feeController));
        poolManager.setProtocolFee(key, newProtocolFee);
        snapEnd();

        (, protocolFee,) = poolManager.getSlot0(key.toId());
        assertEq(protocolFee, newProtocolFee);
    }

    function testFuzz_SetMaxBinStep(uint16 binStep) public {
        vm.assume(binStep > poolManager.MIN_BIN_STEP());

        vm.expectEmit();
        emit SetMaxBinStep(binStep);
        snapStart("BinPoolManagerTest#testFuzz_SetMaxBinStep");
        poolManager.setMaxBinStep(binStep);
        snapEnd();

        assertEq(poolManager.MAX_BIN_STEP(), binStep);
    }

    function testSetMaxBinStep() public {
        uint16 binStep = 0;
        vm.expectRevert(abi.encodeWithSelector(MaxBinStepTooSmall.selector, binStep));
        poolManager.setMaxBinStep(binStep);

        vm.prank(makeAddr("bob"));
        vm.expectRevert("Ownable: caller is not the owner");
        poolManager.setMaxBinStep(100);
    }

    function testUpdateDynamicLPFee_FeeTooLarge() public {
        uint16 bitMap = 0x0004; // 0000 0000 0000 0100 (before mint call)
        BinFeeManagerHook binFeeManagerHook = new BinFeeManagerHook(poolManager);
        binFeeManagerHook.setHooksRegistrationBitmap(bitMap);

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(binFeeManagerHook)),
            poolManager: IPoolManager(address(poolManager)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG + uint24(3000), // 3000 = 0.3%
            parameters: bytes32(uint256(bitMap)).setBinStep(10)
        });

        binFeeManagerHook.setFee(LPFeeLibrary.TEN_PERCENT_FEE + 1);

        vm.expectRevert(IProtocolFees.FeeTooLarge.selector);
        vm.prank(address(binFeeManagerHook));
        poolManager.updateDynamicLPFee(key, LPFeeLibrary.TEN_PERCENT_FEE + 1);
    }

    function testUpdateDynamicLPFee_FeeNotDynamic() public {
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(address(poolManager)),
            fee: uint24(3000), // 3000 = 0.3%
            parameters: poolParam
        });

        vm.expectRevert(IPoolManager.UnauthorizedDynamicLPFeeUpdate.selector);
        poolManager.updateDynamicLPFee(key, 3000);
    }

    function testFuzzUpdateDynamicLPFee(uint24 _lpFee) public {
        _lpFee = uint24(bound(_lpFee, 0, LPFeeLibrary.TEN_PERCENT_FEE));

        uint16 bitMap = 0x0004; // 0000 0000 0000 0100 (before mint call)
        BinFeeManagerHook binFeeManagerHook = new BinFeeManagerHook(poolManager);
        binFeeManagerHook.setHooksRegistrationBitmap(bitMap);

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(binFeeManagerHook)),
            poolManager: IPoolManager(address(poolManager)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG + uint24(3000), // 3000 = 0.3%
            parameters: bytes32(uint256(bitMap)).setBinStep(10)
        });
        poolManager.initialize(key, activeId, new bytes(0));

        binFeeManagerHook.setFee(_lpFee);

        vm.expectEmit();
        emit DynamicLPFeeUpdated(key.toId(), _lpFee);

        snapStart("BinPoolManagerTest#testFuzzUpdateDynamicLPFee");
        vm.prank(address(binFeeManagerHook));
        poolManager.updateDynamicLPFee(key, _lpFee);
        snapEnd();

        (,, uint24 swapFee) = poolManager.getSlot0(key.toId());
        assertEq(swapFee, _lpFee);
    }

    function testSwap_WhenPaused() public {
        BinSwapHelper.TestSettings memory testSettings;

        // initialize the pool
        poolManager.initialize(key, activeId, new bytes(0));

        // mint
        token0.mint(address(this), 10 ether);
        token1.mint(address(this), 10 ether);
        IBinPoolManager.MintParams memory mintParams = _getSingleBinMintParams(activeId, 10 ether, 10 ether);
        binLiquidityHelper.mint(key, mintParams, "");

        // pause
        poolManager.pause();

        // attempt swap
        token0.mint(address(this), 1 ether);
        vm.expectRevert("Pausable: paused");
        testSettings = BinSwapHelper.TestSettings({withdrawTokens: false, settleUsingTransfer: true});
        binSwapHelper.swap(key, true, 1 ether, testSettings, "");
    }

    function testMint_WhenPaused() public {
        token0.mint(address(this), 1 ether);
        token1.mint(address(this), 1 ether);

        poolManager.initialize(key, activeId, new bytes(0));
        IBinPoolManager.MintParams memory mintParams;

        // add 1 eth of tokenX and 1 eth of tokenY liquidity at activeId
        mintParams = _getSingleBinMintParams(activeId, 1 ether, 1 ether);

        // pause
        poolManager.pause();

        vm.expectRevert("Pausable: paused");
        binLiquidityHelper.mint(key, mintParams, "");
    }

    // verify remove liquidity is fine when paused
    function testBurn_WhenPaused() public {
        // initialize
        poolManager.initialize(key, activeId, new bytes(0));

        // mint
        token0.mint(address(this), 2 ether);
        token1.mint(address(this), 2 ether);
        IBinPoolManager.MintParams memory mintParams = _getSingleBinMintParams(activeId, 1 ether, 1 ether);
        binLiquidityHelper.mint(key, mintParams, "");

        // pause
        poolManager.pause();

        // burn
        IBinPoolManager.BurnParams memory burnParams =
            _getSingleBinBurnLiquidityParams(key, poolManager, activeId, address(binLiquidityHelper), 100);

        uint256[] memory ids = new uint256[](1);
        bytes32[] memory amounts = new bytes32[](1);
        ids[0] = activeId;
        amounts[0] = uint128(1e18).encode(uint128(1e18));

        // verify no issue even when pause
        binLiquidityHelper.burn(key, burnParams, "");
    }

    function testDonate_WhenPaused() public {
        poolManager.initialize(key, activeId, new bytes(0));

        token0.mint(address(this), 11 ether);
        token1.mint(address(this), 11 ether);

        // add 1 eth of tokenX and 1 eth of tokenY liquidity at activeId
        IBinPoolManager.MintParams memory mintParams = _getSingleBinMintParams(activeId, 1 ether, 1 ether);
        binLiquidityHelper.mint(key, mintParams, "");

        // pause
        poolManager.pause();

        vm.expectRevert("Pausable: paused");
        binDonateHelper.donate(key, 10 ether, 10 ether, "");
    }

    receive() external payable {}

    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }

    function _getSwapFee(uint24 fee0, uint24 fee1) internal pure returns (uint24) {
        return fee0 + (fee1 << 12);
    }
}
