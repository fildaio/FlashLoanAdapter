const FeeManager = artifacts.require("FeeManager");

module.exports = async function (deployer, network, accounts) {
    await deployer.deploy(FeeManager,
        '0x', // _governance
        '0x73CB0A55Be009B30e63aD5830c85813414c66367' // _daoPool
        );

    console.log("***********************************************");
    console.log("FeeManager address:", FeeManager.address);
    console.log("***********************************************");
};

