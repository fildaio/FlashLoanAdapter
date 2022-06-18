const FeeManager = artifacts.require("FeeManager");

module.exports = async function (deployer, network, accounts) {
    const zeroAddr = "0x0000000000000000000000000000000000000000";
    await deployer.deploy(FeeManager,
        '0xB602eBf916bA8a9227141BDeA208CA1d19727Ab6', // _governance
        zeroAddr // _daoPool
        );

    console.log("***********************************************");
    console.log("FeeManager address:", FeeManager.address);
    console.log("***********************************************");
};

