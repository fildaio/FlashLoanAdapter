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
        address assetFrom;
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
    }

    constructor(IFlashLoan _flashLoan, address _governance,
            address _swapWrapper, address _weth, address _fETH, address _feeManager, address _comptroller) public
        BaseAdapter(_flashLoan, _governance, _swapWrapper, _weth, _fETH, _feeManager) {
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

        vars.toAmount = _swapAndDeposit(
            vars.asset,
            vars.amount,
            vars.premium,
            initiator,
            handlerParams.assetFromFToken,
            handlerParams.assetToFToken,
            handlerParams.fromFTokenAmount,
            handlerParams.swapPath,
            handlerParams.minOut,
            vars.fee
            );

        if (vars.fee > 0) {
            IERC20(vars.asset).safeTransfer(owner(), vars.fee);
        }

        IERC20(vars.asset).safeApprove(address(FLASHLOAN_POOL), 0);
        IERC20(vars.asset).safeApprove(address(FLASHLOAN_POOL), vars.amount.add(vars.premium));

        vars.fromAmount = CToken(handlerParams.assetFromFToken).exchangeRateCurrent().mul(handlerParams.fromFTokenAmount).div(1e18);
        vars.assetFrom = handlerParams.assetFromFToken == fETH ?
                address(_WETH) : CToken(handlerParams.assetFromFToken).underlying();

        emit LiquiditySwaped(
            vars.assetFrom,
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
        address assetFromFToken,
        address assetToFToken,
        uint256 fromFTokenAmount,
        address[] memory swapPath,
        uint256 minOut,
        uint256 fee) internal returns (uint256) {

        require(swapPath.length > 0, "LiquiditySwap: no swap route");

        HandleLocalParams memory vars;

        // mint TO asset;
        if (assetToFToken == fETH) {
            _WETH.withdraw(amount);
            CEther(assetToFToken).mint.value(amount)();
        } else {
            IERC20(asset).safeApprove(assetToFToken, 0);
            IERC20(asset).safeApprove(assetToFToken, amount);

            vars.err = CToken(assetToFToken).mint(amount);
            require(vars.err == 0, "LiquiditySwap: compound mint failed");
        }

        _pullFtoken(initiator, assetFromFToken, fromFTokenAmount);

        vars.neededForFlashLoanDebt = amount.add(premium).add(fee);
        vars.fromUnderlying = assetFromFToken == fETH ? address(_WETH) : CToken(assetFromFToken).underlying();

        vars.fromTokenAmount = IERC20(vars.fromUnderlying).balanceOf(address(this));
        uint256[] memory amountsOut = IUniswapV2Router02(swap.router())
                .getAmountsOut(vars.fromTokenAmount, swapPath);
        require(amountsOut[amountsOut.length - 1] >= minOut, 'LiquiditySwap: slippage too high');
        require(amountsOut[amountsOut.length - 1] >= vars.neededForFlashLoanDebt, "LiquiditySwap: From asset not enough");

        IERC20(vars.fromUnderlying).safeApprove(address(swap), 0);
        IERC20(vars.fromUnderlying).safeApprove(address(swap), vars.fromTokenAmount);

        (, vars.amountOut) = swap.swapExactTokensForTokens(vars.fromTokenAmount, swapPath, minOut);
        if (vars.amountOut > vars.neededForFlashLoanDebt) {
            vars.extraMintAmount = vars.amountOut.sub(vars.neededForFlashLoanDebt);
            if (assetToFToken == fETH) {
                _WETH.withdraw(vars.extraMintAmount);
                CEther(assetToFToken).mint.value(vars.extraMintAmount)();
            } else {
                IERC20(asset).safeApprove(assetToFToken, 0);
                IERC20(asset).safeApprove(assetToFToken, vars.extraMintAmount);

                vars.err = CToken(assetToFToken).mint(vars.extraMintAmount);
                require(vars.err == 0, 'LiquiditySwap: compound mint failed');
            }
        }

        vars.toFTokenAmount = IERC20(assetToFToken).balanceOf(address(this));
        // transfer ftoken to initiator
        IERC20(assetToFToken).safeTransfer(initiator, vars.toFTokenAmount);

        (vars.err, , vars.shortfall) = comptroller.getAccountLiquidity(initiator);
        require(vars.err == 0, 'LiquiditySwap: comptroller getAccountLiquidity failed');
        require(vars.shortfall == 0, "LiquiditySwap: initiator is shortfall after liquidity swap");

        return CToken(assetToFToken).exchangeRateCurrent().mul(vars.toFTokenAmount).div(1e18);
    }

    function _decodeParams(bytes memory params) internal pure returns (LiquiditySwapParams memory) {
        (address assetFromFToken, address assetToFToken, uint256 fromFTokenAmount, address[] memory swapPath, uint256 minOut)
            = abi.decode(params, (address, address, uint256, address[], uint256));

        return LiquiditySwapParams(assetFromFToken, assetToFToken, fromFTokenAmount, swapPath, minOut);
    }

    function() external payable {}
}
