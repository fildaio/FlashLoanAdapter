const LiquiditySwap = artifacts.require("LiquiditySwap");

module.exports = async function (deployer, network, accounts) {

    await deployer.deploy(LiquiditySwap,
        '0x', // falshloan address
        '0x', // _governance
        '0x', // _swapWrapper
        '0x', // _weth
        '0x', // _fETH
        '0x', // _feeManager
        '0x' // _comptroller
        );

    console.log("***********************************************");
    console.log("LiquiditySwap address:", LiquiditySwap.address);
    console.log("***********************************************");
};
