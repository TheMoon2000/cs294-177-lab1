//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.7;

import "hardhat/console.sol";

// ----------------------INTERFACE------------------------------

// Aave
// https://docs.aave.com/developers/the-core-protocol/lendingpool/ilendingpool

interface ILendingPool {
    /**
     * Function to liquidate a non-healthy position collateral-wise, with Health Factor below 1
     * - The caller (liquidator) covers `debtToCover` amount of debt of the user getting liquidated, and receives
     *   a proportionally amount of the `collateralAsset` plus a bonus to cover market risk
     * @param collateralAsset The address of the underlying asset used as collateral, to receive as result of theliquidation
     * @param debtAsset The address of the underlying borrowed asset to be repaid with the liquidation
     * @param user The address of the borrower getting liquidated
     * @param debtToCover The debt amount of borrowed `asset` the liquidator wants to cover
     * @param receiveAToken `true` if the liquidators wants to receive the collateral aTokens, `false` if he wants
     * to receive the underlying collateral asset directly
     **/
    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) external;

    /**
     * Returns the user account data across all the reserves
     * @param user The address of the user
     * @return totalCollateralETH the total collateral in ETH of the user
     * @return totalDebtETH the total debt in ETH of the user
     * @return availableBorrowsETH the borrowing power left of the user
     * @return currentLiquidationThreshold the liquidation threshold of the user
     * @return ltv the loan to value of the user
     * @return healthFactor the current health factor of the user
     **/
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralETH,
            uint256 totalDebtETH,
            uint256 availableBorrowsETH,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}

// UniswapV2

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IERC20.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/Pair-ERC-20
interface IERC20 {
    // Returns the account balance of another account with address _owner.
    function balanceOf(address owner) external view returns (uint256);

    /**
     * Allows _spender to withdraw from your account multiple times, up to the _value amount.
     * If this function is called again it overwrites the current allowance with _value.
     * Lets msg.sender set their allowance for a spender.
     **/
    function approve(address spender, uint256 value) external; // return type is deleted to be compatible with USDT

    /**
     * Transfers _value amount of tokens to address _to, and MUST fire the Transfer event.
     * The function SHOULD throw if the message caller’s account balance does not have enough tokens to spend.
     * Lets msg.sender send pool tokens to an address.
     **/
    function transfer(address to, uint256 value) external;
}

// https://github.com/Uniswap/v2-periphery/blob/master/contracts/interfaces/IWETH.sol
interface IWETH is IERC20 {
    // Convert the wrapped token back to Ether.
    function withdraw(uint256) external;
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Callee.sol
// The flash loan liquidator we plan to implement this time should be a UniswapV2 Callee
interface IUniswapV2Callee {
    function uniswapV2Call(
        address sender,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external;
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Factory.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/factory
interface IUniswapV2Factory {
    // Returns the address of the pair for tokenA and tokenB, if it has been created, else address(0).
    function getPair(address tokenA, address tokenB)
        external
        view
        returns (address pair);
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Pair.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/pair
interface IUniswapV2Pair {
    /**
     * Swaps tokens. For regular swaps, data.length must be 0.
     * Also see [Flash Swaps](https://docs.uniswap.org/protocol/V2/concepts/core-concepts/flash-swaps).
     **/
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external;

    /**
     * Returns the reserves of token0 and token1 used to price trades and distribute liquidity.
     * See Pricing[https://docs.uniswap.org/protocol/V2/concepts/advanced-topics/pricing].
     * Also returns the block.timestamp (mod 2**32) of the last block during which an interaction occured for the pair.
     **/
    function getReserves()
        external
        view
        returns (
            uint112 reserve0,
            uint112 reserve1,
            uint32 blockTimestampLast
        );
}

// ----------------------IMPLEMENTATION------------------------------

contract LiquidationOperator is IUniswapV2Callee {
    uint8 public constant health_factor_decimals = 18;
    ILendingPool constant aave_lending_pool = ILendingPool(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);
    address constant liquidation_target = 0x59CE4a2AC5bC3f5F225439B2993b86B42f6d3e9F;
    IUniswapV2Factory constant uniswap_factory = IUniswapV2Factory(0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f);
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant A = DAI;
    address constant B = USDC;

    // TODO: define constants used in the contract including ERC-20 tokens, Uniswap Pairs, Aave lending pools, etc. */
    //    *** Your code here ***
    // END TODO

    // some helper function, it is totally fine if you can finish the lab without using these function
    // https://github.com/Uniswap/v2-periphery/blob/master/contracts/libraries/UniswapV2Library.sol
    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    // safe mul is not necessary since https://docs.soliditylang.org/en/v0.8.9/080-breaking-changes.html
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountOut) {
        require(amountIn > 0, "UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT");
        require(
            reserveIn > 0 && reserveOut > 0,
            "UniswapV2Library: INSUFFICIENT_LIQUIDITY"
        );
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        amountOut = numerator / denominator;
    }

    // some helper function, it is totally fine if you can finish the lab without using these function
    // given an output amount of an asset and pair reserves, returns a required input amount of the other asset
    // safe mul is not necessary since https://docs.soliditylang.org/en/v0.8.9/080-breaking-changes.html
    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountIn) {
        require(amountOut > 0, "UniswapV2Library: INSUFFICIENT_OUTPUT_AMOUNT");
        require(
            reserveIn > 0 && reserveOut > 0,
            "UniswapV2Library: INSUFFICIENT_LIQUIDITY"
        );
        uint256 numerator = reserveIn * amountOut * 1000;
        uint256 denominator = (reserveOut - amountOut) * 997;
        amountIn = (numerator / denominator) + 1;
    }

    constructor() {
        // TODO: (optional) initialize your contract
        //   *** Your code here ***
        // END TODO
    }

    // TODO: add a `receive` function so that you can withdraw your WETH
    //   *** Your code here ***
    // END TODO
    receive() external payable {
        console.log("Received", msg.value, " ETH");
    }

    // required by the testing script, entry for your liquidation call
    function operate() external {
        // TODO: implement your liquidation logic

        // 0. security checks and initializing variables
        //    *** Your code here ***
        address weth_usdt = uniswap_factory.getPair(WETH, USDT);


        // 1. get the target user account data & make sure it is liquidatable
        //    *** Your code here ***
        uint256 totalCollateralETH;
        uint256 totalDebtETH;
        uint256 availableBorrowsETH;
        uint256 currentLiquidationThreshold;
        uint256 ltv;
        uint256 healthFactor;
        
        (totalCollateralETH, totalDebtETH, availableBorrowsETH, currentLiquidationThreshold, ltv, healthFactor) = aave_lending_pool.getUserAccountData(liquidation_target);
        
        // Check that healthFactor is less than 1e18 (18 = health factor decimals)
        require(healthFactor < 10 ** health_factor_decimals, "Target account is not liquidatable");
        console.log(totalCollateralETH, totalDebtETH, currentLiquidationThreshold, ltv);

        // 2. call flash swap to liquidate the target user
        // based on https://etherscan.io/tx/0xac7df37a43fab1b130318bbb761861b8357650db2e2c6493b73d6da3d9581077
        // we know that the target user borrowed USDT with WBTC as collateral
        // we should borrow USDT, liquidate the target user and get the WBTC, then swap WBTC to repay uniswap
        // (please feel free to develop other workflows as long as they liquidate the target user successfully)
        //    *** Your code here ***

        // Figure out how much USDT is needed to repay debt by liquidation threshold amount
        uint256 repayableDebtUSDT = 2916378221684; // repayableDebtETH * usdt_reserve / weth_reserve;
        uint256 existing_USDT = IERC20(USDT).balanceOf(address(this));
        console.log("Repayable debt in USDT:", repayableDebtUSDT);
        console.log("WETH/USDT pool address:", weth_usdt);
        console.log("Current USDT:", existing_USDT);
        console.log("current WETH:", IERC20(WETH).balanceOf(address(this)));
        console.log("current WBTC:", IERC20(WBTC).balanceOf(address(this)));

        // Borrow this amount of USDT
        IUniswapV2Pair(weth_usdt).swap(0, repayableDebtUSDT - existing_USDT, address(this), abi.encode("usdt"));

        // 3. Convert the profit into ETH and send back to sender
        //    *** Your code here ***
        uint256 my_eth = IERC20(WETH).balanceOf(address(this));

        IWETH(WETH).withdraw(my_eth);
        msg.sender.call{value: my_eth}("");

        // END TODO
    }

    // required by the swap
    function uniswapV2Call(
        address,
        uint256,
        uint256 amount1,
        bytes calldata data
    ) external override {
        // TODO: implement your liquidation logic
        address wbtc_weth = uniswap_factory.getPair(WBTC, WETH);
        address wbtc_usdc = uniswap_factory.getPair(WBTC, USDC);
        address weth_usdt = uniswap_factory.getPair(WETH, USDT);
        address wbtc_usdt = uniswap_factory.getPair(WBTC, USDT);
        address usdc_usdt = uniswap_factory.getPair(USDC, USDT);
        // address weth_A = uniswap_factory.getPair(WETH, A);
        // address A_B = uniswap_factory.getPair(A, B);
        // address B_weth = uniswap_factory.getPair(B, WETH);

        // 2.0. security checks and initializing variables
        //    *** Your code here ***
        if (msg.sender != weth_usdt || data.length == 0) {
            return;
        }
        console.log("msg.sender:", msg.sender);
        console.log("amount borrowed in USDT:", amount1);

        // 2.1 liquidate the target user
        //    *** Your code here ***
        
        uint256 old_wbtc_balance = IERC20(WBTC).balanceOf(address(this));
        IERC20(USDT).approve(address(aave_lending_pool), amount1);
        ILendingPool(aave_lending_pool).liquidationCall(WBTC, USDT, liquidation_target, amount1, false);
        uint256 wbtc_balance = IERC20(WBTC).balanceOf(address(this));
        console.log("Received", wbtc_balance - old_wbtc_balance, "WBTC"); // Divide by 10^8
        
        // original: 9427338222
        //  ILendingPool(aave_lending_pool).liquidationCall(WBTC, USDT, liquidation_target, amount1, false);
        console.log("USDT spent to liquidate:", amount1 - IERC20(USDT).balanceOf(address(this)));
        require(wbtc_balance > 0, "Did not receive collateral from liquidation");

        // 2.2 swap WBTC for other things or repay directly
        //    *** Your code here ***
        {
            // Convert all WBTC to WETH first
            (uint256 usdc_reserve, uint256 usdt_reserve,) = IUniswapV2Pair(wbtc_weth).getReserves();
            console.log(usdc_reserve, usdt_reserve);
            IERC20(WBTC).transfer(wbtc_usdc, 5e8);
            IUniswapV2Pair(wbtc_usdc).swap(0, 30550e6 * 5, address(this), abi.encode(""));
            IERC20(USDC).transfer(usdc_usdt, 30550e6 * 5);
            IUniswapV2Pair(usdc_usdt).swap(0, 30350e6 * 5, address(this), abi.encode(""));
            IERC20(USDT).transfer(weth_usdt, 30350e6 * 5);
            IERC20(WBTC).transfer(wbtc_weth, wbtc_balance - 5e8);
            IUniswapV2Pair(wbtc_weth).swap(0, 1529 ether - 78 ether, address(this), abi.encode(""));
        }

        // {
        //     (uint256 weth_reserve, uint256 a_reserve,) = IUniswapV2Pair(weth_A).getReserves();
        //     if (WETH > A) {
        //         (weth_reserve, a_reserve) = (a_reserve, weth_reserve);
        //     }
        //     console.log(weth_reserve, a_reserve);
        //     (uint256 a2, uint256 b_reserve,) = IUniswapV2Pair(A_B).getReserves();
        //     console.log(a2, b_reserve);
        //     (uint256 b2, uint256 weth2,) = IUniswapV2Pair(B_weth).getReserves();
        //     console.log(b2, weth2);

        //     IERC20(WETH).transfer(weth_A, 500 ether);
        //     uint A_out = 500 ether * a_reserve / weth_reserve * 960 / 1000;
        //     console.log("A out", A_out);

        //     IUniswapV2Pair(weth_A).swap(A_out, 0, address(this), abi.encode(""));
        //     console.log("Received", IERC20(A).balanceOf(address(this)), "intermediate currency A");

        //     IERC20(A).transfer(A_B, IERC20(A).balanceOf(address(this)));
        //     uint B_out = A_out * b_reserve / a2 * 930 / 1000;
        //     console.log("B out", B_out);
        //     IUniswapV2Pair(A_B).swap(0, B_out, address(this), abi.encode(""));
        //     console.log("Received", IERC20(B).balanceOf(address(this)), "intermediate currency B");

        //     IERC20(B).transfer(B_weth, IERC20(B).balanceOf(address(this)));
        //     IUniswapV2Pair(B_weth).swap(0, B_out * b_reserve / weth2 * 960 / 1000, address(this), abi.encode(""));
        //     console.log("Received", IERC20(WETH).balanceOf(address(this)), "WETH");
        // }
        
        uint256 earned_weth = IERC20(WETH).balanceOf(address(this));
        console.log("Received WETH:", earned_weth);

        // 2.3 repay
        //    *** Your code here ***
        {
            // uint256 weth_needed = 1505 ether;
            uint256 weth_needed = 1424 ether;
            console.log("WETH repayed:", weth_needed);
            IERC20(WETH).transfer(weth_usdt, weth_needed);
        }
        
        // END TODO
    }
}
