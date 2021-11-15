const RepayLoan = artifacts.require("RepayLoan");
const FeeManager = artifacts.require("FeeManager");

module.exports = async function (deployer, network, accounts) {
    const feeManage = await FeeManager.deployed();

    await deployer.deploy(RepayLoan,
        '0x', // _governance
        '0x', // _swapWrapper
        '0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270', // _wMatic
        '0x8f7de8e558249aaeb511E2fd2467369c991D1bC2', // _fMatic
        feeManage.address, // _feeManager
        '0x4C4E0307f2c60f5b206a73fab728485ecaD9b2B9', // _oracle
        '0xAb55dB8E2F7505C2191E7dDB5de5e266994A95b6' // _fUSDT
        );

    console.log("***********************************************");
    console.log("RepayLoan address:", RepayLoan.address);
    console.log("***********************************************");
};
