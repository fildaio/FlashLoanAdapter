
// SPDX-License-Identifier: MIT
pragma solidity ^0.5.0;

import './dependency.sol';
import './Governable.sol';
import './RewardPool.sol';

contract FeeManager is Governable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    NoMintRewardPool public daoPool;
    uint256 public feeTotal;

    constructor(address _governance, address _daoPool) public Governable(_governance) {
        require(_daoPool != address(0), "dao pool shouldn't be empty");
        daoPool = NoMintRewardPool(_daoPool);
        feeTotal = 100;
    }

    function setDaoPool(address _daoPool) external onlyGovernance {
        require(_daoPool != address(0), "dao pool shouldn't be empty");
        daoPool =  NoMintRewardPool(_daoPool);
    }

    function getFee(address initiator, uint256 amount) external view returns (uint256) {
        require(initiator != address(0), "initiator shouldn't be empty");
        require(amount > 0, "amount shouldn't be zero");

        uint8 decimals = IERC20Detailed(daoPool.lpToken()).decimals();
        uint256 balance = daoPool.balanceOf(initiator).div(10 ** uint256(decimals));
        if (balance > 1e6) return 0;

        uint256 total = amount.mul(feeTotal).div(1e5);

        return balance > 0 ? total.sub(total.mul(balance).div(1e6)) : total;
    }

}
