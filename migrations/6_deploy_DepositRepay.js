const DepositRepay = artifacts.require("DepositRepay");
const FeeManager = artifacts.require("FeeManager");

module.exports = async function (deployer, network, accounts) {
    const feeManage = await FeeManager.deployed();

    await deployer.deploy(DepositRepay,
        '0xB602eBf916bA8a9227141BDeA208CA1d19727Ab6', // _governance
        '0xc65c5f007fCfC186Bc16e1f75e9A325906eB6D93', // _swapWrapper
        '0x4446fc4eb47f2f6586f9faab68b3498f86c07521', // WKCS
        '0xf9401F5246185eD3Fd0EF48f4775250d32069AEf', // tKCS
        feeManage.address, // _feeManager
        '0x935b755eFEcF62C222Bd0161E7981De7bF9319c0', // _oracle
        '0x92dBEA1Ac6278a0b4AEC11388C94F8fAFBE246C1', // _fUSDT
        );

    console.log("***********************************************");
    console.log("DepositRepay address:", DepositRepay.address);
    console.log("***********************************************");
};
