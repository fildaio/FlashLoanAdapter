const DepositRepay = artifacts.require("DepositRepay");
const FeeManager = artifacts.require("FeeManager");

module.exports = async function (deployer, network, accounts) {
    const feeManage = await FeeManager.deployed();

    await deployer.deploy(DepositRepay,
        '0x', // flashloan address
        '0x', // _governance
        '0xCD83Fb2cb441127602e74860117c8E26E0864692', // _swapWrapper
        '0x5545153CCFcA01fbd7Dd11C0b23ba694D9509A6F', // _weth
        '0x824151251B38056d54A15E56B73c54ba44811aF8', // _fETH
        feeManage.address // _feeManager
        );

    console.log("***********************************************");
    console.log("DepositRepay address:", DepositRepay.address);
    console.log("***********************************************");
};
