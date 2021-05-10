pragma solidity =0.6.6;

import '../interfaces/ICrosswiseCallee.sol';

import '../libraries/CrosswiseLibrary.sol';
import '../interfaces/V1/IUniswapV1Factory.sol';
import '../interfaces/V1/IUniswapV1Exchange.sol';
import '../interfaces/ICrosswiseRouter01.sol';
import '../interfaces/IBEP20.sol';
import '../interfaces/IWBNB.sol';

contract ExampleFlashSwap is ICrosswiseCallee {
    IUniswapV1Factory immutable factoryV1;
    address immutable factory;
    IWBNB immutable WBNB;

    constructor(address _factory, address _factoryV1, address router) public {
        factoryV1 = IUniswapV1Factory(_factoryV1);
        factory = _factory;
        WBNB = IWBNB(ICrosswiseRouter01(router).WBNB());
    }

    // needs to accept ETH from any V1 exchange and WBNB. ideally this could be enforced, as in the router,
    // but it's not possible because it requires a call to the v1 factory, which takes too much gas
    receive() external payable {}

    // gets tokens/WBNB via a V2 flash swap, swaps for the ETH/tokens on V1, repays V2, and keeps the rest!
    function crosswiseCall(address sender, uint amount0, uint amount1, bytes calldata data) external override {
        address[] memory path = new address[](2);
        uint amountToken;
        uint amountETH;
        { // scope for token{0,1}, avoids stack too deep errors
        address token0 = ICrosswisePair(msg.sender).token0();
        address token1 = ICrosswisePair(msg.sender).token1();
        assert(msg.sender == CrosswiseLibrary.pairFor(factory, token0, token1)); // ensure that msg.sender is actually a V2 pair
        assert(amount0 == 0 || amount1 == 0); // this strategy is unidirectional
        path[0] = amount0 == 0 ? token0 : token1;
        path[1] = amount0 == 0 ? token1 : token0;
        amountToken = token0 == address(WBNB) ? amount1 : amount0;
        amountETH = token0 == address(WBNB) ? amount0 : amount1;
        }

        assert(path[0] == address(WBNB) || path[1] == address(WBNB)); // this strategy only works with a V2 WBNB pair
        IBEP20 token = IBEP20(path[0] == address(WBNB) ? path[1] : path[0]);
        IUniswapV1Exchange exchangeV1 = IUniswapV1Exchange(factoryV1.getExchange(address(token))); // get V1 exchange

        if (amountToken > 0) {
            (uint minETH) = abi.decode(data, (uint)); // slippage parameter for V1, passed in by caller
            token.approve(address(exchangeV1), amountToken);
            uint amountReceived = exchangeV1.tokenToEthSwapInput(amountToken, minETH, uint(-1));
            uint amountRequired = CrosswiseLibrary.getAmountsIn(factory, amountToken, path)[0];
            assert(amountReceived > amountRequired); // fail if we didn't get enough ETH back to repay our flash loan
            WBNB.deposit{value: amountRequired}();
            assert(WBNB.transfer(msg.sender, amountRequired)); // return WBNB to V2 pair
            (bool success,) = sender.call{value: amountReceived - amountRequired}(new bytes(0)); // keep the rest! (ETH)
            assert(success);
        } else {
            (uint minTokens) = abi.decode(data, (uint)); // slippage parameter for V1, passed in by caller
            WBNB.withdraw(amountETH);
            uint amountReceived = exchangeV1.ethToTokenSwapInput{value: amountETH}(minTokens, uint(-1));
            uint amountRequired = CrosswiseLibrary.getAmountsIn(factory, amountETH, path)[0];
            assert(amountReceived > amountRequired); // fail if we didn't get enough tokens back to repay our flash loan
            assert(token.transfer(msg.sender, amountRequired)); // return tokens to V2 pair
            assert(token.transfer(sender, amountReceived - amountRequired)); // keep the rest! (tokens)
        }
    }
}
