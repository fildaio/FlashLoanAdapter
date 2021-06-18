
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
        uint8 mode; // 0: spend collateralFTokenAmount. 1: spend all ftoken of user. 2: repay all debt.
        address[] swapRoute;
        uint256 slippage;
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
        uint256 debt;
        uint256 repayAmount;
        uint256 maxSpendAmount;
        uint256 underlyingAmount;
        uint256 pullFTokenAmount;
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

        require(vars.asset == getUnderlying(params.collateralFToken),
                "DepositRepay: asset and collateral ftoken not match");

        ImplLocalParams memory local;


        local.pullFTokenAmount = params.mode == 1
                ? IERC20(params.collateralFToken).balanceOf(vars.initiator) : params.collateralFTokenAmount;
        local.underlyingAmount = CToken(params.collateralFToken)
                .exchangeRateCurrent().mul(local.pullFTokenAmount).div(1e18);

        local.maxSpendAmount = vars.amount > local.underlyingAmount
                ? local.underlyingAmount.sub(vars.premium).sub(vars.fee) : vars.amount.sub(vars.premium).sub(vars.fee);

        local.debt = CToken(params.debtFToken).borrowBalanceCurrent(vars.initiator);

        if (params.debtFToken != params.collateralFToken) {
            require(params.swapRoute.length > 1, "DepositRepay: swap route cannot be empty");

            // repay all det.
            if (params.mode == 2) {
                uint256[] memory amounts = IUniswapV2Router02(swap.router()).getAmountsIn(local.debt, params.swapRoute);
                require(amounts[0] <= params.slippage, 'DepositRepay: swap slippage too high');

                IERC20(vars.asset).safeApprove(address(swap), 0);
                IERC20(vars.asset).safeApprove(address(swap), amounts[0]);

                (, local.repayAmount) = swap.swapTokensForExactTokens(
                        local.debt, params.swapRoute, params.slippage);
            } else {
                uint256[] memory amounts = IUniswapV2Router02(swap.router()).getAmountsOut(local.maxSpendAmount, params.swapRoute);
                require(amounts[amounts.length - 1] > params.slippage, 'DepositRepay: swap slippage too high');

                IERC20(vars.asset).safeApprove(address(swap), 0);
                IERC20(vars.asset).safeApprove(address(swap), local.maxSpendAmount);
                (, local.repayAmount) = swap.swapExactTokensForTokens(
                        local.maxSpendAmount, params.swapRoute, params.slippage);
            }

        } else {

            if (params.mode == 2) {
                require(local.maxSpendAmount >= local.debt, "DepositRepay: Not enough to repay the loan");
                local.repayAmount = local.debt;
            } else {
                local.repayAmount = local.maxSpendAmount;
            }

        }

        // repay loan.
        if (params.debtFToken == fETH) {
            _WETH.withdraw(local.repayAmount);
            CEther(params.debtFToken).repayBorrowBehalf.value(local.repayAmount)(vars.initiator);
        } else {
            IERC20(getUnderlying(params.debtFToken)).safeApprove(params.debtFToken, 0);
            IERC20(getUnderlying(params.debtFToken)).safeApprove(params.debtFToken, local.repayAmount);
            local.err = CToken(params.debtFToken).repayBorrowBehalf(vars.initiator, local.repayAmount);
            require(local.err == 0, 'DepositRepay: compound repay failed');
        }


        // pull ftoken from user.
        _pullFtoken(vars.initiator, params.collateralFToken, local.pullFTokenAmount,
            vars.amount.add(vars.premium).add(vars.fee).sub(IERC20(vars.asset).balanceOf(address(this))));

        local.backFtokenAmount = CToken(params.collateralFToken).balanceOf(address(this));
        if (local.backFtokenAmount > 0) {
            IERC20(params.collateralFToken).safeTransfer(
                    local.backFtokenAmount > 10000 ? vars.initiator : owner(), local.backFtokenAmount);
        }

        // check slippage by oracle.
        uint256 spendAmount = CToken(params.collateralFToken)
                .exchangeRateCurrent().mul(local.pullFTokenAmount.sub(local.backFtokenAmount)).div(1e18);
        require(checkByOracle(params.collateralFToken, spendAmount, params.debtFToken, local.repayAmount), "DepositRepay: slippage too high");
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
            uint8 mode,
            address[] memory swapRoute,
            uint256 slippage
        )
            = abi.decode(params, (address, address, uint256, uint8, address[], uint256));

        return DepositRepayParams(debtFToken, collateralFToken, amount, mode, swapRoute, slippage);
    }

    function setOracle(address _oracle) external onlyGovernance {
        require(Address.isContract(_oracle), "DepositRepay: oracle address is not contract");

        address from = address(oracle);
        oracle = ChainlinkAdaptor(_oracle);

        emit OracleChanged(from, _oracle);
    }

    function() external payable {}
}
