
// SPDX-License-Identifier: MIT
pragma solidity ^0.5.0;

import "./flashloan/FlashLoanReceiverBase.sol";
import './compound/CToken.sol';
import './Governable.sol';
import './dependency.sol';
import './swap/SwapWrapper.sol';
import './swap/uniswap/IUniswapV2Router02.sol';

contract RepayLoan is FlashLoanReceiverBase, Governable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    SwapWrapper public swap;

    event RepayedLoan(
        address indexed initiator,
        address indexed asset,
        uint256 repayAmount,
        uint256 backFtokenAmount
    );

    struct FTokenParams {
        address debtFToken;
        address collateralFToken;
        uint256 collateralFTokenAmount;
        address[] swapRoute;
    }

    constructor(IFlashLoan _flashLoan, address _governance, address _swapWrapper) public
        FlashLoanReceiverBase(_flashLoan)
        Governable(_governance) {
        require(_swapWrapper != address(0), "RepayLoan: invalid parameter");
        swap = SwapWrapper(_swapWrapper);
    }

    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external returns (bool) {
        require(msg.sender == address(FLASHLOAN_POOL), "RepayLoan: caller is not flashloan contract");

        FTokenParams memory ftokenParams = _decodeParams(params);

        (uint256 repaidAmount, uint256 backFtokenAmount) = _repay(initiator, assets[0],
                amounts[0], premiums[0], ftokenParams.debtFToken, ftokenParams.collateralFToken,
                ftokenParams.collateralFTokenAmount, ftokenParams.swapRoute);

        IERC20(assets[0]).safeApprove(address(FLASHLOAN_POOL), 0);
        IERC20(assets[0]).safeApprove(address(FLASHLOAN_POOL), amounts[0].add(premiums[0]));

        emit RepayedLoan(
            initiator,
            assets[0],
            repaidAmount,
            backFtokenAmount
        );

        return true;
    }

    function withdrawERC20(address _token, address _account, uint256 amount) public onlyGovernance returns (uint256) {
        IERC20 token = IERC20(_token);
        if (amount > token.balanceOf(address(this))) {
            amount = token.balanceOf(address(this));
        }
        token.safeTransfer(_account, amount);
        return amount;
    }

    function _pullFtoken(
        address initiator,
        address ftoken,
        uint256 amount,
        uint256 underlyingAmount) internal {

        IERC20(ftoken).safeTransferFrom(initiator, address(this), amount);
        uint err = CToken(ftoken).redeemUnderlying(underlyingAmount);
        require(err == 0, "RepayLoan: compound redeem failed");
    }

    function _repay(
        address initiator,
        address asset,
        uint256 amount,
        uint256 premium,
        address fDebt,
        address fCollateral,
        uint256 ftokenAmount,
        address[] memory swapRoute) internal returns (uint256, uint256) {

        uint256 repaidAmount = CToken(fDebt).borrowBalanceCurrent(initiator);
        if (amount < repaidAmount) {
            repaidAmount = amount;
        }

        IERC20(asset).safeApprove(fDebt, 0);
        IERC20(asset).safeApprove(fDebt, repaidAmount);
        uint err = CToken(fDebt).repayBorrowBehalf(initiator, repaidAmount);
        require(err == 0, 'RepayLoan: compound repay failed');

        if (fDebt != fCollateral) {
            require(swapRoute.length > 1, "RepayLoan: invalid swap route");
            uint256 maxSwapAmount = CToken(fCollateral).exchangeRateCurrent().mul(ftokenAmount).div(1e18);
            if (repaidAmount < amount) {
                maxSwapAmount = maxSwapAmount.mul(repaidAmount).div(amount);
            }

            uint256 neededForFlashLoanDebt = repaidAmount.add(premium);
            uint256[] memory amountsIn = IUniswapV2Router02(swap.router()).getAmountsIn(neededForFlashLoanDebt, swapRoute);
            require(amountsIn[0] <= maxSwapAmount, 'RepayLoan: slippage too high');

            _pullFtoken(initiator, fCollateral, ftokenAmount, maxSwapAmount);

            address underlying = CToken(fCollateral).underlying();
            IERC20(underlying).safeApprove(address(swap), 0);
            IERC20(underlying).safeApprove(address(swap), maxSwapAmount);

            (uint256 amountIn,) = swap.swapTokensForExactTokens(
                    neededForFlashLoanDebt, swapRoute, maxSwapAmount);

            if (amountIn < maxSwapAmount) {
                uint256 mintAmount = maxSwapAmount.sub(amountIn);
                IERC20(underlying).safeApprove(fCollateral, 0);
                IERC20(underlying).safeApprove(fCollateral, mintAmount);

                err = CToken(fCollateral).mint(mintAmount);
                require(err == 0, 'RepayLoan: compound mint failed');
            }
        }
        else {
            _pullFtoken(initiator, fCollateral, ftokenAmount, repaidAmount.add(premium));
        }

        uint256 backFtokenAmount = CToken(fCollateral).balanceOf(address(this));
        IERC20(fCollateral).safeTransfer(initiator, backFtokenAmount);

        return (repaidAmount, backFtokenAmount);
    }

    function _decodeParams(bytes memory params) internal pure returns (FTokenParams memory) {
        (address debtFToken, address collateralFToken, uint256 amount, address[] memory swapRoute)
            = abi.decode(params, (address, address, uint256, address[]));

        return FTokenParams(debtFToken, collateralFToken, amount, swapRoute);
    }

}
