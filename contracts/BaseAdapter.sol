// SPDX-License-Identifier: MIT
pragma solidity ^0.5.0;

import "./flashloan/FlashLoanReceiverBase.sol";
import './Governable.sol';
import './dependency.sol';
import './FeeManager.sol';
import './swap/SwapWrapper.sol';
import './WETH.sol';
import './compound/CToken.sol';
import './oracle/ChainlinkAdaptor.sol';

contract BaseAdapter is FlashLoanReceiverBase, Governable, Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    event FeeManagerChanged(
        address _from,
        address _to
    );

    event FlashLoanPoolChanged(
        address _from,
        address _to
    );


    event OracleChanged(
        address indexed from,
        address indexed to
    );

    SwapWrapper public swap;
    WETH public _WETH;
    address public fETH;
    FeeManager public feeManager;
    ChainlinkAdaptor public oracle;
    address public fHUSD;

    constructor(IFlashLoan _flashLoan, address _governance,
            address _swapWrapper, address _weth, address _fETH, address _feeManager, address _oracle, address _fHUSD) public
        FlashLoanReceiverBase(_flashLoan)
        Governable(_governance) {
        require(_swapWrapper != address(0) && _weth != address(0)
            && _fETH != address(0) && _feeManager != address(0) && _fHUSD != address(0), "FlashLoanAdapter: invalid parameter");
        require(Address.isContract(_oracle), "FlashLoanAdapter: oracle address is not contract");

        swap = SwapWrapper(_swapWrapper);
        _WETH = WETH(_weth);
        fETH = _fETH;
        feeManager = FeeManager(_feeManager);

        oracle = ChainlinkAdaptor(_oracle);

        fHUSD = _fHUSD;
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

        if (ftoken == fETH && address(this).balance > 0) {
            address(uint160(owner())).transfer(address(this).balance);
        }

        IERC20(ftoken).safeTransferFrom(initiator, address(this), amount);
        uint err = CToken(ftoken).redeem(amount);
        require(err == 0, "FlashLoanAdapter: compound redeem failed");

        if (ftoken == fETH) {
            _WETH.deposit.value(address(this).balance)();
        }
    }

    function getUnderlying(address ftoken) internal view returns (address) {
        return ftoken == fETH ? address(_WETH) : CToken(ftoken).underlying();
    }


    function checkByOracle(address ftokenA, uint256 amountA, address ftokenB, uint256 amountB) internal view returns (bool) {
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

    function setFlashLoanPool(address _flashLoan) external onlyGovernance {
        require(_flashLoan != address(0), "FlashLoanAdapter: invalid parameter");

        address from = address(FLASHLOAN_POOL);
        FLASHLOAN_POOL = IFlashLoan(_flashLoan);

        emit FlashLoanPoolChanged(from, _flashLoan);
    }


    function setOracle(address _oracle) external onlyGovernance {
        require(Address.isContract(_oracle), "DepositRepay: oracle address is not contract");

        address from = address(oracle);
        oracle = ChainlinkAdaptor(_oracle);

        emit OracleChanged(from, _oracle);
    }

}
