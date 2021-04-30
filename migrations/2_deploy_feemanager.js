const FeeManager = artifacts.require("FeeManager");

module.exports = async function (deployer, network, accounts) {
    await deployer.deploy(FeeManager,
        '0x', // _governance
        '0x' // _daoPool
        );

    console.log("***********************************************");
    console.log("FeeManager address:", FeeManager.address);
    console.log("***********************************************");
};

