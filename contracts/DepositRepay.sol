
// SPDX-License-Identifier: MIT
pragma solidity ^0.5.0;

import './BaseAdapter.sol';
import './swap/uniswap/IUniswapV2Router02.sol';
import './compound/CEther.sol';
import './oracle/ChainlinkAdaptor.sol';

contract IERC20Extented is IERC20 {
    function decimals() public view returns (uint8);
}

contract DepositRepay is BaseAdapter {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    event Repayed(
        address indexed initiator,
        address indexed asset,
        uint256 repayAmount,
        uint256 backFtokenAmount,
        uint256 fee
    );

    struct DepositRepayParams {
        address debtFToken;
        address collateralFToken;
        uint256 collateralFTokenAmount;
        address[] swapARoute;
        uint256 minOut;
        address[] swapBRoute;
        uint256 maxIn;
    }

    struct RepayLocalParams {
        address asset;
        uint256 amount;
        uint256 premium;
        uint256 fee;
        address initiator;
    }

    struct ImplLocalParams {
        uint err;
        uint256 ftokenAmount;
        uint256 debt;
        uint256 repayAmount;
        uint256 maxCollateralAmount;
        uint256 backFtokenAmount;
    }

    event OracleChanged(
        address indexed from,
        address indexed to
    );

    ChainlinkAdaptor public oracle;
    address public fHUSD;

    constructor(IFlashLoan _flashLoan, address _governance,
            address _swapWrapper, address _weth, address _fETH, address _feeManager, address _oracle, address _fHUSD) public
        BaseAdapter(_flashLoan, _governance, _swapWrapper, _weth, _fETH, _feeManager) {

        require(_fHUSD != address(0), "DepositRepay: fHUSD address can not be zero");
        require(Address.isContract(_oracle), "DepositRepay: oracle address is not contract");
        oracle = ChainlinkAdaptor(_oracle);

        fHUSD = _fHUSD;
    }

    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external returns (bool) {
        require(msg.sender == address(FLASHLOAN_POOL), "RepayLoan: caller is not flashloan contract");

        DepositRepayParams memory ftokenParams = _decodeParams(params);
        RepayLocalParams memory vars;
        vars.asset = assets[0];
        vars.amount = amounts[0];
        vars.premium = premiums[0];
        vars.fee = feeManager.getFee(initiator, vars.amount);
        vars.initiator = initiator;

        _repay(ftokenParams, vars);

        if (vars.fee > 0) {
            IERC20(vars.asset).safeTransfer(owner(), vars.fee);
        }

        IERC20(vars.asset).safeApprove(address(FLASHLOAN_POOL), 0);
        IERC20(vars.asset).safeApprove(address(FLASHLOAN_POOL), vars.amount.add(vars.premium));


        return true;
    }

    function _repay(
        DepositRepayParams memory params,
        RepayLocalParams memory vars
        ) internal {

        require(vars.asset == getUnderlying(params.collateralFToken), "DepositRepay: asset and collateral ftoken not match");

        ImplLocalParams memory local;

        if (params.collateralFToken == fETH) {
            _WETH.withdraw(vars.amount);
            CEther(params.collateralFToken).mint.value(vars.amount)();
        } else {
            IERC20(vars.asset).safeApprove(params.collateralFToken, 0);
            IERC20(vars.asset).safeApprove(params.collateralFToken, vars.amount);

            local.err = CToken(params.collateralFToken).mint(vars.amount);
            require(local.err == 0, 'DepositRepay: compound mint failed');
        }


        local.ftokenAmount = CToken(params.collateralFToken).balanceOf(address(this));
        IERC20(params.collateralFToken).safeTransfer(vars.initiator, local.ftokenAmount);

        local.debt = CToken(params.debtFToken).borrowBalanceCurrent(vars.initiator);
        local.repayAmount = local.debt;
        local.maxCollateralAmount = CToken(params.collateralFToken)
                .exchangeRateCurrent().mul(params.collateralFTokenAmount).div(1e18).sub(vars.premium).sub(vars.fee);

        if (params.debtFToken != params.collateralFToken) {

            if (params.swapARoute.length > 1) {
                uint256[] memory amounts = IUniswapV2Router02(swap.router()).getAmountsOut(local.maxCollateralAmount, params.swapARoute);
                require(amounts[amounts.length - 1] > params.minOut, 'DepositRepay: swap A slippage too high');

                if (amounts[amounts.length - 1] >= local.debt) {
                    swapExactDebts(vars.initiator, local.debt, params);
                } else {
                    _pullFtoken(vars.initiator, params.collateralFToken, params.collateralFTokenAmount, local.maxCollateralAmount);

                    IERC20(vars.asset).safeApprove(address(swap), 0);
                    IERC20(vars.asset).safeApprove(address(swap), local.maxCollateralAmount);
                    (, local.repayAmount) = swap.swapExactTokensForTokens(
                            local.maxCollateralAmount, params.swapARoute, params.minOut);
                }
            } else {
                swapExactDebts(vars.initiator, local.debt, params);
            }

        } else {
            local.repayAmount = local.maxCollateralAmount > local.debt ? local.debt : local.maxCollateralAmount;
            _pullFtoken(vars.initiator, params.collateralFToken, params.collateralFTokenAmount, local.repayAmount);
        }

        if (params.debtFToken == fETH) {
            _WETH.withdraw(local.repayAmount);
            // repay loan.
            CEther(params.debtFToken).repayBorrowBehalf.value(local.repayAmount)(vars.initiator);
        } else {
            IERC20(getUnderlying(params.debtFToken)).safeApprove(params.debtFToken, 0);
            IERC20(getUnderlying(params.debtFToken)).safeApprove(params.debtFToken, local.repayAmount);
            local.err = CToken(params.debtFToken).repayBorrowBehalf(vars.initiator, local.repayAmount);
            require(local.err == 0, 'DepositRepay: compound repay failed');
        }

        _pullFtoken(vars.initiator, params.collateralFToken, local.ftokenAmount, vars.amount.add(vars.premium).add(vars.fee));

        local.backFtokenAmount = CToken(params.collateralFToken).balanceOf(address(this));
        if (local.backFtokenAmount > 0) {
            IERC20(params.collateralFToken).safeTransfer(
                    local.backFtokenAmount > 10000 ? vars.initiator : owner(), local.backFtokenAmount);
        }

        uint256 spendAmount = CToken(params.collateralFToken)
                .exchangeRateCurrent().mul(params.collateralFTokenAmount.sub(local.backFtokenAmount)).div(1e18);
        require(checkByOracle(params.collateralFToken, spendAmount, params.debtFToken, local.repayAmount), "DepositRepay: slippage too high");
    }

    function swapExactDebts(
        address initiator,
        uint256 amountOut,
        DepositRepayParams memory params
        ) internal {
        require(params.swapBRoute.length > 1, 'DepositRepay: swap B route should not be empty');

        uint256[] memory amounts = IUniswapV2Router02(swap.router()).getAmountsIn(amountOut, params.swapBRoute);
        require(amounts[0] <= params.maxIn, 'DepositRepay: swap B slippage too high');

        _pullFtoken(initiator, params.collateralFToken, params.collateralFTokenAmount, amounts[0]);

        IERC20(params.swapBRoute[0]).safeApprove(address(swap), 0);
        IERC20(params.swapBRoute[0]).safeApprove(address(swap), amounts[0]);

        swap.swapTokensForExactTokens(amountOut, params.swapBRoute, params.maxIn);
    }

    function checkByOracle(address ftokenA, uint256 amountA, address ftokenB, uint256 amountB) private view returns (bool) {
        address underlyingA = getUnderlying(ftokenA);
        address underlyingB = getUnderlying(ftokenB);

        uint256 decimalsA = IERC20Extented(underlyingA).decimals();
        uint256 decimalsB = IERC20Extented(underlyingB).decimals();

        uint256 priceA = amountA.mul(getHUSDPrice(ftokenA, underlyingA)).div(10**decimalsA);
        uint256 priceB = amountB.mul(getHUSDPrice(ftokenB, underlyingB)).div(10**decimalsB);

        if (priceA <= priceB) return true;

        return priceA.sub(priceB) < priceA.mul(5).div(100);
    }

    function getHUSDPrice(address ftoken, address token) private view returns (uint256) {
        uint256 husdHTPrice = oracle.getUnderlyingPrice(CToken(fHUSD));
        uint256 tokenHTPrice = oracle.getUnderlyingPrice(CToken(ftoken));

        uint256 decimals = IERC20Extented(token).decimals();
        return tokenHTPrice.mul(10**decimals).div(husdHTPrice);
    }

    function getHtPrice() private view returns (uint256) {
        return uint256(1e36).div(oracle.getUnderlyingPrice(CToken(fHUSD)));
    }

    function _decodeParams(bytes memory params) internal pure returns (DepositRepayParams memory) {
        (
            address debtFToken,
            address collateralFToken,
            uint256 amount,
            address[] memory swapARoute,
            uint256 minOut,
            address[] memory swapBRoute,
            uint256 maxIn
        )
            = abi.decode(params, (address, address, uint256, address[], uint256, address[], uint256));

        return DepositRepayParams(debtFToken, collateralFToken, amount, swapARoute, minOut, swapBRoute, maxIn);
    }

    function setOracle(address _oracle) external onlyGovernance {
        require(Address.isContract(_oracle), "DepositRepay: oracle address is not contract");

        address from = address(oracle);
        oracle = ChainlinkAdaptor(_oracle);

        emit OracleChanged(from, _oracle);
    }

    function() external payable {}
}
