// SPDX-License-Identifier: MIT
pragma solidity >=0.4.22 <0.8.0;

contract SwapWrapper {
    function swapTokensForExactTokens(
        uint256 amountOut, address[] calldata path, uint256 amountInMax) external returns (uint256, uint256);

    function swapExactTokensForTokens(
        uint256 amountIn, address[] calldata path, uint256 amountOutMin) external returns (uint256, uint256);

    function router() external view returns (address);
}
