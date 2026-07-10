// SPDX-License-Identifier: MIT
pragma solidity >=0.7.6 <0.8.0;
pragma experimental ABIEncoderV2;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../contracts/FeeAMM.sol";

contract MockTIP20Basic is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 100_000_000e6);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract FeeAMMBasicInvariantTest is Test {
    FeeAMM public feeAmm;
    MockTIP20Basic public userToken;
    MockTIP20Basic public validatorToken;

    function setUp() public {
        feeAmm = new FeeAMM();
        userToken = new MockTIP20Basic("User TIP-20 USD", "uUSD");
        validatorToken = new MockTIP20Basic("Validator TIP-20 USD", "vUSD");
    }

    function _mintAndApprove(
        address user,
        uint256 amountUserToken,
        uint256 amountValidatorToken
    ) internal {
        if (amountUserToken > 0) {
            userToken.mint(user, amountUserToken);
        }
        if (amountValidatorToken > 0) {
            validatorToken.mint(user, amountValidatorToken);
        }
        vm.startPrank(user);
        userToken.approve(address(feeAmm), type(uint256).max);
        validatorToken.approve(address(feeAmm), type(uint256).max);
        vm.stopPrank();
    }

    function _seedValidatorLiquidity(
        address provider,
        uint256 amountValidatorToken
    ) internal returns (bytes32 poolId) {
        _mintAndApprove(provider, 0, amountValidatorToken);
        vm.startPrank(provider);
        feeAmm.mint(
            address(userToken),
            address(validatorToken),
            amountValidatorToken,
            provider
        );
        vm.stopPrank();

        poolId = feeAmm.getPoolId(address(userToken), address(validatorToken));
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /**
     * @notice Basic happy-path mint/burn round-trip.
     * @dev Should pass with or without the reentrancy patch.
     */
    function testMintBurnRoundTripBasic() public {
        address lp = makeAddr("lp");
        bytes32 poolId = _seedValidatorLiquidity(lp, 200_000e6);

        address swapper = makeAddr("swapper");
        _mintAndApprove(swapper, 50_000e6, 0);
        vm.startPrank(swapper);
        feeAmm.executeFeeSwap(
            address(userToken),
            address(validatorToken),
            10_000e6
        );
        vm.stopPrank();

        uint256 lpBalance = feeAmm.liquidityBalances(poolId, lp);
        uint256 burnAmount = lpBalance / 2;

        FeeAMM.Pool memory poolBefore = feeAmm.getPool(
            address(userToken),
            address(validatorToken)
        );

        vm.startPrank(lp);
        feeAmm.burn(
            address(userToken),
            address(validatorToken),
            burnAmount,
            lp
        );
        vm.stopPrank();

        FeeAMM.Pool memory poolAfter = feeAmm.getPool(
            address(userToken),
            address(validatorToken)
        );

        // Burning should not increase pool reserves
        assertTrue(
            poolAfter.reserveUserToken <= poolBefore.reserveUserToken,
            "Reserve user token should not increase"
        );
        assertTrue(
            poolAfter.reserveValidatorToken <= poolBefore.reserveValidatorToken,
            "Reserve validator token should not increase"
        );

        uint256 remainingLp = feeAmm.liquidityBalances(poolId, lp);
        assertEq(remainingLp, lpBalance - burnAmount, "LP balance mismatch");
    }

    /**
     * @notice Swap sanity: reserves move in opposite directions for a swap.
     * @dev Should pass regardless of reentrancy patch.
     */
    function testExecuteFeeSwapMovesReserves() public {
        _seedValidatorLiquidity(makeAddr("lp"), 200_000e6);

        FeeAMM.Pool memory beforeSwap = feeAmm.getPool(
            address(userToken),
            address(validatorToken)
        );

        address swapper = makeAddr("swapper");
        _mintAndApprove(swapper, 50_000e6, 0);

        vm.startPrank(swapper);
        feeAmm.executeFeeSwap(
            address(userToken),
            address(validatorToken),
            10_000e6
        );
        vm.stopPrank();

        FeeAMM.Pool memory afterSwap = feeAmm.getPool(
            address(userToken),
            address(validatorToken)
        );

        // For a user->validator swap, user reserve should increase, validator reserve should decrease
        assertTrue(
            afterSwap.reserveUserToken > beforeSwap.reserveUserToken,
            "User reserve should increase after swap"
        );
        assertTrue(
            afterSwap.reserveValidatorToken < beforeSwap.reserveValidatorToken,
            "Validator reserve should decrease after swap"
        );
    }

    /**
     * @notice Invariant: LP balances sum to totalSupply minus MIN_LIQUIDITY.
     */
    function testInvariantTotalSupplyMatchesLpSumPlusMinLiquidity() public {
        address lp1 = makeAddr("lp1");
        address lp2 = makeAddr("lp2");
        _mintAndApprove(lp1, 0, 300_000e6);
        _mintAndApprove(lp2, 0, 200_000e6);

        vm.startPrank(lp1);
        feeAmm.mint(
            address(userToken),
            address(validatorToken),
            150_000e6,
            lp1
        );
        vm.stopPrank();

        vm.startPrank(lp2);
        feeAmm.mint(
            address(userToken),
            address(validatorToken),
            100_000e6,
            lp2
        );
        vm.stopPrank();

        bytes32 poolId = feeAmm.getPoolId(
            address(userToken),
            address(validatorToken)
        );
        uint256 lp1Bal = feeAmm.liquidityBalances(poolId, lp1);
        uint256 lp2Bal = feeAmm.liquidityBalances(poolId, lp2);
        uint256 totalSupply = feeAmm.totalSupply(poolId);

        assertEq(
            totalSupply,
            lp1Bal + lp2Bal + feeAmm.MIN_LIQUIDITY(),
            "LP sum should equal totalSupply minus MIN_LIQUIDITY"
        );
    }

    /**
     * @notice Invariant: burning never increases reserves.
     */
    function testInvariantBurnWithinReserves() public {
        address lp = makeAddr("lpBurn");
        bytes32 poolId = _seedValidatorLiquidity(lp, 200_000e6);

        address swapper = makeAddr("swapper2");
        _mintAndApprove(swapper, 50_000e6, 0);
        vm.startPrank(swapper);
        feeAmm.executeFeeSwap(
            address(userToken),
            address(validatorToken),
            10_000e6
        );
        vm.stopPrank();

        uint256 lpBal = feeAmm.liquidityBalances(poolId, lp);
        uint256 burnAmount = _min(lpBal / 2, lpBal);

        FeeAMM.Pool memory beforeBurn = feeAmm.getPool(
            address(userToken),
            address(validatorToken)
        );

        vm.startPrank(lp);
        feeAmm.burn(
            address(userToken),
            address(validatorToken),
            burnAmount,
            lp
        );
        vm.stopPrank();

        FeeAMM.Pool memory afterBurn = feeAmm.getPool(
            address(userToken),
            address(validatorToken)
        );

        assertTrue(
            afterBurn.reserveUserToken <= beforeBurn.reserveUserToken,
            "User reserve should not increase on burn"
        );
        assertTrue(
            afterBurn.reserveValidatorToken <= beforeBurn.reserveValidatorToken,
            "Validator reserve should not increase on burn"
        );
    }
}

