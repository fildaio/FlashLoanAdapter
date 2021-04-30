const RepayLoan = artifacts.require("RepayLoan");
const FeeManager = artifacts.require("FeeManager");

module.exports = async function (deployer, network, accounts) {
    const feeManage = await FeeManager.deployed();

    await deployer.deploy(RepayLoan,
        '0x', // falshloan address
        '0x', // _governance
        '0x', // _swapWrapper
        '0x', // _weth
        '0x', // _fETH
        feeManage.address // _feeManager
        );

    console.log("***********************************************");
    console.log("RepayLoan address:", RepayLoan.address);
    console.log("***********************************************");
};
