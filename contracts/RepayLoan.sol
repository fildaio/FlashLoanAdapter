
// SPDX-License-Identifier: MIT
pragma solidity ^0.5.0;

import './BaseAdapter.sol';
import './swap/uniswap/IUniswapV2Router02.sol';
import './compound/CEther.sol';

contract RepayLoan is BaseAdapter {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    event RepayedLoan(
        address indexed initiator,
        address indexed asset,
        uint256 repayAmount,
        uint256 backFtokenAmount,
        uint256 fee
    );

    struct FTokenParams {
        address debtFToken;
        address collateralFToken;
        uint256 collateralFTokenAmount;
        address[] swapRoute;
    }

    struct RepayLocalParams {
        address asset;
        uint256 amount;
        uint256 premium;
        uint256 fee;
        uint256 repaidAmount;
        uint256 backFtokenAmount;
    }

    constructor(address _governance,
            address _swapWrapper, address _weth, address _fETH, address _feeManager, address _oracle, address _fHUSD) public
        BaseAdapter(_governance, _swapWrapper, _weth, _fETH, _feeManager, _oracle, _fHUSD)
        {}

    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external returns (bytes32) {
        require(IERC20(token).balanceOf(address(this)) == amount, "LiquiditySwap: token amount is not enough");

        FTokenParams memory ftokenParams = _decodeParams(data);
        RepayLocalParams memory vars;
        vars.asset = token;
        vars.amount = amount;
        vars.premium = fee;
        vars.fee = feeManager.getFee(initiator, vars.amount);

        (vars.repaidAmount, vars.backFtokenAmount) = _repay(initiator, vars.asset,
                vars.amount, vars.premium, vars.fee, ftokenParams.debtFToken, ftokenParams.collateralFToken,
                ftokenParams.collateralFTokenAmount, ftokenParams.swapRoute);

        if (vars.fee > 0) {
            IERC20(vars.asset).safeTransfer(owner(), vars.fee);
        }

        IERC20(vars.asset).safeApprove(msg.sender, 0);
        IERC20(vars.asset).safeApprove(msg.sender, vars.amount.add(vars.premium));

        emit RepayedLoan(
            initiator,
            vars.asset,
            vars.repaidAmount,
            vars.backFtokenAmount,
            vars.fee
        );

        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }

    function _repay(
        address initiator,
        address asset,
        uint256 amount,
        uint256 premium,
        uint256 fee,
        address fDebt,
        address fCollateral,
        uint256 ftokenAmount,
        address[] memory swapRoute) internal returns (uint256, uint256) {

        uint256 repaidAmount = CToken(fDebt).borrowBalanceCurrent(initiator);
        if (amount < repaidAmount) {
            repaidAmount = amount;
        }

        if (asset == address(_WETH)) {
            _WETH.withdraw(repaidAmount);
            // repay loan.
            CEther(fDebt).repayBorrowBehalf.value(repaidAmount)(initiator);
        } else {
            IERC20(asset).safeApprove(fDebt, 0);
            IERC20(asset).safeApprove(fDebt, repaidAmount);
            uint err = CToken(fDebt).repayBorrowBehalf(initiator, repaidAmount);
            require(err == 0, 'RepayLoan: compound repay failed');
        }

        if (fDebt != fCollateral) {
            require(swapRoute.length > 1, "RepayLoan: invalid swap route");
            uint256 maxSwapAmount = CToken(fCollateral).exchangeRateCurrent().mul(ftokenAmount).div(1e18);
            if (repaidAmount < amount) {
                maxSwapAmount = maxSwapAmount.mul(repaidAmount).div(amount);
            }

            uint256 neededForFlashLoanDebt = repaidAmount.add(premium).add(fee);
            uint256[] memory amountsIn = IUniswapV2Router02(swap.router()).getAmountsIn(neededForFlashLoanDebt, swapRoute);
            require(amountsIn[0] <= maxSwapAmount, 'RepayLoan: slippage too high');

            _pullFtoken(initiator, fCollateral, ftokenAmount, maxSwapAmount);

            address underlying;
            if (fCollateral == fETH) {
                underlying = address(_WETH);
            } else {
                underlying = CToken(fCollateral).underlying();
            }
            IERC20(underlying).safeApprove(address(swap), 0);
            IERC20(underlying).safeApprove(address(swap), maxSwapAmount);

            (uint256 amountIn,) = swap.swapTokensForExactTokens(
                    neededForFlashLoanDebt, swapRoute, maxSwapAmount);

            if (amountIn < maxSwapAmount) {
                uint256 mintAmount = maxSwapAmount.sub(amountIn);
                if (fCollateral == fETH) {
                    _WETH.withdraw(mintAmount);
                    CEther(fCollateral).mint.value(mintAmount)();
                } else {
                    IERC20(underlying).safeApprove(fCollateral, 0);
                    IERC20(underlying).safeApprove(fCollateral, mintAmount);

                    uint err = CToken(fCollateral).mint(mintAmount);
                    require(err == 0, 'RepayLoan: compound mint failed');
                }
            }
        }
        else {
            _pullFtoken(initiator, fCollateral, ftokenAmount, repaidAmount.add(premium).add(fee));
        }

        uint256 backFtokenAmount = CToken(fCollateral).balanceOf(address(this));
        if (backFtokenAmount > 0) {
            IERC20(fCollateral).safeTransfer(initiator, backFtokenAmount);
        }

        return (repaidAmount, backFtokenAmount);
    }

    function _decodeParams(bytes memory params) internal pure returns (FTokenParams memory) {
        (address debtFToken, address collateralFToken, uint256 amount, address[] memory swapRoute)
            = abi.decode(params, (address, address, uint256, address[]));

        return FTokenParams(debtFToken, collateralFToken, amount, swapRoute);
    }

    function() external payable {}
}
