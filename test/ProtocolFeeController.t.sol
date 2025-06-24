// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Vault} from "../src/Vault.sol";
import {CLPoolManager} from "../src/pool-cl/CLPoolManager.sol";
import {BinPoolManager} from "../src/pool-bin/BinPoolManager.sol";
import {ProtocolFeeController} from "../src/ProtocolFeeController.sol";
import {PoolKey} from "../src/types/PoolKey.sol";
import {LPFeeLibrary} from "../src/libraries/LPFeeLibrary.sol";
import {TokenFixture} from "./helpers/TokenFixture.sol";
import {Constants} from "../test/pool-cl/helpers/Constants.sol";
import {IHooks} from "../src/interfaces/IHooks.sol";
import {CLPoolParametersHelper} from "../src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {BinPoolParametersHelper} from "../src/pool-bin/libraries/BinPoolParametersHelper.sol";
import {ProtocolFeeLibrary} from "../src/libraries/ProtocolFeeLibrary.sol";
import {IPoolManager} from "../src/interfaces/IPoolManager.sol";
import {IProtocolFees} from "../src/interfaces/IProtocolFees.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {CLPoolManagerRouter} from "../test/pool-cl/helpers/CLPoolManagerRouter.sol";
import {ICLPoolManager} from "../src/pool-cl/interfaces/ICLPoolManager.sol";
import {IBinPoolManager} from "../src/pool-bin/interfaces/IBinPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "../src/types/Currency.sol";
import {TickMath} from "../src/pool-cl/libraries/TickMath.sol";
import {BalanceDelta} from "../src/types/BalanceDelta.sol";
import {BinTestHelper} from "./pool-bin/helpers/BinTestHelper.sol";
import {BinSwapHelper} from "./pool-bin/helpers/BinSwapHelper.sol";
import {BinLiquidityHelper} from "./pool-bin/helpers/BinLiquidityHelper.sol";
import {HooksContract} from "./libraries/Hooks/HooksContract.sol";

contract ProtocolFeeControllerTest is Test, BinTestHelper, TokenFixture {
    using CLPoolParametersHelper for bytes32;
    using BinPoolParametersHelper for bytes32;
    using ProtocolFeeLibrary for *;

    /// @notice 100% in hundredths of a bip
    uint256 private constant ONE_HUNDRED_PERCENT_RATIO = 1e6;

    /// @dev the initial setting of the default protocol fee for dynamic fee pool is 0.03% i.e. 3bps
    uint24 private constant DEFAULT_PROTOCOL_FEE_FOR_DYNAMIC_FEE_POOL = 300;

    Vault vault;
    CLPoolManager clPoolManager;
    BinPoolManager binPoolManager;

    BinSwapHelper public binSwapHelper;
    BinLiquidityHelper public binLiquidityHelper;

    HooksContract public hooksContract;

    function setUp() public {
        initializeTokens();

        vault = new Vault();
        clPoolManager = new CLPoolManager(vault);
        binPoolManager = new BinPoolManager(vault);
        vault.registerApp(address(clPoolManager));
        vault.registerApp(address(binPoolManager));

        binSwapHelper = new BinSwapHelper(binPoolManager, vault);
        binLiquidityHelper = new BinLiquidityHelper(binPoolManager, vault);
        IERC20(Currency.unwrap(currency0)).approve(address(binSwapHelper), 1000 ether);
        IERC20(Currency.unwrap(currency1)).approve(address(binSwapHelper), 1000 ether);
        IERC20(Currency.unwrap(currency0)).approve(address(binLiquidityHelper), 1000 ether);
        IERC20(Currency.unwrap(currency1)).approve(address(binLiquidityHelper), 1000 ether);

        hooksContract = new HooksContract(0);
    }

    function testOwnerTransfer() public {
        ProtocolFeeController controller = new ProtocolFeeController(address(clPoolManager));
        // starts with address(this) as owner
        assertEq(controller.owner(), address(this));

        {
            // must from owner
            vm.prank(makeAddr("someone"));
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, makeAddr("someone")));
            controller.transferOwnership(makeAddr("newOwner"));
        }

        controller.transferOwnership(makeAddr("newOwner"));

        // still address(this) as owner before new owner accept
        assertEq(controller.pendingOwner(), makeAddr("newOwner"));
        assertEq(controller.owner(), address(this));

        {
            // must from pending owner
            vm.prank(makeAddr("someone"));
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, makeAddr("someone")));
            controller.acceptOwnership();
        }

        vm.prank(makeAddr("newOwner"));
        controller.acceptOwnership();
        assertEq(controller.owner(), makeAddr("newOwner"));
    }

    function testSetDefaultProtocolFeeForDynamicFeePool(uint24 newDefaultProtocolFeeForDynamicFeePool) public {
        ProtocolFeeController controller = new ProtocolFeeController(address(clPoolManager));

        // it should start with 0.03% as default
        assertEq(controller.defaultProtocolFeeForDynamicFeePool(), DEFAULT_PROTOCOL_FEE_FOR_DYNAMIC_FEE_POOL);

        {
            // must from owner
            vm.prank(makeAddr("someone"));
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, makeAddr("someone")));
            controller.setDefaultProtocolFeeForDynamicFeePool(newDefaultProtocolFeeForDynamicFeePool);
        }

        if (newDefaultProtocolFeeForDynamicFeePool > ProtocolFeeLibrary.MAX_PROTOCOL_FEE) {
            vm.expectRevert(ProtocolFeeController.InvalidDefaultProtocolFeeForDynamicFeePool.selector);
            controller.setDefaultProtocolFeeForDynamicFeePool(newDefaultProtocolFeeForDynamicFeePool);
        } else {
            vm.expectEmit(true, true, true, true);
            emit ProtocolFeeController.DefaultProtocolFeeForDynamicFeePoolUpdated(
                DEFAULT_PROTOCOL_FEE_FOR_DYNAMIC_FEE_POOL, newDefaultProtocolFeeForDynamicFeePool
            );
            controller.setDefaultProtocolFeeForDynamicFeePool(newDefaultProtocolFeeForDynamicFeePool);
            assertEq(controller.defaultProtocolFeeForDynamicFeePool(), newDefaultProtocolFeeForDynamicFeePool);
        }
    }

    function testSetProcotolFeeSplitRatio(uint256 newProtocolFeeSplitRatio) public {
        ProtocolFeeController controller = new ProtocolFeeController(address(clPoolManager));

        {
            // must from owner
            vm.prank(makeAddr("someone"));
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, makeAddr("someone")));
            controller.setProtocolFeeSplitRatio(newProtocolFeeSplitRatio);
        }

        if (newProtocolFeeSplitRatio > ONE_HUNDRED_PERCENT_RATIO) {
            vm.expectRevert(ProtocolFeeController.InvalidProtocolFeeSplitRatio.selector);
            controller.setProtocolFeeSplitRatio(newProtocolFeeSplitRatio);
        } else {
            vm.expectEmit(true, true, true, true);
            emit ProtocolFeeController.ProtocolFeeSplitRatioUpdated(
                controller.protocolFeeSplitRatio(), newProtocolFeeSplitRatio
            );
            controller.setProtocolFeeSplitRatio(newProtocolFeeSplitRatio);
            assertEq(controller.protocolFeeSplitRatio(), newProtocolFeeSplitRatio);
        }
    }

    function testGetLPFeeFromTotalFee() public {
        ProtocolFeeController controller = new ProtocolFeeController(address(clPoolManager));
        // common case1: totalFee=1%, splitRatio=33%
        {
            uint24 totalFee = 10000;
            uint24 lpFee = controller.getLPFeeFromTotalFee(totalFee);
            assertEq(lpFee, 6722);
        }

        // common case2: totalFee=0.5%, splitRatio=33%
        {
            uint24 totalFee = 5000;
            uint24 lpFee = controller.getLPFeeFromTotalFee(totalFee);
            assertEq(lpFee, 3355);
        }

        // common case3: totalFee=0.1%, splitRatio=33%
        {
            uint24 totalFee = 1000;
            uint24 lpFee = controller.getLPFeeFromTotalFee(totalFee);
            assertEq(lpFee, 670);
        }

        controller.setProtocolFeeSplitRatio(500000);

        // common case4: totalFee=1%, splitRatio=50%
        {
            uint24 totalFee = 10000;
            uint24 lpFee = controller.getLPFeeFromTotalFee(totalFee);
            // protocol fee is capped at 0.4% so lpFee will be 0.6% in this case
            assertEq(lpFee, 6024);
        }

        // common case5: totalFee=0.5%, splitRatio=50%
        {
            uint24 totalFee = 5000;
            uint24 lpFee = controller.getLPFeeFromTotalFee(totalFee);
            assertEq(lpFee, 2506);
        }

        // common case6: totalFee=0.1%, splitRatio=50%
        {
            uint24 totalFee = 1000;
            uint24 lpFee = controller.getLPFeeFromTotalFee(totalFee);
            assertEq(lpFee, 500);
        }
    }

    function testGetLPFeeFromTotalFee(uint24 totalFee, uint24 splitRatio) public {
        totalFee = uint24(bound(totalFee, 0, LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE));
        ProtocolFeeController controller = new ProtocolFeeController(address(clPoolManager));

        // ignore extreme case where splitRatio is over 90% to avoid precision loss
        splitRatio = uint24(bound(splitRatio, 0, ONE_HUNDRED_PERCENT_RATIO * 9 / 10));
        controller.setProtocolFeeSplitRatio(splitRatio);

        // try to simulate the calculation the process of FE initialization pool

        // step1: calculate lpFee from totalFee
        uint24 lpFee = controller.getLPFeeFromTotalFee(totalFee);

        assertGe(lpFee, 0);
        assertLe(lpFee, totalFee);

        // step2: prepare the poolKey
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: clPoolManager,
            fee: lpFee,
            parameters: bytes32(0).setTickSpacing(10)
        });
        uint24 protocolFee = controller.protocolFeeForPool(key);
        uint16 protocolFeeZeroForOne = protocolFee.getZeroForOneFee();

        // verify the totalFee expected to be equal to protocolFee + (1 - protocolFee) * lpFee
        assertApproxEqAbs(
            totalFee,
            protocolFeeZeroForOne.calculateSwapFee(lpFee),
            // keeping the error within 0.05% (can't avoid due to precision loss)
            500,
            "totalFee should be equal to protocolFee + (1 - protocolFee) * lpFee"
        );
    }

    function testProtocolFeeForPool(uint24 lpFee, uint256 protocolFeeRatio) public {
        lpFee = uint24(bound(lpFee, 0, LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE));
        ProtocolFeeController controller = new ProtocolFeeController(address(clPoolManager));
        protocolFeeRatio = bound(protocolFeeRatio, 0, ONE_HUNDRED_PERCENT_RATIO);
        controller.setProtocolFeeSplitRatio(protocolFeeRatio);

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: clPoolManager,
            fee: lpFee,
            parameters: bytes32(0).setTickSpacing(10)
        });

        uint24 protcolFee = controller.protocolFeeForPool(key);
        uint16 protocolFeeZeroForOne = protcolFee.getZeroForOneFee();

        // protocol fee should be equal for both directions
        assertEq(protocolFeeZeroForOne, protcolFee.getOneForZeroFee());

        // protocol fee should always be no more than the cap
        assertLe(protocolFeeZeroForOne, ProtocolFeeLibrary.MAX_PROTOCOL_FEE);

        if (protocolFeeZeroForOne == ProtocolFeeLibrary.MAX_PROTOCOL_FEE) {
            // for example, given splitRatio=33% then lpFee=0.81538274% is the threshold that will make the protocol fee 0.4%
            assertGe(lpFee, _calculateLPFeeThreshold(controller));
        } else {
            // protocol fee should be protocolFeeRatio of the total fee
            uint24 totalFee = protocolFeeZeroForOne.calculateSwapFee(lpFee);
            assertApproxEqAbs(
                totalFee * controller.protocolFeeSplitRatio() / ONE_HUNDRED_PERCENT_RATIO,
                protocolFeeZeroForOne,
                // keeping the error within 0.01% (can't avoid due to precision loss)
                100
            );
        }
    }

    function testCLPoolInitWithoutProtolFeeController(uint24 lpFee) public {
        lpFee = uint24(bound(lpFee, 0, LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE));
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: clPoolManager,
            fee: lpFee,
            parameters: bytes32(0).setTickSpacing(10)
        });
        clPoolManager.initialize(key, Constants.SQRT_RATIO_1_1);

        (,, uint24 actualProtocolFee, uint24 actualLpFee) = clPoolManager.getSlot0(key.toId());

        assertEq(actualLpFee, lpFee);
        assertEq(actualProtocolFee, 0);
    }

    function testBinPoolInitWithoutProtolFeeController(uint24 lpFee) public {
        lpFee = uint24(bound(lpFee, 0, LPFeeLibrary.TEN_PERCENT_FEE));
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: binPoolManager,
            fee: lpFee,
            parameters: bytes32(0).setBinStep(1)
        });
        binPoolManager.initialize(key, ID_ONE);

        (, uint24 actualProtocolFee, uint24 actualLpFee) = binPoolManager.getSlot0(key.toId());
        assertEq(actualLpFee, lpFee);
        assertEq(actualProtocolFee, 0);
    }

    function testCLPoolInitWithProtolFeeControllerFuzz(uint24 lpFee, uint256 newProtocolFeeRatio) public {
        lpFee = uint24(bound(lpFee, 0, LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE));
        ProtocolFeeController controller = new ProtocolFeeController(address(clPoolManager));
        newProtocolFeeRatio = bound(newProtocolFeeRatio, 0, ONE_HUNDRED_PERCENT_RATIO);

        clPoolManager.setProtocolFeeController(controller);
        controller.setProtocolFeeSplitRatio(newProtocolFeeRatio);

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: clPoolManager,
            fee: lpFee,
            parameters: bytes32(0).setTickSpacing(10)
        });
        clPoolManager.initialize(key, Constants.SQRT_RATIO_1_1);

        (,, uint24 actualProtocolFee, uint24 actualLpFee) = clPoolManager.getSlot0(key.toId());

        assertEq(actualLpFee, lpFee);

        // under default rule protocol fee must be equal for both directions
        uint16 protocolFeeZeroForOne = actualProtocolFee.getZeroForOneFee();
        uint16 protocolFeeOneForZero = actualProtocolFee.getOneForZeroFee();
        assertEq(protocolFeeOneForZero, protocolFeeZeroForOne);

        // protocol fee should always be no more than the cap
        assertLe(protocolFeeOneForZero, ProtocolFeeLibrary.MAX_PROTOCOL_FEE);

        if (protocolFeeOneForZero == ProtocolFeeLibrary.MAX_PROTOCOL_FEE) {
            // for example, given splitRatio=33% then lpFee=0.81538274% is the threshold that will make the protocol fee 0.4%
            assertGe(lpFee, _calculateLPFeeThreshold(controller));
        } else {
            // protocol fee should be the given ratio of the total fee
            uint24 totalFee = protocolFeeZeroForOne.calculateSwapFee(actualLpFee);
            assertApproxEqAbs(
                totalFee * controller.protocolFeeSplitRatio() / ONE_HUNDRED_PERCENT_RATIO,
                protocolFeeZeroForOne,
                // keeping the error within 0.05% (can't avoid due to precision loss)
                500
            );
        }
    }

    function testBinPoolInitWithProtolFeeControllerFuzz(uint24 lpFee, uint256 newProtocolFeeRatio) public {
        lpFee = uint24(bound(lpFee, 0, LPFeeLibrary.TEN_PERCENT_FEE));
        ProtocolFeeController controller = new ProtocolFeeController(address(binPoolManager));
        newProtocolFeeRatio = bound(newProtocolFeeRatio, 0, ONE_HUNDRED_PERCENT_RATIO);

        binPoolManager.setProtocolFeeController(controller);
        controller.setProtocolFeeSplitRatio(newProtocolFeeRatio);

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: binPoolManager,
            fee: lpFee,
            parameters: bytes32(0).setBinStep(1)
        });
        binPoolManager.initialize(key, ID_ONE);

        (, uint24 actualProtocolFee, uint24 actualLpFee) = binPoolManager.getSlot0(key.toId());

        assertEq(actualLpFee, lpFee);

        // under default rule protocol fee must be equal for both directions
        uint16 protocolFeeZeroForOne = actualProtocolFee.getZeroForOneFee();
        uint16 protocolFeeOneForZero = actualProtocolFee.getOneForZeroFee();
        assertEq(protocolFeeOneForZero, protocolFeeZeroForOne);

        // protocol fee should always be no more than the cap
        assertLe(protocolFeeOneForZero, ProtocolFeeLibrary.MAX_PROTOCOL_FEE);

        if (protocolFeeOneForZero == ProtocolFeeLibrary.MAX_PROTOCOL_FEE) {
            // for example, given splitRatio=33% then lpFee=0.81538274% is the threshold that will make the protocol fee 0.4%
            assertGe(lpFee, _calculateLPFeeThreshold(controller));
        } else {
            // protocol fee should be the given ratio of the total fee
            uint24 totalFee = protocolFeeZeroForOne.calculateSwapFee(actualLpFee);
            assertApproxEqAbs(
                totalFee * controller.protocolFeeSplitRatio() / ONE_HUNDRED_PERCENT_RATIO,
                protocolFeeZeroForOne,
                // keeping the error within 0.01% (can't avoid due to precision loss)
                100
            );
        }
    }

    function testCLDynamicPoolInitWithProtolFeeControllerFuzz(uint24 newDefaultProtocolFeeForDynamicFeePool) public {
        ProtocolFeeController controller = new ProtocolFeeController(address(clPoolManager));
        newDefaultProtocolFeeForDynamicFeePool =
            uint24(bound(newDefaultProtocolFeeForDynamicFeePool, 0, ProtocolFeeLibrary.MAX_PROTOCOL_FEE));

        clPoolManager.setProtocolFeeController(controller);

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: hooksContract,
            poolManager: clPoolManager,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            parameters: bytes32(0).setTickSpacing(10)
        });
        clPoolManager.initialize(key, Constants.SQRT_RATIO_1_1);

        (,, uint24 actualProtocolFee,) = clPoolManager.getSlot0(key.toId());

        // under default rule protocol fee must be equal for both directions
        uint16 protocolFeeZeroForOne = actualProtocolFee.getZeroForOneFee();
        uint16 protocolFeeOneForZero = actualProtocolFee.getOneForZeroFee();
        assertEq(protocolFeeOneForZero, protocolFeeZeroForOne);
        assertEq(protocolFeeOneForZero, DEFAULT_PROTOCOL_FEE_FOR_DYNAMIC_FEE_POOL);

        controller.setDefaultProtocolFeeForDynamicFeePool(newDefaultProtocolFeeForDynamicFeePool);

        key.parameters = bytes32(0).setTickSpacing(30);
        clPoolManager.initialize(key, Constants.SQRT_RATIO_1_1);

        (,, actualProtocolFee,) = clPoolManager.getSlot0(key.toId());
        // under default rule protocol fee must be equal for both directions
        protocolFeeZeroForOne = actualProtocolFee.getZeroForOneFee();
        protocolFeeOneForZero = actualProtocolFee.getOneForZeroFee();
        assertEq(protocolFeeOneForZero, protocolFeeZeroForOne);
        assertEq(protocolFeeOneForZero, newDefaultProtocolFeeForDynamicFeePool);

        // verify the original pool is not affected
        {
            key.parameters = bytes32(0).setTickSpacing(10);

            (,, actualProtocolFee,) = clPoolManager.getSlot0(key.toId());
            // under default rule protocol fee must be equal for both directions
            protocolFeeZeroForOne = actualProtocolFee.getZeroForOneFee();
            protocolFeeOneForZero = actualProtocolFee.getOneForZeroFee();
            assertEq(protocolFeeOneForZero, protocolFeeZeroForOne);
        }
    }

    function testBinDynamicPoolInitWithProtolFeeControllerFuzz(uint24 newDefaultProtocolFeeForDynamicFeePool) public {
        ProtocolFeeController controller = new ProtocolFeeController(address(binPoolManager));
        newDefaultProtocolFeeForDynamicFeePool =
            uint24(bound(newDefaultProtocolFeeForDynamicFeePool, 0, ProtocolFeeLibrary.MAX_PROTOCOL_FEE));

        binPoolManager.setProtocolFeeController(controller);

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: hooksContract,
            poolManager: binPoolManager,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            parameters: bytes32(0).setBinStep(1)
        });
        binPoolManager.initialize(key, ID_ONE);

        (, uint24 actualProtocolFee,) = binPoolManager.getSlot0(key.toId());

        // under default rule protocol fee must be equal for both directions
        uint16 protocolFeeZeroForOne = actualProtocolFee.getZeroForOneFee();
        uint16 protocolFeeOneForZero = actualProtocolFee.getOneForZeroFee();
        assertEq(protocolFeeOneForZero, protocolFeeZeroForOne);
        assertEq(protocolFeeOneForZero, DEFAULT_PROTOCOL_FEE_FOR_DYNAMIC_FEE_POOL);

        controller.setDefaultProtocolFeeForDynamicFeePool(newDefaultProtocolFeeForDynamicFeePool);

        key.parameters = bytes32(0).setBinStep(5);
        binPoolManager.initialize(key, ID_ONE);

        (, actualProtocolFee,) = binPoolManager.getSlot0(key.toId());
        // under default rule protocol fee must be equal for both directions
        protocolFeeZeroForOne = actualProtocolFee.getZeroForOneFee();
        protocolFeeOneForZero = actualProtocolFee.getOneForZeroFee();
        assertEq(protocolFeeOneForZero, protocolFeeZeroForOne);
        assertEq(protocolFeeOneForZero, newDefaultProtocolFeeForDynamicFeePool);

        // verify the original pool is not affected
        {
            key.parameters = bytes32(0).setBinStep(1);

            (, actualProtocolFee,) = binPoolManager.getSlot0(key.toId());
            // under default rule protocol fee must be equal for both directions
            protocolFeeZeroForOne = actualProtocolFee.getZeroForOneFee();
            protocolFeeOneForZero = actualProtocolFee.getOneForZeroFee();
            assertEq(protocolFeeOneForZero, protocolFeeZeroForOne);
        }
    }

    function testSetProtocolFeeForCLPool(uint24 newProtocolFee) public {
        ProtocolFeeController controller = new ProtocolFeeController(address(clPoolManager));
        clPoolManager.setProtocolFeeController(controller);

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: clPoolManager,
            fee: 3000,
            parameters: bytes32(0).setTickSpacing(10)
        });
        clPoolManager.initialize(key, Constants.SQRT_RATIO_1_1);

        {
            // must from owner
            vm.prank(makeAddr("someone"));
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, makeAddr("someone")));
            controller.setProtocolFee(key, newProtocolFee);
        }

        {
            // key match
            key.poolManager = IPoolManager(makeAddr("notPoolManagerAddress"));
            vm.expectRevert(ProtocolFeeController.InvalidPoolManager.selector);
            controller.setProtocolFee(key, newProtocolFee);
        }

        key.poolManager = clPoolManager;
        if (!newProtocolFee.validate()) {
            vm.expectRevert(abi.encodeWithSelector(IProtocolFees.ProtocolFeeTooLarge.selector, newProtocolFee));
            controller.setProtocolFee(key, newProtocolFee);
        } else {
            controller.setProtocolFee(key, newProtocolFee);

            (,, uint24 actualProtocolFee,) = clPoolManager.getSlot0(key.toId());
            assertEq(actualProtocolFee, newProtocolFee);
        }
    }

    /// @dev when collectProtocolFee with amt=0, event should emit amount collected
    function testCollectProtocolFee_CollectAllFee() public {
        // init protocol fee controller and bind it to clPoolManager
        ProtocolFeeController controller = new ProtocolFeeController(address(clPoolManager));
        clPoolManager.setProtocolFeeController(controller);

        // init pool with protocol fee controller
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: clPoolManager,
            fee: 2000,
            parameters: bytes32(0).setTickSpacing(10)
        });
        clPoolManager.initialize(key, Constants.SQRT_RATIO_1_1);

        // add some liquidity
        CLPoolManagerRouter router = new CLPoolManagerRouter(vault, clPoolManager);
        IERC20(Currency.unwrap(currency0)).approve(address(router), 10000 ether);
        IERC20(Currency.unwrap(currency1)).approve(address(router), 10000 ether);
        router.modifyPosition(
            key,
            ICLPoolManager.ModifyLiquidityParams({tickLower: -10, tickUpper: 10, liquidityDelta: 1000000 ether, salt: 0}),
            ""
        );

        // swap to generate protocol fee
        // by default splitRatio=33.33% if lpFee is 0.2% then protocol fee should be roughly 0.1%
        router.swap(
            key,
            ICLPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -100 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            ""
        );

        // verify protocol fee accrued > 0
        uint256 protocolFeesAccrued = clPoolManager.protocolFeesAccrued(currency0);
        assertGt(protocolFeesAccrued, 0);

        // collect all fee
        vm.expectEmit();
        emit ProtocolFeeController.ProtocolFeeCollected(currency0, protocolFeesAccrued);
        controller.collectProtocolFee(makeAddr("recipient"), currency0, 0);
    }

    function testCollectProtocolFeeForCLPool() public {
        // init protocol fee controller and bind it to clPoolManager
        ProtocolFeeController controller = new ProtocolFeeController(address(clPoolManager));
        clPoolManager.setProtocolFeeController(controller);

        // init pool with protocol fee controller
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: clPoolManager,
            fee: 2000,
            parameters: bytes32(0).setTickSpacing(10)
        });
        clPoolManager.initialize(key, Constants.SQRT_RATIO_1_1);

        (,, uint24 actualProtocolFee,) = clPoolManager.getSlot0(key.toId());

        // add some liquidity
        CLPoolManagerRouter router = new CLPoolManagerRouter(vault, clPoolManager);
        IERC20(Currency.unwrap(currency0)).approve(address(router), 10000 ether);
        IERC20(Currency.unwrap(currency1)).approve(address(router), 10000 ether);
        router.modifyPosition(
            key,
            ICLPoolManager.ModifyLiquidityParams({tickLower: -10, tickUpper: 10, liquidityDelta: 1000000 ether, salt: 0}),
            ""
        );

        // swap to generate protocol fee
        // by default splitRatio=33.33% if lpFee is 0.2% then protocol fee should be roughly 0.1%
        router.swap(
            key,
            ICLPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -100 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            ""
        );

        assertEq(
            clPoolManager.protocolFeesAccrued(currency0),
            100 ether * uint256(actualProtocolFee >> 12) / ONE_HUNDRED_PERCENT_RATIO
        );

        // lp fee should be roughly 0.1 ether, allow 2% error
        assertApproxEqAbs(clPoolManager.protocolFeesAccrued(currency0), 0.1 ether, 0.1 ether / 50);

        // check lp fee is twice the protocol fee
        (, BalanceDelta accumulatedLPFee) = router.modifyPosition(
            key,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: -10,
                tickUpper: 10,
                liquidityDelta: -1000000 ether,
                salt: 0
            }),
            ""
        );

        // allow 5% error
        assertApproxEqAbs(
            clPoolManager.protocolFeesAccrued(currency0) * 2,
            uint256(int256(accumulatedLPFee.amount0())),
            clPoolManager.protocolFeesAccrued(currency0) * 2 / 20
        );

        // collect protocol fee
        {
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, makeAddr("someone")));
            vm.prank(makeAddr("someone"));
            controller.collectProtocolFee(makeAddr("recipient"), currency0, 0);
        }

        // collect half
        uint256 protocolFeeAmount = clPoolManager.protocolFeesAccrued(currency0);
        vm.expectEmit();
        emit ProtocolFeeController.ProtocolFeeCollected(currency0, protocolFeeAmount / 2);
        controller.collectProtocolFee(makeAddr("recipient"), currency0, protocolFeeAmount / 2);

        assertEq(clPoolManager.protocolFeesAccrued(currency0), protocolFeeAmount / 2);
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(makeAddr("recipient")), protocolFeeAmount / 2);

        // collect the rest
        controller.collectProtocolFee(makeAddr("recipient"), currency0, 0);
        assertEq(clPoolManager.protocolFeesAccrued(currency0), 0);
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(makeAddr("recipient")), protocolFeeAmount);
    }

    function testCollectProtocolFeeForBinPool() public {
        // init protocol fee controller and bind it to binPoolManager
        ProtocolFeeController controller = new ProtocolFeeController(address(binPoolManager));
        binPoolManager.setProtocolFeeController(controller);
        // make protocol fee half of the total fee
        controller.setProtocolFeeSplitRatio(500000);

        // init pool with protocol fee controller
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: binPoolManager,
            fee: 2000,
            parameters: bytes32(0).setBinStep(1)
        });
        binPoolManager.initialize(key, ID_ONE);

        (, uint24 actualProtocolFee,) = binPoolManager.getSlot0(key.toId());

        // add some liquidity
        IBinPoolManager.MintParams memory mintParams = _getSingleBinMintParams(ID_ONE, 500 ether, 500 ether);
        binLiquidityHelper.mint(key, mintParams, abi.encode(0));

        // swap to generate protocol fee
        // splitRatio=50% so that protcol fee should be half of the total fee
        binSwapHelper.swap(key, true, -int128(100 ether), BinSwapHelper.TestSettings(true, true), "");

        assertEq(
            binPoolManager.protocolFeesAccrued(currency0),
            100 ether * uint256(actualProtocolFee >> 12) / ONE_HUNDRED_PERCENT_RATIO
        );

        // lp fee should be roughly 0.2 ether
        assertApproxEqAbs(binPoolManager.protocolFeesAccrued(currency0), 0.2 ether, 0.2 ether / 100);

        // check lp fee equals to the protocol fee
        IBinPoolManager.BurnParams memory burnParams =
            _getSingleBinBurnLiquidityParams(key, binPoolManager, ID_ONE, address(binLiquidityHelper), 100);
        BalanceDelta delta = binLiquidityHelper.burn(key, burnParams, "");

        assertApproxEqAbs(
            binPoolManager.protocolFeesAccrued(currency0) * 2,
            // amt1 out roughly 100 ether, but the actual output amount is less due to fee and init liquidity lock
            // since no slippage within a given bin, we can calculate the total fee as follows:
            uint256(int256(delta.amount1() - 400 ether)),
            // we know total fee is roughly 0.4 ether, let's say error caused by init liqudity lock is less than 1%
            0.4 ether / 100
        );

        // collect protocol fee
        {
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, makeAddr("someone")));
            vm.prank(makeAddr("someone"));
            controller.collectProtocolFee(makeAddr("recipient"), currency0, 0);
        }

        // collect half
        uint256 protocolFeeAmount = binPoolManager.protocolFeesAccrued(currency0);
        controller.collectProtocolFee(makeAddr("recipient"), currency0, protocolFeeAmount / 2);

        assertEq(binPoolManager.protocolFeesAccrued(currency0), protocolFeeAmount / 2);
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(makeAddr("recipient")), protocolFeeAmount / 2);

        // collect the rest
        controller.collectProtocolFee(makeAddr("recipient"), currency0, 0);
        assertEq(binPoolManager.protocolFeesAccrued(currency0), 0);
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(makeAddr("recipient")), protocolFeeAmount);
    }

    function _calculateLPFeeThreshold(ProtocolFeeController controller) internal view returns (uint24) {
        return uint24(
            ((ONE_HUNDRED_PERCENT_RATIO / controller.protocolFeeSplitRatio() - 1) * ProtocolFeeLibrary.MAX_PROTOCOL_FEE)
                / (ONE_HUNDRED_PERCENT_RATIO - ProtocolFeeLibrary.MAX_PROTOCOL_FEE)
        );
    }
}
