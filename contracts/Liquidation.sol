// SPDX-License-Identifier: MIT
pragma solidity ^0.5.0;

import './BaseAdapter.sol';
import './compound/CEther.sol';
import './swap/uniswap/IUniswapV2Router02.sol';

contract Liquidation is BaseAdapter {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    event LiquidationEarned(
        address liquidator,
        address token,
        uint256 amount
    );

    struct LiquidationParams {
        address borrower;
        address fDebt;
        address fCollateral;
        address[] swapRepayPath;
        uint256 maxIn;
        address[] swapIncomePath;
        uint256 minOut;
    }

    struct LiquidationLocalParams {
        address debtToken;
        uint256 liquidateAmount;
        uint256 premium;
        uint256 fee;
        address initiator;
    }

    constructor(IFlashLoan _flashLoan, address _governance,
            address _swapWrapper, address _weth, address _fETH, address _feeManager, address _oracle, address _fHUSD) public
        BaseAdapter(_flashLoan, _governance, _swapWrapper, _weth, _fETH, _feeManager, _oracle, _fHUSD) {}


    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external returns (bool) {
        require(msg.sender == address(FLASHLOAN_POOL), "Liquidation: caller is not flashloan contract");

        LiquidationParams memory handlerParams = _decodeParams(params);

        LiquidationLocalParams memory vars;
        vars.debtToken = assets[0];
        vars.liquidateAmount = amounts[0];
        vars.premium = premiums[0];
        vars.initiator = initiator;
        vars.fee = feeManager.getFee(vars.initiator, vars.liquidateAmount);

        (address token, uint256 amount) = _liquidateAndSwap(handlerParams, vars);

        if (vars.fee > 0) {
            IERC20(vars.debtToken).safeTransfer(owner(), vars.fee);
        }

        IERC20(vars.debtToken).safeApprove(address(FLASHLOAN_POOL), 0);
        IERC20(vars.debtToken).safeApprove(address(FLASHLOAN_POOL), vars.liquidateAmount.add(vars.premium));

        emit LiquidationEarned(
            vars.initiator,
            token,
            amount
        );

        return true;
    }

    function _liquidateAndSwap(
        LiquidationParams memory params,
        LiquidationLocalParams memory vars
    ) internal returns (address, uint256) {

        if (params.fCollateral != params.fDebt) {
            require(params.swapRepayPath.length > 1, "Liquidation: swapRepayPath is invalid");
        }

        uint err = 0;
        // do liquidate
        if (params.fDebt == fETH) {
            _WETH.withdraw(vars.liquidateAmount);
            CEther(fETH).liquidateBorrow.value(vars.liquidateAmount)(params.borrower, params.fCollateral);
        } else {
            IERC20(vars.debtToken).safeApprove(params.fDebt, 0);
            IERC20(vars.debtToken).safeApprove(params.fDebt, vars.liquidateAmount);
            err = CToken(params.fDebt).liquidateBorrow(params.borrower, vars.liquidateAmount, CTokenInterface(params.fCollateral));
        }
        require(err == 0, "Liquidation: liquidateBorrow failed");

        // redeem collateral
        err = CToken(params.fCollateral).redeem(CToken(params.fCollateral).balanceOf(address(this)));
        require(err == 0, "Liquidation: redeem failed");
        if (params.fCollateral == fETH) {
             _WETH.deposit.value(address(this).balance)();
        }

        uint256 neededForFlashLoanDebt = vars.liquidateAmount.add(vars.premium).add(vars.fee);
        address underlying = params.fCollateral == fETH ? address(_WETH) : CToken(params.fCollateral).underlying();
        uint256 incomeAmount = 0;
        if (params.fCollateral != params.fDebt) {
            uint256[] memory amountsIn = IUniswapV2Router02(swap.router()).getAmountsIn(
                            neededForFlashLoanDebt, params.swapRepayPath);
            require(amountsIn[0] <= params.maxIn, 'Liquidation: swap repay slippage too high');

            IERC20(underlying).safeApprove(address(swap), 0);
            IERC20(underlying).safeApprove(address(swap), params.maxIn);

            swap.swapTokensForExactTokens(neededForFlashLoanDebt, params.swapRepayPath, params.maxIn);

            incomeAmount = IERC20(underlying).balanceOf(address(this));
        } else {
            incomeAmount = IERC20(underlying).balanceOf(address(this)).sub(neededForFlashLoanDebt);
        }

        address token = underlying;
        uint256 earned = incomeAmount;
        if (params.swapIncomePath.length > 1) {
            token = params.swapIncomePath[params.swapIncomePath.length - 1];
            uint256[] memory amountsOut = IUniswapV2Router02(swap.router())
                        .getAmountsOut(incomeAmount, params.swapIncomePath);
            require(amountsOut[amountsOut.length - 1] >= params.minOut, 'Liquidation: swap income slippage too high');

            IERC20(underlying).safeApprove(address(swap), 0);
            IERC20(underlying).safeApprove(address(swap), incomeAmount);

            (, earned) = swap.swapExactTokensForTokens(incomeAmount, params.swapIncomePath, params.minOut);
        }

        // transfer income to Liquidator
        IERC20(token).safeTransfer(vars.initiator, earned);

        return (token, earned);
    }


    function _decodeParams(bytes memory params) internal pure returns (LiquidationParams memory) {
        (
            address borrower,
            address fDebt,
            address fCollateral,
            address[] memory swapRepayPath,
            uint256 maxIn,
            address[] memory swapIncomePath,
            uint256 minOut
        ) = abi.decode(
            params,
            (address, address, address, address[], uint256, address[], uint256)
        );

        return LiquidationParams(borrower, fDebt, fCollateral, swapRepayPath, maxIn, swapIncomePath, minOut);
    }

    function() external payable {}
}
