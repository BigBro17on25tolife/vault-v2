// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.13;

import "forge-std/src/Test.sol";
import "forge-std/src/console.sol";
import "@yield-protocol/utils-v2/contracts/cast/CastU256I128.sol";
import "../../Cauldron.sol";
import "../../FYToken.sol";
import "../../Join.sol";
import "../../interfaces/IJoin.sol";
import "../../interfaces/ILadle.sol";
import "../../interfaces/IOracle.sol";
import "../../oracles/uniswap/uniswapv0.8/FullMath.sol";
import "../../mocks/oracles/compound/CTokenChiMock.sol";
import "../../mocks/FlashBorrower.sol";
import "../../mocks/ERC20Mock.sol";
import "../utils/TestConstants.sol";
import { TestExtensions } from "../TestExtensions.sol";

interface ILadleCustom {
    function addToken(address token, bool set) external;

    function batch(bytes[] calldata calls) external payable returns(bytes[] memory results);

    function transfer(IERC20 token, address receiver, uint128 wad) external payable;

    function redeem(bytes6 seriesId, address to, uint256 wad) external payable returns (uint256);
}

abstract contract ZeroState is Test, TestConstants, TestExtensions {
    using CastU256I128 for uint256;

    event Point(bytes32 indexed param, address value);
    event SeriesMatured(uint256 chiAtMaturity);
    event Redeemed(address indexed from, address indexed to, uint256 amount, uint256 redeemed);

    FYToken public fyToken;
    Join public join;
    address public timelock;
    Cauldron public cauldron;
    IERC20 public token;
    uint128 public unit;
    address user;
    bytes6 public seriesId = 0x303130390000; // DAI March 23 series
    // bytes12 public vaultId;

    ILadle public ladle;
    IOracle public oracle;
    CTokenChiMock public mockOracle;

    function setUpMock() public {
        timelock = address(1);
        cauldron = Cauldron(address(2));
        ladle = ILadle(address(3));

        mockOracle = new CTokenChiMock();
        token = IERC20(address(new ERC20Mock("", "")));
        bytes6 mockIlkId = 0x000000000001;
        join = new Join(address(token));

        fyToken = new FYToken(
            mockIlkId,
            IOracle(address(mockOracle)),
            join,
            1680427572,
            "",
            ""
        );
        console.log("fyToken created");

        bytes4[] memory fyTokenRoles = new bytes4[](2);
        fyTokenRoles[0] = fyToken.mint.selector;

        fyTokenRoles[1] = fyToken.point.selector;
        fyToken.grantRoles(fyTokenRoles, address(this));
        fyToken.grantRoles(fyTokenRoles, address(ladle));

        bytes4[] memory daiJoinRoles = new bytes4[](2);
        daiJoinRoles[0] = join.join.selector;
        daiJoinRoles[1] = join.exit.selector;
        join.grantRoles(daiJoinRoles, address(fyToken));

        // vm.startPrank(timelock);

        // ILadleCustom(address(ladle)).addToken(address(fyToken), true);
        // cauldron.addSeries(seriesId, 0x303100000000, fyToken);
        // bytes6[] memory ilkIds = new bytes6[](1);
        // ilkIds[0] = fyToken.underlyingId();
        // cauldron.addIlks(seriesId, ilkIds);

        // vm.stopPrank();

    }

    function setUpHarness(string memory network) public {
        timelock = addresses[network][TIMELOCK];
        cauldron = Cauldron(addresses[network][CAULDRON]);
        ladle = ILadle(addresses[network][LADLE]);

        fyToken = FYToken(vm.envAddress("FYTOKEN"));
        token = IERC20(fyToken.underlying());
        oracle = fyToken.oracle();
        unit = uint128(10 ** ERC20Mock(address(token)).decimals());
    } 

    function setUp() public virtual {
        string memory network = vm.envOr(NETWORK, LOCALHOST);
        if (!equal(network, LOCALHOST)) vm.createSelectFork(network);

        if (vm.envOr(MOCK, true)) setUpMock();
        else setUpHarness(network);

        user = address(1);

        vm.label(address(cauldron), "cauldron");
        vm.label(address(ladle), "ladle");
        vm.label(user, "user");
        vm.label(address(token), "token");
        vm.label(address(oracle), "oracle");
        vm.label(address(join), "join");

        cash(token, user, 100 * unit);
    }
}

contract FYTokenTest is ZeroState {
    function testChangeOracle() public {
        console.log("can change the CHI oracle");
        vm.expectEmit(true, false, false, true);
        emit Point("oracle", address(this));
        vm.prank(timelock);
        fyToken.point("oracle", address(this));
    }

    function testChangeJoin() public {
        console.log("can change Join");
        vm.expectEmit(true, false, false, true);
        emit Point("join", address(this));
        vm.prank(timelock);
        fyToken.point("join", address(this));
    }

    function testMintWithUnderlying() public {
        console.log("can mint with underlying");
        uint256 balance = fyToken.balanceOf(address(this));   // will have 1 fyToken
        fyToken.mint(address(this), WAD);
        assertEq(fyToken.balanceOf(address(this)) - balance, WAD);
    }

    function testCantMatureBeforeMaturity() public {
        console.log("can't mature before maturity");
        vm.prank(timelock);
        vm.expectRevert("Only after maturity");
        fyToken.mature();
    }

    function testCantRedeemBeforeMaturity() public {
        console.log("can't redeem before maturity");
        vm.expectRevert("Only after maturity");
        fyToken.redeem(address(this), WAD);
    }

    function testConvertToPrincipal() public {
        console.log("can convert amount of underlying to principal");
        assertEq(fyToken.convertToPrincipal(1000), 1000);
    }

    function testConvertToUnderlying() public {
        console.log("can convert amount of principal to underlying");
        assertEq(fyToken.convertToUnderlying(1000), 1000);
    }

    function testPreviewRedeem() public {
        console.log("can preview the amount of underlying redeemed");
        assertEq(fyToken.previewRedeem(WAD), WAD);
    }

    function testPreviewWithdraw() public {
        console.log("can preview the amount of principal withdrawn");
        assertEq(fyToken.previewWithdraw(WAD), WAD);
    }
}

abstract contract AfterMaturity is ZeroState {
    function setUp() public virtual override {
        super.setUp();
        vm.warp(1664550000);
    }
}

contract AfterMaturityTest is AfterMaturity {
    function testCantMintAfterMaturity() public {
        console.log("can't mint after maturity");
        vm.expectRevert("Only before maturity");
        fyToken.mint(address(this), WAD);
    }

    function testMatureOnlyOnce() public {
        console.log("can only mature once");
        vm.prank(timelock);
        fyToken.mature();
        vm.expectRevert("Already matured");
        fyToken.mature();
    }

    function testMatureRevertsOnZeroChi() public {
        console.log("can't mature if chi is zero");

        CTokenChiMock chiOracle = new CTokenChiMock(); // Use a new oracle that we can force to be zero
        fyToken.mature();
        fyToken.point("oracle", address(chiOracle));
        chiOracle.set(0); 

        vm.prank(timelock);
        fyToken.mature();
        vm.expectRevert("Chi oracle malfunction");
        fyToken.mature();
    }

    function testMatureRecordsChiValue() public {
        console.log("records chi value when matureed");
        vm.prank(timelock);
        vm.expectEmit(false, false, false, true);
        emit SeriesMatured(220434062002504964823286680);
        fyToken.mature();
    }

    function testMaturesFirstRedemptionAfterMaturity() public {
        console.log("matures on first redemption after maturity if needed");
        uint256 ownerBalanceBefore = IERC20(fyToken.underlying()).balanceOf(address(this));
        uint256 joinBalanceBefore = IERC20(fyToken.underlying()).balanceOf(address(join));
        vm.expectEmit(true, true, false, true);
        emit Redeemed(
            address(this), 
            address(this), 
            WAD, 
            WAD
        );
        fyToken.redeem(address(this), WAD);
        assertEq(
            IERC20(fyToken.underlying()).balanceOf(address(this)), 
            ownerBalanceBefore + WAD
        );
        assertEq(
            IERC20(fyToken.underlying()).balanceOf(address(join)), 
            joinBalanceBefore - WAD
        );
        assertEq(
            fyToken.balanceOf(address(this)), 
            0
        );
    }
}

abstract contract OnceMatured is AfterMaturity {
    CTokenChiMock public chiOracle;
    uint256 accrual = FullMath.mulDiv(WAD, 110, 100);                       // 10%
    address fyTokenHolder = address(1);

    function setUp() public override {
        super.setUp();
        chiOracle = new CTokenChiMock();
        fyToken.point("oracle", address(chiOracle));                          // Uses new oracle to update to new chi value
        chiOracle.set(220434062002504964823286680); 
        fyToken.mature();
        chiOracle.set(220434062002504964823286680 * 110 / 100);             // Will set chi returned to be 10%
    }
}

contract OnceMaturedTest is OnceMatured {
    function testCannotChangeOracle() public {
        console.log("can't change the CHI oracle once matured");
        vm.expectRevert("Already matured");
        fyToken.point("oracle", address(this));
    }

    function testChiAccrualNotBelowOne() public {
        console.log("cannot have chi accrual below 1");
        assertGt(fyToken.accrual(), WAD);
    }

    function testConvertToUnderlyingWithAccrual() public {
        console.log("can convert the amount of underlying plus the accrual to principal");
        assertEq(fyToken.convertToUnderlying(1000), 1100);
        assertEq(fyToken.convertToUnderlying(5000), 5500);
    }

    function testConvertToPrincipalWithAccrual() public {
        console.log("can convert the amount of underlying plus the accrual to principal");
        assertEq(fyToken.convertToPrincipal(1100), 1000);
        assertEq(fyToken.convertToPrincipal(5500), 5000);
    }

    function testMaxRedeem() public {
        console.log("can get the max amount of principal redeemable");
        deal(address(fyToken), address(this), WAD * 2);
        assertEq(fyToken.maxRedeem(address(this)), WAD * 2);
    }

    function testMaxWithdraw() public {
        console.log("can get the max amount of underlying withdrawable");
        deal(address(fyToken), address(this), WAD * 2);
        assertEq(fyToken.maxRedeem(address(this)), WAD * 2);
    }

    function testRedeemWithAccrual() public {
        console.log("redeems according to chi accrual");
        uint256 ownerBalanceBefore = IERC20(fyToken.underlying()).balanceOf(address(this));
        uint256 joinBalanceBefore = IERC20(fyToken.underlying()).balanceOf(address(join));
        vm.expectEmit(true, true, false, true);
        emit Redeemed(
            address(this), 
            address(this), 
            WAD, 
            FullMath.mulDiv(WAD, accrual, WAD)
        );
        fyToken.redeem(address(this), WAD);
        assertEq(
            IERC20(fyToken.underlying()).balanceOf(address(this)), 
            ownerBalanceBefore + FullMath.mulDiv(WAD, accrual, WAD)
        );
        assertEq(
            IERC20(fyToken.underlying()).balanceOf(address(join)), 
            joinBalanceBefore - FullMath.mulDiv(WAD, accrual, WAD)
        );
        assertEq(
            fyToken.balanceOf(address(this)), 
            0
        );
    }

    function testRedeemOnTransfer() public {
        console.log("redeems when transfering to the fyToken contract");
        uint256 ownerBalanceBefore = IERC20(fyToken.underlying()).balanceOf(address(this));
        uint256 joinBalanceBefore = IERC20(fyToken.underlying()).balanceOf(address(join));
        fyToken.transfer(address(fyToken), WAD);
        assertEq(fyToken.balanceOf(address(this)), 0);
        vm.expectEmit(true, true, false, true);
        emit Redeemed(
            address(this),
            address(this), 
            WAD, 
            FullMath.mulDiv(WAD, accrual, WAD)
        );
        fyToken.redeem(address(this), WAD);
        assertEq(
            IERC20(fyToken.underlying()).balanceOf(address(this)), 
            ownerBalanceBefore + FullMath.mulDiv(WAD, accrual, WAD)
        );
        assertEq(
            IERC20(fyToken.underlying()).balanceOf(address(join)), 
            joinBalanceBefore - FullMath.mulDiv(WAD, accrual, WAD)
        );
    }

    function testRedeemByTransferAndApprove() public {
        console.log("redeems by transfer and approve combination");
        uint256 ownerBalanceBefore = IERC20(fyToken.underlying()).balanceOf(address(this));
        uint256 joinBalanceBefore = IERC20(fyToken.underlying()).balanceOf(address(join));
        fyToken.transfer(address(fyToken), WAD / 2);
        assertEq(fyToken.balanceOf(address(this)), WAD / 2);
        vm.expectEmit(true, true, false, true);
        emit Redeemed(
            address(this), 
            address(this), 
            WAD,
            FullMath.mulDiv(WAD, accrual, WAD)
        );
        fyToken.redeem(WAD, address(this), address(this));
        assertEq(
            IERC20(fyToken.underlying()).balanceOf(address(this)), 
            ownerBalanceBefore + FullMath.mulDiv(WAD, accrual, WAD)
        );
        assertEq(
            IERC20(fyToken.underlying()).balanceOf(address(join)), 
            joinBalanceBefore - FullMath.mulDiv(WAD, accrual, WAD)
        );        
    }

    function testRedeemByBatch() public {
        console.log("redeems by transferring to the fyToken contract in a batch");
        uint256 ownerBalanceBefore = IERC20(fyToken.underlying()).balanceOf(address(this));
        uint256 joinBalanceBefore = IERC20(fyToken.underlying()).balanceOf(address(join));
        fyToken.approve(address(ladle), WAD);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(ILadleCustom(address(ladle)).transfer.selector, address(fyToken), address(fyToken), WAD);
        calls[1] = abi.encodeWithSelector(ILadleCustom(address(ladle)).redeem.selector, seriesId, address(this), WAD);
        ILadleCustom(address(ladle)).batch(calls);
        assertEq(
            IERC20(fyToken.underlying()).balanceOf(address(this)), 
            ownerBalanceBefore + FullMath.mulDiv(WAD, accrual, WAD)
        );
        assertEq(
            IERC20(fyToken.underlying()).balanceOf(address(join)), 
            joinBalanceBefore - FullMath.mulDiv(WAD, accrual, WAD)
        );
    }

    function testRedeemByBatchWithZeroAmount() public {
        console.log("redeems with an amount of 0 by transferring to the fyToken contract in a batch");
        uint256 ownerBalanceBefore = IERC20(fyToken.underlying()).balanceOf(address(this));
        uint256 joinBalanceBefore = IERC20(fyToken.underlying()).balanceOf(address(join));
        fyToken.approve(address(ladle), WAD);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(ILadleCustom(address(ladle)).transfer.selector, address(fyToken), address(fyToken), WAD);
        calls[1] = abi.encodeWithSelector(ILadleCustom(address(ladle)).redeem.selector, seriesId, address(this), 0);
        ILadleCustom(address(ladle)).batch(calls);
        assertEq(
            IERC20(fyToken.underlying()).balanceOf(address(this)), 
            ownerBalanceBefore + FullMath.mulDiv(WAD, accrual, WAD)
        );
        assertEq(
            IERC20(fyToken.underlying()).balanceOf(address(join)), 
            joinBalanceBefore - FullMath.mulDiv(WAD, accrual, WAD)
        );
    }

    function testRedeemERC5095() public {
        console.log("redeems with ERC5095 redeem");
        uint256 ownerBalanceBefore = IERC20(fyToken.underlying()).balanceOf(address(this));
        uint256 joinBalanceBefore = IERC20(fyToken.underlying()).balanceOf(address(join));
        vm.expectEmit(true, true, false, true);
        emit Redeemed(
            address(this), 
            address(this), 
            WAD, 
            FullMath.mulDiv(WAD, accrual, WAD)
        );
        fyToken.redeem(WAD, address(this), address(this));
        assertEq(
            IERC20(fyToken.underlying()).balanceOf(address(this)), 
            ownerBalanceBefore + FullMath.mulDiv(WAD, accrual, WAD)
        );
        assertEq(
            IERC20(fyToken.underlying()).balanceOf(address(join)), 
            joinBalanceBefore - FullMath.mulDiv(WAD, accrual, WAD)
        );        
    }

    function testRedeemWithZeroAmount() public {
        console.log("Redeems the contract's balance when amount is 0");
        uint256 ownerBalanceBefore = IERC20(fyToken.underlying()).balanceOf(address(this));
        uint256 joinBalanceBefore = IERC20(fyToken.underlying()).balanceOf(address(join));
        deal(address(fyToken), address(fyToken), WAD * 10);

        vm.expectEmit(true, true, false, true);
        emit Redeemed(
            address(this), 
            address(this), 
            WAD * 10, 
            FullMath.mulDiv(WAD * 10, accrual, WAD)
        );
        fyToken.redeem(0, address(this), address(this));
        assertEq(
            fyToken.balanceOf(address(fyToken)), 
            0
        );
        assertEq(
            IERC20(fyToken.underlying()).balanceOf(address(this)), 
            ownerBalanceBefore + FullMath.mulDiv(WAD * 10, accrual, WAD)
        );
        assertEq(
            IERC20(fyToken.underlying()).balanceOf(address(join)),
            joinBalanceBefore - FullMath.mulDiv(WAD * 10, accrual, WAD)
        );
    }

    function testRedeemApproval() public {
        console.log("can redeem only the approved amount from holder");
        uint256 ownerBalanceBefore = IERC20(fyToken.underlying()).balanceOf(address(this));
        uint256 joinBalanceBefore = IERC20(fyToken.underlying()).balanceOf(address(join));
        deal(address(fyToken), fyTokenHolder, WAD * 5);
        vm.prank(fyTokenHolder);
        fyToken.approve(address(this), WAD * 5);

        vm.expectRevert("ERC20: Insufficient approval");
        fyToken.redeem(
            WAD * 10, 
            address(this), 
            fyTokenHolder
        );

        fyToken.redeem(
            WAD * 4,
            address(this),
            fyTokenHolder
        );
        assertEq(fyToken.balanceOf(fyTokenHolder), WAD);
        assertEq(
            IERC20(fyToken.underlying()).balanceOf(address(this)), 
            ownerBalanceBefore + FullMath.mulDiv(WAD * 4, accrual, WAD)
        );
        assertEq(
            IERC20(fyToken.underlying()).balanceOf(address(join)),
            joinBalanceBefore - FullMath.mulDiv(WAD * 4, accrual, WAD)
        );
    }

    function testWithdrawERC5095() public {
        console.log("withdrwas with ERC5095 withdraw");
        uint256 ownerBalanceBefore = IERC20(fyToken.underlying()).balanceOf(address(this));
        uint256 joinBalanceBefore = IERC20(fyToken.underlying()).balanceOf(address(join));
        vm.expectEmit(true, true, false, true);
        emit Redeemed(
            address(this), 
            address(this), 
            WAD, 
            FullMath.mulDiv(WAD, accrual, WAD)
        );
        fyToken.withdraw(FullMath.mulDiv(WAD, accrual, WAD), address(this), address(this));
        assertEq(
            IERC20(fyToken.underlying()).balanceOf(address(this)), 
            ownerBalanceBefore + FullMath.mulDiv(WAD, accrual, WAD)
        );
        assertEq(
            IERC20(fyToken.underlying()).balanceOf(address(join)), 
            joinBalanceBefore - FullMath.mulDiv(WAD, accrual, WAD)
        );
    }

    function testWithdrawWithZeroAmount() public {
        console.log("Withdraws the contract's balance when amount is 0");
        uint256 ownerBalanceBefore = IERC20(fyToken.underlying()).balanceOf(address(this));
        uint256 joinBalanceBefore = IERC20(fyToken.underlying()).balanceOf(address(join));
        deal(address(fyToken), address(fyToken), WAD * 10);

        vm.expectEmit(true, true, false, true);
        emit Redeemed(
            address(this), 
            address(this), 
            WAD * 10, 
            FullMath.mulDiv(WAD * 10, accrual, WAD)
        );
        fyToken.withdraw(0, address(this), address(this));
        assertEq(
            fyToken.balanceOf(address(fyToken)), 
            0
        );
        assertEq(
            IERC20(fyToken.underlying()).balanceOf(address(this)), 
            ownerBalanceBefore + FullMath.mulDiv(WAD * 10, accrual, WAD)
        );
        assertEq(
            IERC20(fyToken.underlying()).balanceOf(address(join)),
            joinBalanceBefore - FullMath.mulDiv(WAD * 10, accrual, WAD)
        );
    }

    function testWithdrawApproval() public {
        console.log("can withdraw only the approved amount from holder");
        uint256 ownerBalanceBefore = IERC20(fyToken.underlying()).balanceOf(address(this));
        uint256 joinBalanceBefore = IERC20(fyToken.underlying()).balanceOf(address(join));
        deal(address(fyToken), fyTokenHolder, WAD * 5);
        vm.prank(fyTokenHolder);
        fyToken.approve(address(this), WAD * 5);

        uint256 amountToWithdraw = fyToken.convertToUnderlying(WAD * 10);     // so revert works properly
        vm.expectRevert("ERC20: Insufficient approval");
        fyToken.withdraw(
            amountToWithdraw,
            address(this),
            fyTokenHolder
        );

        fyToken.withdraw(
            fyToken.convertToUnderlying(WAD * 4),
            address(this),
            fyTokenHolder
        );
        assertEq(fyToken.balanceOf(fyTokenHolder), WAD);
        assertEq(
            IERC20(fyToken.underlying()).balanceOf(address(this)),
            ownerBalanceBefore + FullMath.mulDiv(WAD * 4, accrual, WAD)
        );
        assertEq(
            IERC20(fyToken.underlying()).balanceOf(address(join)),
            joinBalanceBefore - FullMath.mulDiv(WAD * 4, accrual, WAD)
        );
    }
}