
// SPDX-License-Identifier: MIT
pragma solidity ^0.5.0;

import "./flashloan/FlashLoanReceiverBase.sol";
import './compound/CToken.sol';
import './Governable.sol';
import './dependency.sol';
import './swap/SwapWrapper.sol';
import './swap/uniswap/IUniswapV2Router02.sol';
import './WETH.sol';
import './compound/CEther.sol';
import './FeeManager.sol';

contract RepayLoan is FlashLoanReceiverBase, Governable, Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    SwapWrapper public swap;
    WETH public _WETH;
    address public fETH;
    FeeManager public feeManager;

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

    constructor(IFlashLoan _flashLoan, address _governance,
            address _swapWrapper, address _weth, address _fETH, address _feeManager) public
        FlashLoanReceiverBase(_flashLoan)
        Governable(_governance) {
        require(_swapWrapper != address(0) && _weth != address(0)
            && _fETH != address(0) && _feeManager != address(0), "RepayLoan: invalid parameter");

        swap = SwapWrapper(_swapWrapper);
        _WETH = WETH(_weth);
        fETH = _fETH;
        feeManager = FeeManager(_feeManager);
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
        RepayLocalParams memory vars;
        vars.asset = assets[0];
        vars.amount = amounts[0];
        vars.premium = premiums[0];
        vars.fee = feeManager.getFee(initiator, amounts[0]);

        (vars.repaidAmount, vars.backFtokenAmount) = _repay(initiator, vars.asset,
                vars.amount, vars.premium, vars.fee, ftokenParams.debtFToken, ftokenParams.collateralFToken,
                ftokenParams.collateralFTokenAmount, ftokenParams.swapRoute);

        if (vars.fee > 0) {
            IERC20(vars.asset).safeTransfer(owner(), vars.fee);
        }

        IERC20(vars.asset).safeApprove(address(FLASHLOAN_POOL), 0);
        IERC20(vars.asset).safeApprove(address(FLASHLOAN_POOL), amounts[0].add(premiums[0]));

        emit RepayedLoan(
            initiator,
            vars.asset,
            vars.repaidAmount,
            vars.backFtokenAmount,
            vars.fee
        );

        return true;
    }

    function withdrawERC20(address _token, address _account, uint256 amount) public onlyOwner {
        IERC20 token = IERC20(_token);
        if (amount > token.balanceOf(address(this))) {
            amount = token.balanceOf(address(this));
        }
        token.safeTransfer(_account, amount);
    }

    function _pullFtoken(
        address initiator,
        address ftoken,
        uint256 amount,
        uint256 underlyingAmount) internal {

        IERC20(ftoken).safeTransferFrom(initiator, address(this), amount);
        uint err = CToken(ftoken).redeemUnderlying(underlyingAmount);
        require(err == 0, "RepayLoan: compound redeem failed");

        if (ftoken == fETH) {
            _WETH.deposit.value(underlyingAmount)();
        }
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

    function setFeeManager(address _feeManager) external onlyGovernance {
        require(_feeManager != address(0), "RepayLoan: invalid parameter");
        feeManager = FeeManager(_feeManager);
    }
}
