const FeeManager = artifacts.require("FeeManager");

module.exports = async function (deployer, network, accounts) {
    const zeroAddr = "0x0000000000000000000000000000000000000000";
    await deployer.deploy(FeeManager,
        '0x05Ddc595FD33D7B2AB302143c420D0e7f21B622a', // _governance
        zeroAddr // _daoPool
        );

    console.log("***********************************************");
    console.log("FeeManager address:", FeeManager.address);
    console.log("***********************************************");
};

