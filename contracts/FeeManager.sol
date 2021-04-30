
// SPDX-License-Identifier: MIT
pragma solidity ^0.5.0;

import './dependency.sol';
import './Governable.sol';
import './RewardPool.sol';

contract FeeManager is Governable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    NoMintRewardPool public daoPool;
    uint256 constant internal feeMolecular = 10;
    uint256 constant internal feeDenominator = 10000; // Handling fee 1/1000
    uint256 constant internal freeQuota = 1e24; // 1 million in dao pool free

    constructor(address _governance, address _daoPool) public Governable(_governance) {
        require(_daoPool != address(0), "dao pool shouldn't be empty");
        daoPool = NoMintRewardPool(_daoPool);
    }

    function setDaoPool(address _daoPool) external onlyGovernance {
        require(_daoPool != address(0), "dao pool shouldn't be empty");
        daoPool =  NoMintRewardPool(_daoPool);
    }

    function getFee(address initiator, uint256 amount) external view returns (uint256) {
        require(initiator != address(0), "initiator shouldn't be empty");
        require(amount > 0, "amount shouldn't be zero");

        uint256 balance = daoPool.balanceOf(initiator);

        return balance >= freeQuota
            ? 0 : amount.mul(freeQuota.sub(balance)).div(freeQuota).mul(feeMolecular).div(feeDenominator);
    }

}
