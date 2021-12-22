pragma solidity >=0.6.6;

interface IPriceConsumer {
    function getLatestPrice(address _pair)
        external view returns (uint256);
}