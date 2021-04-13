const RepayLoan = artifacts.require("RepayLoan");

module.exports = async function (deployer, network, accounts) {

    await deployer.deploy(RepayLoan,
        '0x', // falshloan address
        '0x' // _governance
        );

    console.log("***********************************************");
    console.log("RepayLoan address:", RepayLoan.address);
    console.log("***********************************************");
};
