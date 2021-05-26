// SPDX-License-Identifier: MIT
pragma solidity ^0.5.0;

import "./flashloan/FlashLoanReceiverBase.sol";
import './Governable.sol';
import './dependency.sol';
import './FeeManager.sol';
import './swap/SwapWrapper.sol';
import './WETH.sol';
import './compound/CToken.sol';

contract BaseAdapter is FlashLoanReceiverBase, Governable, Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    event FeeManagerChanged(
        address _from,
        address _to
    );

    SwapWrapper public swap;
    WETH public _WETH;
    address public fETH;
    FeeManager public feeManager;

    constructor(IFlashLoan _flashLoan, address _governance,
            address _swapWrapper, address _weth, address _fETH, address _feeManager) public
        FlashLoanReceiverBase(_flashLoan)
        Governable(_governance) {
        require(_swapWrapper != address(0) && _weth != address(0)
            && _fETH != address(0) && _feeManager != address(0), "FlashLoanAdapter: invalid parameter");

        swap = SwapWrapper(_swapWrapper);
        _WETH = WETH(_weth);
        fETH = _fETH;
        feeManager = FeeManager(_feeManager);
    }

    function _pullFtoken(
        address initiator,
        address ftoken,
        uint256 amount,
        uint256 underlyingAmount) internal {

        IERC20(ftoken).safeTransferFrom(initiator, address(this), amount);
        uint err = CToken(ftoken).redeemUnderlying(underlyingAmount);
        require(err == 0, "FlashLoanAdapter: compound redeem failed");

        if (ftoken == fETH) {
            _WETH.deposit.value(underlyingAmount)();
        }
    }

    function _pullFtoken(
        address initiator,
        address ftoken,
        uint256 amount) internal {

        IERC20(ftoken).safeTransferFrom(initiator, address(this), amount);
        uint err = CToken(ftoken).redeem(amount);
        require(err == 0, "FlashLoanAdapter: compound redeem failed");

        if (ftoken == fETH) {
            _WETH.deposit.value(address(this).balance)();
        }
    }

    function withdrawERC20(address _token, address _account, uint256 amount) public onlyOwner {
        IERC20 token = IERC20(_token);
        if (amount > token.balanceOf(address(this))) {
            amount = token.balanceOf(address(this));
        }
        token.safeTransfer(_account, amount);
    }

    function setFeeManager(address _feeManager) external onlyGovernance {
        require(_feeManager != address(0), "FlashLoanAdapter: invalid parameter");

        address from = address(feeManager);
        feeManager = FeeManager(_feeManager);

        emit FeeManagerChanged(from, _feeManager);
    }
}
