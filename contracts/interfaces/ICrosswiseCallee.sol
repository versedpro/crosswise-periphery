pragma solidity =0.6.6;

interface ICrosswiseCallee {
    function crosswiseCall(address sender, uint amount0, uint amount1, bytes calldata data) external;
}