// SPDX-License-Identifier: MIT
pragma solidity ^0.5.0;

import './BaseAdapter.sol';
import './compound/Comptroller.sol';
import './compound/CEther.sol';
import './swap/uniswap/IUniswapV2Router02.sol';

contract LiquiditySwap is BaseAdapter {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    Comptroller public comptroller;

    event LiquiditySwaped(
        address assetFrom,
        uint256 fromAmount,
        address assetTo,
        uint256 toAmount
    );

    struct LiquiditySwapParams {
        address assetFromFToken;
        address assetToFToken;
        uint256 fromFTokenAmount;
        address[] swapPath;
        uint256 minOut;
    }

    struct LiquiditySwapLocalParams {
        address asset;
        uint256 amount;
        uint256 premium;
        uint256 fee;
        uint256 fromAmount;
        uint256 toAmount;
    }

    struct HandleLocalParams {
        uint err;
        uint256 neededForFlashLoanDebt;
        address fromUnderlying;
        uint256 fromTokenAmount;
        uint256 amountOut;
        uint256 extraMintAmount;
        uint256 toFTokenAmount;
        uint256 liquidity;
        uint shortfall;
        uint256 fromAmount;
        uint256 toAmount;
    }

    constructor(IFlashLoan _flashLoan, address _governance,
            address _swapWrapper, address _weth, address _fETH, address _feeManager, address _oracle, address _fHUSD, address _comptroller) public
        BaseAdapter(_flashLoan, _governance, _swapWrapper, _weth, _fETH, _feeManager, _oracle, _fHUSD) {
        require(_comptroller != address(0), "LiquiditySwap: invalid argument");

        comptroller = Comptroller(_comptroller);
    }

    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external returns (bool) {
        require(msg.sender == address(FLASHLOAN_POOL), "LiquiditySwap: caller is not flashloan contract");

        LiquiditySwapParams memory handlerParams = _decodeParams(params);
        LiquiditySwapLocalParams memory vars;
        vars.asset = assets[0];
        vars.amount = amounts[0];
        vars.premium = premiums[0];
        vars.fee = feeManager.getFee(initiator, vars.amount);

        (vars.fromAmount, vars.toAmount) = _swapAndDeposit(
            vars.asset,
            vars.amount,
            vars.premium,
            initiator,
            handlerParams,
            vars.fee
            );

        if (vars.fee > 0) {
            IERC20(vars.asset).safeTransfer(owner(), vars.fee);
        }

        IERC20(vars.asset).safeApprove(address(FLASHLOAN_POOL), 0);
        IERC20(vars.asset).safeApprove(address(FLASHLOAN_POOL), vars.amount.add(vars.premium));

        emit LiquiditySwaped(
            getUnderlying(handlerParams.assetFromFToken),
            vars.fromAmount,
            vars.asset,
            vars.toAmount
        );

        return true;
    }

    function _swapAndDeposit(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        LiquiditySwapParams memory params,
        uint256 fee) internal returns (uint256, uint256) {

        require(params.swapPath.length > 0, "LiquiditySwap: no swap route");

        HandleLocalParams memory vars;

        // mint TO asset;
        if (params.assetToFToken == fETH) {
            _WETH.withdraw(amount);
            CEther(params.assetToFToken).mint.value(amount)();
        } else {
            IERC20(asset).safeApprove(params.assetToFToken, 0);
            IERC20(asset).safeApprove(params.assetToFToken, amount);

            vars.err = CToken(params.assetToFToken).mint(amount);
            require(vars.err == 0, "LiquiditySwap: compound mint failed");
        }

        vars.toFTokenAmount = IERC20(params.assetToFToken).balanceOf(address(this));
        // transfer ftoken to initiator
        IERC20(params.assetToFToken).safeTransfer(initiator, vars.toFTokenAmount);

        _pullFtoken(initiator, params.assetFromFToken, params.fromFTokenAmount);

        vars.neededForFlashLoanDebt = amount.add(premium).add(fee);
        vars.fromUnderlying = getUnderlying(params.assetFromFToken);

        vars.fromTokenAmount = IERC20(vars.fromUnderlying).balanceOf(address(this));
        uint256[] memory amountsOut = IUniswapV2Router02(swap.router())
                .getAmountsOut(vars.fromTokenAmount, params.swapPath);
        require(amountsOut[amountsOut.length - 1] >= params.minOut, 'LiquiditySwap: slippage too high');
        require(amountsOut[amountsOut.length - 1] >= vars.neededForFlashLoanDebt, "LiquiditySwap: From asset not enough");

        IERC20(vars.fromUnderlying).safeApprove(address(swap), 0);
        IERC20(vars.fromUnderlying).safeApprove(address(swap), vars.fromTokenAmount);

        (, vars.amountOut) = swap.swapExactTokensForTokens(vars.fromTokenAmount, params.swapPath, params.minOut);
        if (vars.amountOut > vars.neededForFlashLoanDebt) {
            vars.extraMintAmount = vars.amountOut.sub(vars.neededForFlashLoanDebt);
            if (params.assetToFToken == fETH) {
                _WETH.withdraw(vars.extraMintAmount);
                CEther(params.assetToFToken).mint.value(vars.extraMintAmount)();
            } else {
                IERC20(asset).safeApprove(params.assetToFToken, 0);
                IERC20(asset).safeApprove(params.assetToFToken, vars.extraMintAmount);

                vars.err = CToken(params.assetToFToken).mint(vars.extraMintAmount);
                require(vars.err == 0, 'LiquiditySwap: compound mint failed');
            }
        }

        if (IERC20(params.assetToFToken).balanceOf(address(this)) > 0) {
            vars.toFTokenAmount = vars.toFTokenAmount.add(IERC20(params.assetToFToken).balanceOf(address(this)));
            // transfer ftoken to initiator
            IERC20(params.assetToFToken).safeTransfer(initiator, IERC20(params.assetToFToken).balanceOf(address(this)));
        }

        (vars.err, , vars.shortfall) = comptroller.getAccountLiquidity(initiator);
        require(vars.err == 0, 'LiquiditySwap: comptroller getAccountLiquidity failed');
        require(vars.shortfall == 0, "LiquiditySwap: initiator is shortfall after liquidity swap");

        // check slippage by oracle.
        vars.fromAmount = CToken(params.assetFromFToken).exchangeRateCurrent().mul(params.fromFTokenAmount).div(1e18);
        vars.toAmount = CToken(params.assetToFToken).exchangeRateCurrent().mul(vars.toFTokenAmount).div(1e18);
        require(checkByOracle(params.assetFromFToken, vars.fromAmount, params.assetToFToken, vars.toAmount),
                "LiquiditySwap: check by oracle slippage too high");

        return (vars.fromAmount, vars.toAmount);
    }

    function _decodeParams(bytes memory params) internal pure returns (LiquiditySwapParams memory) {
        (address assetFromFToken, address assetToFToken, uint256 fromFTokenAmount, address[] memory swapPath, uint256 minOut)
            = abi.decode(params, (address, address, uint256, address[], uint256));

        return LiquiditySwapParams(assetFromFToken, assetToFToken, fromFTokenAmount, swapPath, minOut);
    }

    function() external payable {}
}
