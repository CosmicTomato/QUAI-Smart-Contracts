// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.7.5;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

contract WaterfallPresale is Ownable {
    using SafeMath for uint256;

    uint256 public constant presaleStart = 1611014400; //Tuesday, January 19, 2021 12:00:00 AM GMT
    uint256 public constant presaleEnd = 1612224000; //Tuesday, February 2, 2021 12:00:00 AM GMT
    uint256 public constant claimStart = 1612310400; //Wednesday, February 3, 2021 12:00:00 AM GMT
    uint256 public constant claimEnd = 1617408000; //Saturday, April 3, 2021 12:00:00 AM GMT
    bool public endedEarly = false;

    address public quaiToken = 0x40821CD074dfeCb1524286923bC69315075b5c89; //token to sell
    address public constant uniswapV2router =
        0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    IUniswapV2Router02 router = IUniswapV2Router02(uniswapV2router);

    uint256 public totalTokensSold = 0; //sum of all tokens sold (returned as smallest unit of token)
    uint256[2] tokensPerEth; //token exchange rates in stages of waterfall
    uint256[2] tokenCeilings; //amounts of tokens in stages of waterfall
    uint256 private currentPriceLevel = 0; //stage of waterfall for token exchange rate

    uint256 public totalEthReceived = 0; //sum of all sales in ETH (returned as wei)

    uint256 public uniswapPoolEth = 0; //ETH to be pooled in Uniswap according to LP waterfall distribution
    uint256[5] ethTargets; //ETH amounts for stages of LP waterfall
    uint256[5] percentLevels; //percent of ETH to be pooled in Uniswap in stages of waterfall
    uint256 private constant percentPrecision = 100; //divisor for percentages
    uint256 private currentEthTarget = 0; //stage of LP waterfall

    mapping(address => uint256) public balances; //keeps track of pending balances to be claimed once the claim process begins
    mapping(address => bool) approvedTokens; //keeps track of ERC20 tokens approved by owner as purchase methods

    event Sold(address user, uint256 amountTokens);
    event Claimed(address user, uint256 amountTokens);

    constructor() {
        tokensPerEth[0] = (4000 * 1e18); //listed as tokens for an entire Ether (10^18 wei). assumes sold tokens have 18 decimals in calculations.
        tokensPerEth[1] = (2222 * 1e18); //prices are 25cents and 45cents a token at $1000/ETH

        tokenCeilings[0] = 2500000000000000000000000; //2.5million tokens
        tokenCeilings[1] = 5000000000000000000000000; //5million tokens

        ethTargets[0] = 400 ether;
        ethTargets[1] = 600 ether;
        ethTargets[2] = 800 ether;
        ethTargets[3] = 1000 ether;
        ethTargets[4] = uint256(-1);

        percentLevels[0] = 25; //% to go to Uniswap up to ethTarget
        percentLevels[1] = 20;
        percentLevels[2] = 15;
        percentLevels[3] = 10;
        percentLevels[4] = 5;
    }

    receive() external payable {}

    function buyTokens() external payable {
        processPurchase(msg.value, msg.sender);
    }

    function processPurchase(uint256 etherValue, address user) internal {
        require(
            block.timestamp >= presaleStart,
            "processPurchase: presale has not yet started"
        );
        require(
            block.timestamp <= presaleEnd,
            "processPurchase: presale has ended"
        );
        require(!endedEarly, "processPurchase: presale was ended early");
        etherWaterfall(etherValue);
        getTokensFromEth(etherValue, user);
    }

    function etherWaterfall(uint256 etherValue) internal {
        uint256 ethToTarget = ethTargets[currentEthTarget] - totalEthReceived;
        uint256 etherRemaining = etherValue;

        //ether waterfall -- while loop covers all cases where purchase value overflows one or more ether targets
        while (etherRemaining >= ethToTarget) {
            //move to next level of token waterfall
            uniswapPoolEth += (ethToTarget.mul(percentLevels[currentEthTarget]))
                .div(percentPrecision);
            etherRemaining -= ethToTarget;
            currentEthTarget += 1;
            //get ETH size for next level of waterfall
            ethToTarget =
                ethTargets[currentEthTarget] -
                ethTargets[(currentEthTarget - 1)];
        }

        //get uniswapPool amount for current waterfall level -- this is the only part of the logic that will be called when the purchase does not overflow a level
        uniswapPoolEth += (etherRemaining.mul(percentLevels[currentEthTarget]))
            .div(percentPrecision);

        //update total ether received
        totalEthReceived += etherValue;
    }

    function getTokensFromEth(uint256 ethInput, address user) internal {
        uint256 tokensToCeiling =
            tokenCeilings[currentPriceLevel] - totalTokensSold;
        uint256 valueRemaining = ethInput;
        uint256 tokens = 0;

        //token waterfall -- while loop covers all cases where purchase value overflows one or more token levels
        while (
            valueRemaining.mul(tokensPerEth[currentPriceLevel]).div(
                uint256(1e18)
            ) >= tokensToCeiling
        ) {
            //move to next level of LP waterfall
            require(
                currentPriceLevel < (tokenCeilings.length - 1),
                "getTokensFromEth: purchase would exceed max token ceiling"
            );
            tokens += tokensToCeiling;
            valueRemaining -= tokensToCeiling.mul(uint256(1e18)).div(
                tokensPerEth[currentPriceLevel]
            );
            currentPriceLevel += 1;
            //get token size for next level of waterfall
            tokensToCeiling =
                tokenCeilings[currentPriceLevel] -
                tokenCeilings[(currentPriceLevel - 1)];
        }

        //get tokens for current waterfall level -- this is the only part of the logic that will be called when the purchase does not overflow a level
        tokens += valueRemaining.mul(tokensPerEth[currentPriceLevel]).div(
            uint256(1e18)
        );

        //store token balance for msg.sender to be withdrawn later
        totalTokensSold += tokens;
        balances[user] += tokens;
        emit Sold(user, tokens);
    }

    //claims tokens for the user
    function claimTokens() external returns (uint256) {
        require(
            (block.timestamp >= claimStart || endedEarly),
            "claimTokens: tokens cannot yet be claimed"
        );
        uint256 amountToSend = balances[msg.sender];
        balances[msg.sender] = 0;
        IERC20(quaiToken).transfer(msg.sender, amountToSend);
        emit Claimed(msg.sender, amountToSend);
        return (amountToSend);
    }

    //allows owner to reclaim any leftover tokens after the claim period is over
    function recoverUnclaimed() external onlyOwner() {
        require(
            block.timestamp >= claimEnd,
            "recoverUnclaimed: token claim period has not yet ended"
        );
        uint256 amountToSend = IERC20(quaiToken).balanceOf(address(this));
        IERC20(quaiToken).transfer(msg.sender, amountToSend);
    }

    //allows owner to withdraw ETH from contract
    function withdrawEth() external onlyOwner() {
        uint256 amountToSend = address(this).balance;
        address payable receiver = payable(owner());
        receiver.transfer(amountToSend);
    }

    //allows owner to recover ERC20 tokens mistakenly sent to contract
    function recoverTokens(
        address tokenAddress,
        address dest,
        uint256 amountTokens
    ) external onlyOwner() {
        require(
            tokenAddress != quaiToken,
            "recoverTokens: cannot move sold token"
        );
        IERC20(tokenAddress).transfer(dest, amountTokens);
    }

    //gets expected amount of ETH from input amount of ERC20 token
    function getExpectedEth(address tokenAddress, uint256 amountIn)
        public
        view
        returns (uint256)
    {
        address[] memory _path = new address[](2);
        _path[0] = tokenAddress;
        _path[1] = router.WETH();
        uint256[] memory _amts = router.getAmountsOut(amountIn, _path);
        return _amts[1];
    }

    //internally adds purchase option
    function addPurchaseOption(address tokenAddress) internal {
        approvedTokens[tokenAddress] = true;
        IERC20(tokenAddress).approve(uniswapV2router, uint256(-1));
    }

    //adds an ERC20 token as a purchase option
    function newPurchaseOption(address tokenAddress) external onlyOwner() {
        require(
            approvedTokens[tokenAddress] == false,
            "newPurchaseOption: token already added"
        );
        addPurchaseOption(tokenAddress);
    }

    //ends sale early -- prevents any further sales and allows claim process to begin
    function endEarly() external onlyOwner() {
        endedEarly = true;
    }

    function purchaseWithERC20(address tokenAddress, uint256 amountIn)
        external
    {
        require(
            approvedTokens[tokenAddress] == true,
            "token is not approved as payment option"
        );
        require(
            IERC20(tokenAddress).allowance(msg.sender, address(this)) >=
                amountIn,
            "token approval is insufficent for purchase"
        );
        IERC20(tokenAddress).transferFrom(msg.sender, address(this), amountIn);
        address[] memory path = new address[](2);
        path[0] = tokenAddress;
        path[1] = router.WETH();
        uint256 deadline = (block.timestamp + 1200); //20min window for transaction to be confirmed, otherwise it will revert
        uint256[] memory _amts =
            router.swapExactTokensForETH(
                amountIn,
                uint256(0),
                path,
                address(this),
                deadline
            );
        processPurchase(_amts[1], msg.sender);
    }

    function expectedTokensFromETH(uint256 ethInput)
        public
        view
        returns (uint256)
    {
        uint256 tokensToCeiling =
            tokenCeilings[currentPriceLevel] - totalTokensSold;
        uint256 valueRemaining = ethInput;
        uint256 tokens = 0;
        uint256 virtualPriceLevel = currentPriceLevel;

        //token waterfall -- while loop covers all cases where purchase value overflows one or more token levels
        while (
            valueRemaining.mul(tokensPerEth[virtualPriceLevel]).div(
                uint256(1e18)
            ) >= tokensToCeiling
        ) {
            require(
                virtualPriceLevel < (tokenCeilings.length - 1),
                "getTokensFromEth: purchase would exceed max token ceiling"
            );
            tokens += tokensToCeiling;
            valueRemaining -= tokensToCeiling.mul(uint256(1e18)).div(
                tokensPerEth[virtualPriceLevel]
            );
            //move to next level of waterfall
            virtualPriceLevel += 1;
            //get token size for next level of waterfall
            tokensToCeiling =
                tokenCeilings[virtualPriceLevel] -
                tokenCeilings[(virtualPriceLevel - 1)];
        }

        //get tokens for current waterfall level -- this is the only part of the logic that will be called when the purchase does not overflow a level
        tokens += valueRemaining.mul(tokensPerEth[virtualPriceLevel]).div(
            uint256(1e18)
        );
        return tokens;
    }

    function expectedTokensFromERC20(address tokenAddress, uint256 amountIn)
        external
        view
        returns (uint256)
    {
        uint256 ethInput = getExpectedEth(tokenAddress, amountIn);
        uint256 tokensOut = expectedTokensFromETH(ethInput);
        return tokensOut;
    }

    function currentTokensPerEth() external view returns (uint256) {
        return (tokensPerEth[currentPriceLevel]);
    }
}

contract QUAIDAO_Staking is Ownable {
    using SafeMath for uint256;

    address public quaiToken = 0x40821CD074dfeCb1524286923bC69315075b5c89; //token to stake

    uint256 public stakingEnd; //point after which staking rewards cease to accumulate
    uint256 public constant rewardRate = 15; //15% return per staking period
    uint256 public constant stakingPeriod = 30 days; //period over which tokens are locked after staking
    uint256 public constant maxTotalStaked = 35e23; //3.5 million tokens
    uint256 public totalStaked; //sum of all user stakes
    uint256 public minStaked = 1e21; //1000 tokens. min staked per user

    mapping(address => uint256) public stakedTokens; //amount of tokens that address has staked
    mapping(address => uint256) public lastStaked; //last time at which address staked, deposited, or "rolled over" their position by calling updateStake directly
    mapping(address => uint256) public totalEarnedTokens;

    constructor() {
        stakingEnd = (block.timestamp + 365 days);
    }

    function deposit(uint256 amountTokens) external {
        require(
            (stakedTokens[msg.sender] >= minStaked ||
                amountTokens >= minStaked),
            "deposit: must exceed minimum stake"
        );
        require(
            totalStaked + amountTokens <= maxTotalStaked,
            "deposit: amount would exceed max stake. call updateStake to claim dividends"
        );
        updateStake();
        IERC20(quaiToken).transferFrom(msg.sender, address(this), amountTokens);
        stakedTokens[msg.sender] += amountTokens;
        totalStaked += amountTokens;
    }

    function updateStake() public {
        uint256 stakedUntil = min(block.timestamp, stakingEnd);
        uint256 periodStaked = stakedUntil.sub(lastStaked[msg.sender]);
        uint256 dividends;
        //linear rewards up to stakingPeriod
        if (periodStaked < stakingPeriod) {
            dividends = periodStaked
                .mul(stakedTokens[msg.sender])
                .mul(rewardRate)
                .div(stakingPeriod)
                .div(100);
        } else {
            dividends = stakedTokens[msg.sender].mul(rewardRate).div(100);
        }
        //update lastStaked time for msg.sender -- user cannot unstake until end of another stakingPeriod
        lastStaked[msg.sender] = stakedUntil;
        //withdraw dividends for user if rolling over dividends would exceed staking cap, else stake the dividends automatically
        if (totalStaked + dividends > maxTotalStaked) {
            IERC20(quaiToken).transfer(msg.sender, dividends);
        } else {
            stakedTokens[msg.sender] += dividends;
            totalStaked += dividends;
        }
    }

    function withdrawDividends() external {
        uint256 stakedUntil = min(block.timestamp, stakingEnd);
        uint256 periodStaked = stakedUntil.sub(lastStaked[msg.sender]);
        uint256 dividends;
        //linear rewards up to stakingPeriod
        if (periodStaked < stakingPeriod) {
            dividends = periodStaked
                .mul(stakedTokens[msg.sender])
                .mul(rewardRate)
                .div(stakingPeriod)
                .div(100);
        } else {
            dividends = stakedTokens[msg.sender].mul(rewardRate).div(100);
        }
        //update lastStaked time for msg.sender -- user cannot unstake until end of another stakingPeriod
        lastStaked[msg.sender] = stakedUntil;
        //withdraw dividends for user
        IERC20(quaiToken).transfer(msg.sender, dividends);
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function unstake() external {
        uint256 timeSinceStake = (block.timestamp).sub(lastStaked[msg.sender]);
        require(
            timeSinceStake >= stakingPeriod,
            "unstake: staking period for user still ongoing"
        );
        updateStake();
        uint256 toTransfer = stakedTokens[msg.sender];
        stakedTokens[msg.sender] = 0;
        IERC20(quaiToken).transfer(msg.sender, toTransfer);
        totalStaked -= toTransfer;
    }

    function getPendingDivs(address user) external view returns (uint256) {
        uint256 stakedUntil = min(block.timestamp, stakingEnd);
        uint256 periodStaked = stakedUntil.sub(lastStaked[user]);
        uint256 dividends;
        //linear rewards up to stakingPeriod
        if (periodStaked < stakingPeriod) {
            dividends = periodStaked
                .mul(stakedTokens[user])
                .mul(rewardRate)
                .div(stakingPeriod)
                .div(100);
        } else {
            dividends = stakedTokens[user].mul(rewardRate).div(100);
        }
        return (dividends);
    }

    function recoverTokens(
        address tokenAddress,
        address dest,
        uint256 amountTokens
    ) external onlyOwner() {
        require(
            tokenAddress != quaiToken,
            "recoverTokens: cannot move staked token"
        );
        IERC20(tokenAddress).transfer(dest, amountTokens);
    }

    function recoverQUAI() external onlyOwner() {
        require(
            block.timestamp >= (stakingEnd + 60 days),
            "recoverQUAI: too early"
        );
        uint256 amountToSend = IERC20(quaiToken).balanceOf(address(this));
        IERC20(quaiToken).transfer(msg.sender, amountToSend);
    }

    function updateMinStake(uint256 newMinStake) external onlyOwner() {
        minStaked = newMinStake;
    }
}
