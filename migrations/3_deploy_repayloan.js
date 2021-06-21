const RepayLoan = artifacts.require("RepayLoan");
const FeeManager = artifacts.require("FeeManager");

module.exports = async function (deployer, network, accounts) {
    const feeManage = await FeeManager.deployed();

    await deployer.deploy(RepayLoan,
        '0x', // flashloan address
        '0x', // _governance
        '0xCD83Fb2cb441127602e74860117c8E26E0864692', // _swapWrapper
        '0x5545153CCFcA01fbd7Dd11C0b23ba694D9509A6F', // _weth
        '0x824151251B38056d54A15E56B73c54ba44811aF8', // _fETH
        feeManage.address, // _feeManager
        '0xa7042d87b25b18875cd1d2b1ce535c5488bc4fd0', // _oracle
        '0xB16Df14C53C4bcfF220F4314ebCe70183dD804c0' // _fHUSD
        );

    console.log("***********************************************");
    console.log("RepayLoan address:", RepayLoan.address);
    console.log("***********************************************");
};
