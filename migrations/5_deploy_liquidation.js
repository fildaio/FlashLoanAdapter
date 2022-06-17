const Liquidation = artifacts.require("Liquidation");
const FeeManager = artifacts.require("FeeManager");

module.exports = async function (deployer, network, accounts) {
    const feeManage = await FeeManager.deployed();

    await deployer.deploy(Liquidation,
        '0x05Ddc595FD33D7B2AB302143c420D0e7f21B622a', // _governance
        // '0x0fbB23e1D143e6de13988BB1DF21d52168795bB5', // _swapWrapper
        // '0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270', // _wMatic
        // '0x154250560242c4f2947Cf2EA6c8e92e0cE714d4E', // _fMatic
        // feeManage.address, // _feeManager
        // '0x879a05fb8A0545f0Fbd382Cb33fCb63bb71fc082', // _oracle
        // '0x7280faEc8C4a6ABbb3414e31015AC108113363A4', // _fUSDT
        // '0x56AbDDA598ee1a5847651d858A81D3714dCDa3d2', // _swapWrapper
        // '0xa00744882684c3e4747faefd68d283ea44099d03', // _wIoTeX
        // '0x8aee1d27D906895cc771380ba5a49bbD421DD5a0', // _fIoTeX
        '0xAbad362b4DFfaFE3047EC10c68155EB99f4b9301', // esc glide _swapWrapper
        '0x517E9e5d46C1EA8aB6f78677d6114Ef47F71f6c4', // _wELA
        '0xF31AD464E61118c735E6d3C909e7a42DAA1575A3', // _fELA
        feeManage.address, // _feeManager
        // '0xd42374e5D0C53026558bFE59B3270e9E2A30cB98', // _oracle
        // '0x7cfB238C628f321bA905D1beEc2bfB18AE56Fcdb', // _fUSDT
        '0x5117b046517ffa18d4d9897090d0537ff62a844a', // esc _oracle
        '0x7bC72d7780C2E811814e81FFac828d53f4CDe7c2' // esc _fUSDC
        );

    console.log("***********************************************");
    console.log("Liquidation address:", Liquidation.address);
    console.log("***********************************************");
};
