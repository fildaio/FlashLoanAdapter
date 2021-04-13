
// SPDX-License-Identifier: agpl-3.0
pragma solidity ^0.5.0;

import "./flashloan/FlashLoanReceiverBase.sol";
import './compound/CToken.sol';
import './Governable.sol';
import './dependency.sol';

contract RepayLoan is FlashLoanReceiverBase, Governable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    event RepayedLoan(
        address indexed initiator,
        address indexed asset,
        uint256 repayAmount,
        uint256 backFtokenAmount
    );

    struct FTokenParams {
        address[] ftokens;
        uint256[] ftokensAmount;
    }

    struct RepayLocalVars {
        address asset;
        uint256 amount;
        uint256 premium;
        uint256 borrowAmount;
        address ftoken;
        uint256 ftokenAmount;
        uint256 backFtokenAmount;
    }

    constructor(IFlashLoan _flashLoan, address _governance) public
        FlashLoanReceiverBase(_flashLoan)
        Governable(_governance) {}

    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external returns (bool) {
        require(msg.sender == address(FLASHLOAN_POOL), "RepayLoan: caller is not flash loan contract");

        FTokenParams memory ftokenParams = _decodeParams(params);
        require(assets.length == ftokenParams.ftokens.length, "RepayLoan: invalid params");

        RepayLocalVars memory vars;

        for (uint i = 0; i < assets.length; i++) {
            vars.asset = assets[i];
            vars.amount = amounts[i];
            vars.premium = premiums[i];
            vars.ftoken = ftokenParams.ftokens[i];
            vars.ftokenAmount = ftokenParams.ftokensAmount[i];
            vars.borrowAmount = CToken(vars.ftoken).borrowBalanceCurrent(initiator);

            if (vars.amount < vars.borrowAmount) return false;

            IERC20(vars.asset).safeApprove(vars.ftoken, vars.borrowAmount);
            uint err = CToken(vars.ftoken).repayBorrowBehalf(initiator, vars.borrowAmount);
            if (err != 0) return false;

            IERC20(vars.ftoken).safeTransferFrom(initiator, address(this), vars.ftokenAmount);
            // redeemAmount = amount + premium - (amount - borrowAmount) = premium + borrowAmount;
            err = CToken(vars.ftoken).redeemUnderlying(vars.premium.add(vars.borrowAmount));
            if (err != 0) return false;

            IERC20(vars.asset).safeApprove(address(FLASHLOAN_POOL), vars.amount.add(vars.premium));

            vars.backFtokenAmount = CToken(vars.ftoken).balanceOf(address(this));
            IERC20(vars.ftoken).safeTransfer(initiator, vars.backFtokenAmount);

            emit RepayedLoan(
                initiator,
                vars.asset,
                vars.borrowAmount,
                vars.backFtokenAmount
            );
        }

        return true;
    }

    function withdrawERC20(address _token, address _account, uint256 amount) public onlyGovernance returns (uint256) {
        require(msg.sender == governance, "only governance.");
        IERC20 token = IERC20(_token);
        if (amount > token.balanceOf(address(this))) {
            amount = token.balanceOf(address(this));
        }
        token.safeTransfer(_account, amount);
        return amount;
    }

    function _decodeParams(bytes memory params) internal pure returns (FTokenParams memory) {
        (address[] memory ftokens, uint256[] memory ftokensAmount)
            = abi.decode(params, (address[], uint256[]));

        return FTokenParams(ftokens, ftokensAmount);
    }
}
