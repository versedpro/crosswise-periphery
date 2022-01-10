pragma solidity =0.6.6;

// import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol';
import './interfaces/ICrosswiseFactory.sol';
import '@uniswap/lib/contracts/libraries/TransferHelper.sol';

import './interfaces/ICrosswiseRouter02.sol';
import './interfaces/IPriceConsumer.sol';
import './libraries/CrosswiseLibrary.sol';
import './libraries/SafeMath.sol';
import './interfaces/IBEP20.sol';
import './interfaces/IWBNB.sol';

contract CrosswiseRouter is ICrosswiseRouter02 {
    using SafeMath for uint;

    event SetAntiWhale(address indexed lp, bool status);
    event SetwhitelistToken(address indexed token, bool status);
    event PausePriceGuard(address _lp, bool _paused);

    address public immutable override factory;
    address public immutable override WBNB;

    // user who can set the whitelist token
    address public immutable admin;

    uint public maxTransferAmountRate = 50;
    uint public maxShare = 10000;

    mapping(address => bool) private antiWhalePerLp;
    mapping(address => address) public lpCreators;
    mapping(address => bool) public whitelistTokens;

    IPriceConsumer public priceConsumer;
    // <LP pair => paused>
    mapping (address => bool) public priceGuardPaused;
    // <LP pair => tolerance> 100% in 10000
    mapping (address => uint256) public maxSpreadTolerance;

    modifier ensure(uint deadline) {
        require(deadline >= block.timestamp, 'CrosswiseRouter: EXPIRED');
        _;
    }

    function antiWhale(address[] memory path, uint amountIn) internal view {
        for (uint256 i = 0; i < path.length - 1; i++) {
            ICrosswisePair pair = ICrosswisePair(
                CrosswiseLibrary.pairFor(factory, path[i], path[i + 1])
            );

            if (antiWhalePerLp[address(pair)]) {
                (uint reserve0, uint reserve1,) = pair.getReserves();
                (reserve0, reserve1) =
                    path[i] == pair.token0() ?
                    (reserve0, reserve1) :
                    (reserve1, reserve0);
                uint maxTransferAmount = (reserve0 * maxTransferAmountRate) / maxShare;
                require(amountIn <= maxTransferAmount, "CrssRouter.antiWhale: Transfer amount exceeds the maxTransferAmount");
            }
        }
    }

    constructor(
        address _factory,
        address _WBNB,
        IPriceConsumer _priceConsumer,
        address _admin
    ) public {
        factory = _factory;
        WBNB = _WBNB;
        priceConsumer = _priceConsumer;
        admin = _admin;
    }

    receive() external payable {
        assert(msg.sender == WBNB); // only accept ETH via fallback from the WBNB contract
    }

    // **** ADD LIQUIDITY ****
    function _addLiquidity( 
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin
    ) internal virtual returns (uint amountA, uint amountB) {
        // create the pair if it doesn't exist yet
        if (ICrosswiseFactory(factory).getPair(tokenA, tokenB) == address(0)) {
            ICrosswiseFactory(factory).createPair(tokenA, tokenB);
        }
        (uint reserveA, uint reserveB) = CrosswiseLibrary.getReserves(factory, tokenA, tokenB);
        if (reserveA == 0 && reserveB == 0) {
            lpCreators[ICrosswiseFactory(factory).getPair(tokenA, tokenB)] = msg.sender;
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint amountBOptimal = CrosswiseLibrary.quote(amountADesired, reserveA, reserveB);
            if (amountBOptimal <= amountBDesired) {
                require(amountBOptimal >= amountBMin, 'CrosswiseRouter: INSUFFICIENT_B_AMOUNT');
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint amountAOptimal = CrosswiseLibrary.quote(amountBDesired, reserveB, reserveA);
                assert(amountAOptimal <= amountADesired);
                require(amountAOptimal >= amountAMin, 'CrosswiseRouter: INSUFFICIENT_A_AMOUNT');
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) returns (uint amountA, uint amountB, uint liquidity) {
        require(whitelistTokens[tokenA] && whitelistTokens[tokenB], "not whitelisted tokens");

        (amountA, amountB) = _addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);
        address pair = CrosswiseLibrary.pairFor(factory, tokenA, tokenB);
        TransferHelper.safeTransferFrom(tokenA, msg.sender, pair, amountA);
        TransferHelper.safeTransferFrom(tokenB, msg.sender, pair, amountB);
        liquidity = ICrosswisePair(pair).mint(to);
    }
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external virtual override payable ensure(deadline) returns (uint amountToken, uint amountETH, uint liquidity) {
        require(whitelistTokens[token], "not whitelisted tokens");
        (amountToken, amountETH) = _addLiquidity(
            token,
            WBNB,
            amountTokenDesired,
            msg.value,
            amountTokenMin,
            amountETHMin
        );
        address pair = CrosswiseLibrary.pairFor(factory, token, WBNB);
        TransferHelper.safeTransferFrom(token, msg.sender, pair, amountToken);
        IWBNB(WBNB).deposit{value: amountETH}();
        assert(IWBNB(WBNB).transfer(pair, amountETH));
        liquidity = ICrosswisePair(pair).mint(to);
        // refund dust eth, if any
        if (msg.value > amountETH) TransferHelper.safeTransferETH(msg.sender, msg.value - amountETH);
    }

    // **** REMOVE LIQUIDITY ****
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) public virtual override ensure(deadline) returns (uint amountA, uint amountB) {
        address pair = CrosswiseLibrary.pairFor(factory, tokenA, tokenB);
        ICrosswisePair(pair).transferFrom(msg.sender, pair, liquidity); // send liquidity to pair
        (uint amount0, uint amount1) = ICrosswisePair(pair).burn(to);
        (address token0,) = CrosswiseLibrary.sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
        require(amountA >= amountAMin, 'CrosswiseRouter: INSUFFICIENT_A_AMOUNT');
        require(amountB >= amountBMin, 'CrosswiseRouter: INSUFFICIENT_B_AMOUNT');
    }
    function removeLiquidityETH(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) public virtual override ensure(deadline) returns (uint amountToken, uint amountETH) {
        (amountToken, amountETH) = removeLiquidity(
            token,
            WBNB,
            liquidity,
            amountTokenMin,
            amountETHMin,
            address(this),
            deadline
        );
        TransferHelper.safeTransfer(token, to, amountToken);
        IWBNB(WBNB).withdraw(amountETH);
        TransferHelper.safeTransferETH(to, amountETH);
    }
    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external virtual override returns (uint amountA, uint amountB) {
        address pair = CrosswiseLibrary.pairFor(factory, tokenA, tokenB);
        uint value = approveMax ? uint(-1) : liquidity;
        ICrosswisePair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        (amountA, amountB) = removeLiquidity(tokenA, tokenB, liquidity, amountAMin, amountBMin, to, deadline);
    }
    function removeLiquidityETHWithPermit(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external virtual override returns (uint amountToken, uint amountETH) {
        address pair = CrosswiseLibrary.pairFor(factory, token, WBNB);
        uint value = approveMax ? uint(-1) : liquidity;
        ICrosswisePair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        (amountToken, amountETH) = removeLiquidityETH(token, liquidity, amountTokenMin, amountETHMin, to, deadline);
    }

    // **** REMOVE LIQUIDITY (supporting fee-on-transfer tokens) ****
    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) public virtual override ensure(deadline) returns (uint amountETH) {
        (, amountETH) = removeLiquidity(
            token,
            WBNB,
            liquidity,
            amountTokenMin,
            amountETHMin,
            address(this),
            deadline
        );
        TransferHelper.safeTransfer(token, to, IBEP20(token).balanceOf(address(this)));
        IWBNB(WBNB).withdraw(amountETH);
        TransferHelper.safeTransferETH(to, amountETH);
    }
    function removeLiquidityETHWithPermitSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external virtual override returns (uint amountETH) {
        address pair = CrosswiseLibrary.pairFor(factory, token, WBNB);
        uint value = approveMax ? uint(-1) : liquidity;
        ICrosswisePair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        amountETH = removeLiquidityETHSupportingFeeOnTransferTokens(
            token, liquidity, amountTokenMin, amountETHMin, to, deadline
        );
    }

    // **** SWAP ****
    // requires the initial amount to have already been sent to the first pair
    function _swap(uint[] memory amounts, address[] memory path, address _to) internal virtual {
        for (uint i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0,) = CrosswiseLibrary.sortTokens(input, output);
            uint amountOut = amounts[i + 1];
            (uint amount0Out, uint amount1Out) = input == token0 ? (uint(0), amountOut) : (amountOut, uint(0));
            address to = i < path.length - 2 ? CrosswiseLibrary.pairFor(factory, output, path[i + 2]) : _to;
            ICrosswisePair(CrosswiseLibrary.pairFor(factory, input, output)).swap(
                amount0Out, amount1Out, to, new bytes(0)
            );
        }
    }
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) returns (uint[] memory amounts) {
        antiWhale(path, amountIn);
        verifyPrice(path, amountIn, 0);
        amounts = CrosswiseLibrary.getAmountsOut(factory, amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, 'CrosswiseRouter: INSUFFICIENT_OUTPUT_AMOUNT');
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, CrosswiseLibrary.pairFor(factory, path[0], path[1]), amounts[0]
        );
        _swap(amounts, path, to);
    }
    function swapTokensForExactTokens(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) returns (uint[] memory amounts) {
        antiWhale(path, amountOut);
        verifyPrice(path, 0, amountOut);
        amounts = CrosswiseLibrary.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= amountInMax, 'CrosswiseRouter: EXCESSIVE_INPUT_AMOUNT');
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, CrosswiseLibrary.pairFor(factory, path[0], path[1]), amounts[0]
        );
        _swap(amounts, path, to);
    }
    function swapExactETHForTokens(uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        virtual
        override
        payable
        ensure(deadline)
        returns (uint[] memory amounts)
    {
        require(path[0] == WBNB, 'CrosswiseRouter: INVALID_PATH');
        antiWhale(path, msg.value);
        verifyPrice(path, msg.value, 0);
        amounts = CrosswiseLibrary.getAmountsOut(factory, msg.value, path);
        require(amounts[amounts.length - 1] >= amountOutMin, 'CrosswiseRouter: INSUFFICIENT_OUTPUT_AMOUNT');
        IWBNB(WBNB).deposit{value: amounts[0]}();
        assert(IWBNB(WBNB).transfer(CrosswiseLibrary.pairFor(factory, path[0], path[1]), amounts[0]));
        _swap(amounts, path, to);
    }
    function swapTokensForExactETH(uint amountOut, uint amountInMax, address[] calldata path, address to, uint deadline)
        external
        virtual
        override
        ensure(deadline)
        returns (uint[] memory amounts)
    {
        require(path[path.length - 1] == WBNB, 'CrosswiseRouter: INVALID_PATH');
        antiWhale(path, amountOut);
        verifyPrice(path, 0, amountOut);
        amounts = CrosswiseLibrary.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= amountInMax, 'CrosswiseRouter: EXCESSIVE_INPUT_AMOUNT');
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, CrosswiseLibrary.pairFor(factory, path[0], path[1]), amounts[0]
        );
        _swap(amounts, path, address(this));
        IWBNB(WBNB).withdraw(amounts[amounts.length - 1]);
        TransferHelper.safeTransferETH(to, amounts[amounts.length - 1]);
    }
    function swapExactTokensForETH(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        virtual
        override
        ensure(deadline)
        returns (uint[] memory amounts)
    {
        require(path[path.length - 1] == WBNB, 'CrosswiseRouter: INVALID_PATH');
        antiWhale(path, amountIn);
        verifyPrice(path, amountIn, 0);
        amounts = CrosswiseLibrary.getAmountsOut(factory, amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, 'CrosswiseRouter: INSUFFICIENT_OUTPUT_AMOUNT');
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, CrosswiseLibrary.pairFor(factory, path[0], path[1]), amounts[0]
        );
        _swap(amounts, path, address(this));
        IWBNB(WBNB).withdraw(amounts[amounts.length - 1]);
        TransferHelper.safeTransferETH(to, amounts[amounts.length - 1]);
    }
    function swapETHForExactTokens(uint amountOut, address[] calldata path, address to, uint deadline)
        external
        virtual
        override
        payable
        ensure(deadline)
        returns (uint[] memory amounts)
    {
        require(path[0] == WBNB, 'CrosswiseRouter: INVALID_PATH');
        antiWhale(path, msg.value);
        verifyPrice(path, 0, amountOut);
        amounts = CrosswiseLibrary.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= msg.value, 'CrosswiseRouter: EXCESSIVE_INPUT_AMOUNT');
        IWBNB(WBNB).deposit{value: amounts[0]}();
        assert(IWBNB(WBNB).transfer(CrosswiseLibrary.pairFor(factory, path[0], path[1]), amounts[0]));
        _swap(amounts, path, to);
        // refund dust eth, if any
        if (msg.value > amounts[0]) TransferHelper.safeTransferETH(msg.sender, msg.value - amounts[0]);
    }

    // **** SWAP (supporting fee-on-transfer tokens) ****
    // requires the initial amount to have already been sent to the first pair
    function _swapSupportingFeeOnTransferTokens(address[] memory path, address _to) internal virtual {
        for (uint i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0,) = CrosswiseLibrary.sortTokens(input, output);
            ICrosswisePair pair = ICrosswisePair(CrosswiseLibrary.pairFor(factory, input, output));
            uint amountInput;
            uint amountOutput;
            { // scope to avoid stack too deep errors
            (uint reserve0, uint reserve1,) = pair.getReserves();
            (uint reserveInput, uint reserveOutput) = input == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
            amountInput = IBEP20(input).balanceOf(address(pair)).sub(reserveInput);
            amountOutput = CrosswiseLibrary.getAmountOut(amountInput, reserveInput, reserveOutput);
            }
            (uint amount0Out, uint amount1Out) = input == token0 ? (uint(0), amountOutput) : (amountOutput, uint(0));
            address to = i < path.length - 2 ? CrosswiseLibrary.pairFor(factory, output, path[i + 2]) : _to;
            pair.swap(amount0Out, amount1Out, to, new bytes(0));
        }
    }
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) {
        antiWhale(path, amountIn);
        verifyPrice(path, amountIn, 0);
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, CrosswiseLibrary.pairFor(factory, path[0], path[1]), amountIn
        );
        uint balanceBefore = IBEP20(path[path.length - 1]).balanceOf(to);
        _swapSupportingFeeOnTransferTokens(path, to);
        require(
            IBEP20(path[path.length - 1]).balanceOf(to).sub(balanceBefore) >= amountOutMin,
            'CrosswiseRouter: INSUFFICIENT_OUTPUT_AMOUNT'
        );
    }
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    )
        external
        virtual
        override
        payable
        ensure(deadline)
    {
        require(path[0] == WBNB, 'CrosswiseRouter: INVALID_PATH');
        antiWhale(path, msg.value);
        verifyPrice(path, msg.value, 0);
        uint amountIn = msg.value;
        IWBNB(WBNB).deposit{value: amountIn}();
        assert(IWBNB(WBNB).transfer(CrosswiseLibrary.pairFor(factory, path[0], path[1]), amountIn));
        uint balanceBefore = IBEP20(path[path.length - 1]).balanceOf(to);
        _swapSupportingFeeOnTransferTokens(path, to);
        require(
            IBEP20(path[path.length - 1]).balanceOf(to).sub(balanceBefore) >= amountOutMin,
            'CrosswiseRouter: INSUFFICIENT_OUTPUT_AMOUNT'
        );
    }
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    )
        external
        virtual
        override
        ensure(deadline)
    {
        require(path[path.length - 1] == WBNB, 'CrosswiseRouter: INVALID_PATH');
        antiWhale(path, amountIn);
        verifyPrice(path, amountIn, 0);
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, CrosswiseLibrary.pairFor(factory, path[0], path[1]), amountIn
        );
        _swapSupportingFeeOnTransferTokens(path, address(this));
        uint amountOut = IBEP20(WBNB).balanceOf(address(this));
        require(amountOut >= amountOutMin, 'CrosswiseRouter: INSUFFICIENT_OUTPUT_AMOUNT');
        IWBNB(WBNB).withdraw(amountOut);
        TransferHelper.safeTransferETH(to, amountOut);
    }


    function setAntiWhale(address lp, bool status) external {
        require(lpCreators[lp] == msg.sender, "CrosswiseRouter.setAntiWhale: invalid sender");
        antiWhalePerLp[lp] = status;
        emit SetAntiWhale(lp, status);
    }

    function setwhitelistToken(address token, bool status) external {
        require(msg.sender == admin, "CrosswiseRouter.setwhitelistToken: invalid sender");
        whitelistTokens[token] = status;
        emit SetwhitelistToken(token, status);
    }
    // **** LIBRARY FUNCTIONS ****
    function quote(uint amountA, uint reserveA, uint reserveB) public pure virtual override returns (uint amountB) {
        return CrosswiseLibrary.quote(amountA, reserveA, reserveB);
    }

    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut)
        public
        pure
        virtual
        override
        returns (uint amountOut)
    {
        return CrosswiseLibrary.getAmountOut(amountIn, reserveIn, reserveOut);
    }

    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut)
        public
        pure
        virtual
        override
        returns (uint amountIn)
    {
        return CrosswiseLibrary.getAmountIn(amountOut, reserveIn, reserveOut);
    }

    function getAmountsOut(uint amountIn, address[] memory path)
        public
        view
        virtual
        override
        returns (uint[] memory amounts)
    {
        return CrosswiseLibrary.getAmountsOut(factory, amountIn, path);
    }

    function getAmountsIn(uint amountOut, address[] memory path)
        public
        view
        virtual
        override
        returns (uint[] memory amounts)
    {
        return CrosswiseLibrary.getAmountsIn(factory, amountOut, path);
    }

    // price guard
    function pausePriceGuard(address _lp, bool _paused) external {
        require(
            lpCreators[_lp] == msg.sender,
            'CrosswiseRouter.pausePriceGuard: invalid sender'
        );
        priceGuardPaused[_lp] = _paused;
        emit PausePriceGuard(_lp, _paused);
    }

    function setMaxSpreadTolerance(address _lp, uint256 _tolerance) external {
        require(
            lpCreators[_lp] == msg.sender,
            'CrosswiseRouter.setMaxSpreadTolerance: invalid sender'
        );
        maxSpreadTolerance[_lp] = _tolerance;
    }

    function getPairPrice(
        address _token0,
        address _token1,
        uint256 _amountIn,
        uint256 _amountOut
    ) internal view returns (uint256) {
        (address token0,) = CrosswiseLibrary.sortTokens(_token0, _token1);
        (uint256 reserve0, uint256 reserve1) =
            CrosswiseLibrary.getReserves(factory, _token0, _token1);
        (reserve0, reserve1) =
            token0 == _token0 ?
            (reserve0, reserve1) :
            (reserve1, reserve0);
        (uint256 amountIn, uint256 amountOut) = _amountIn == 0 ?
            (CrosswiseLibrary.getAmountIn(
                _amountOut,
                reserve0,
                reserve1
            ), _amountOut) :
            (_amountIn, CrosswiseLibrary.getAmountOut(
                _amountIn,
                reserve0,
                reserve1
            ));

        (uint256 decimals0, uint256 decimals1) =
            (IBEP20(_token0).decimals(), IBEP20(_token1).decimals());
        return (amountIn.mul(10 ** decimals1)).mul(10 ** 8) /
            (amountOut * (10 ** decimals0));
    }

    function verifyPrice(
        address[] memory _path,
        uint256 _amountIn,
        uint256 _amountOut
    ) internal view {
        for (uint256 i = 0; i < _path.length - 1; i++) {
            ICrosswisePair pair =
                ICrosswisePair(
                    CrosswiseLibrary.pairFor(factory, _path[i], _path[i + 1])
                );

            if (!priceGuardPaused[address(pair)]) {
                require(
                    maxSpreadTolerance[address(pair)] > 0,
                    "max spread tolerance not initialized"
                );
                uint256 pairPrice =
                    getPairPrice(
                        _path[i],
                        _path[i + 1],
                        _amountIn,
                        _amountOut
                    );
                uint256 oraclePrice = priceConsumer.getLatestPrice(
                    address(pair)
                );
                uint256 minPrice =
                    pairPrice < oraclePrice ?
                    pairPrice :
                    oraclePrice;
                uint256 maxPrice =
                    pairPrice < oraclePrice ?
                    oraclePrice :
                    pairPrice;
                uint256 upperLimit =
                    minPrice.mul(maxSpreadTolerance[
                        address(pair)
                    ].add(10000)) / 10000;
                require(
                    maxPrice <= upperLimit,
                    'CrosswiseRouter.verifyPrice: verify price is failed'
                );
            }
        }
    }
}
