pragma solidity =0.6.6;

import '../interfaces/ICrosswisePair.sol';
import '../libraries/CrosswiseLibrary.sol';
import '../libraries/SafeMath.sol';

interface IPriceConsumer {
    function getLatestPrice(address _token0, address _token1);
}

abstract contract PriceGuard {
    using SafeMath for uint256;

    uint256 public maxSpreadTolerance; // maximum spread
    IPriceConsumer public priceConsumer;
    mapping (address => mapping (address => bool)) public priceGuardPaused;

    event PausePriceGuard(address _token0, address _token1, bool _paused);

    constructor(IPriceConsumer _priceConsumer) {
        priceConsumer = _priceConsumer;
        maxSpreadTolerance = 100; // maximum 10% spread
    }

    function _pausePriceGuard(
        address _token0,
        address _token1,
        bool _paused
    ) internal {
        priceGuardPaused[_token0][_token1] = _paused;
        emit PausePriceGuard(_token0, _token1, _paused);
    }

    function getChainLinkLatestPrice(address _token0, address _token1)
        public
        view
        returns (uint256)
    {
        return priceConsumer.getLatestPrice(_token0, _token1);
    }

    function _getPairPrice(address _token0, address _token1, uint256 amountIn)
        internal view return (uint256);

    function _verifyPrice(
        address _token0,
        address _token1,
        uint256 amountIn
    ) internal {
        if (!priceGuardPaused[_token0][_token1]) {
            uint256 pairPrice = _getPairPrice(_token0, _token1, amountIn);
            uint256 oraclePrice = getChainLinkLatestPrice(_token1, _token1);
            uint256 minPrice =
                pairPrice < oraclePrice ?
                pairPrice :
                oraclePrice;
            uint256 maxPrice =
                pairPrice < oraclePrice ?
                oraclePrice :
                pairPrice;
            uint256 upperLimit =
                minPrice.mul(maxSpreadTolerance.add(100)).div(100);
            require(maxPrice <= upperLimit, "verify price is failed");
        }
    }
}