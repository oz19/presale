// SPDX-License-Identifier: MIT

pragma solidity 0.8.34;

import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "src/interfaces/IAggregator.sol";


contract PresaleApp is Ownable {

    using SafeERC20 for IERC20;

    address public internalWallet;  // Funds will be stored here
    address public usdtAddress;
    address public usdcAddress;
    uint256 public maxSupply;
    uint256 public totalSold;
    uint256 public startTime;
    uint256 public endTime;
    uint256[][3] public phases;
    uint256 public currentPhase;
    uint256 public dataFeedAddress;
    mapping(address => bool) public isBanned;
    mapping(address => bool) public allowedPayingTokens;
    mapping(address => uint256) public balances;

    modifier BanCheck() {
        require(!isBanned[msg.sender], "User is banned");
        _;
    }

    event BuyToken(address buyer, uint256 amount);

    constructor (
        address internalWallet_,
        address usdtAddress_,
        address usdcAddress_,
        uint256 maxSupply_,
        uint256 startTime_,
        uint256 endTime_,
        uint256 dataFeedAddress_,
        uint256[][3] memory phases_
    ) Ownable(msg.sender) {
        internalWallet = internalWallet_;
        usdtAddress = usdtAddress_;
        usdcAddress = usdcAddress_;
        maxSupply = maxSupply_;
        startTime = startTime_;
        endTime = endTime_;
        phases = phases_;
        dataFeedAddress = dataFeedAddress_;

        require(endTime > startTime, "Start time should be before End time");

        // Allowed tokens used to buy
        allowedPayingTokens[usdtAddress] = true;
        allowedPayingTokens[usdcAddress] = true;
    }

    function ban(address user_) onlyOwner external {
        isBanned[user_] = true;
    }

    function removeBan(address user_) onlyOwner external {
        delete isBanned[user_];
    }

    /**
    * Used to buy tokens with Stablecoins.
    * @param tokenUsedToBuy_ the address of the token used to buy (must be an allowed token)
    * @param amount_ amount in dollars (USDC, USDT...) used to buy our token
    */
    function buyWithStable(address tokenUsedToBuy_, uint256 amount_) banCheck external {
        require(block.timestamp >= startTime && block.timestamp <= endTime, "Out of presale period");
        require(allowedPayingTokens[tokenUsedToBuy_], "Paying token not allowed");

        uint256 tokenAmountToReceive = calculateTokenAmountToReceive(tokenUsedToBuy_, amount_);
        currentPhaseCheck(tokenAmountToReceive);

        totalSold += tokenAmountToReceive;
        require(totalSold <= maxSupply, "Max supply exceeded");

        balances[msg.sender] += tokenAmountToReceive;

        IERC20(tokenUsedToBuy_).safeTransferFrom(msg.sender, internalWallet, amount_);

        emit BuyToken(msg.sender, tokenAmountToReceive);
    }

    /**
    * Used to buy tokens with Stablecoins.
    * @param amount_ amount in dollars (USDC, USDT...) used to buy our token
    */
    function buyWithEther() banCheck payable external {
        require(block.timestamp >= startTime && block.timestamp <= endTime, "Out of presale period");

        uint256 ethUsdPrice = getEthUsdPriceWith18Decimals();  // From data feed (oracle)
        uint256 tokenAmountToReceive = calculateTokenAmountToReceiveFromEther(
            ethUsdPrice,
            msg.value  // Ether with 18 decimals
        );
        currentPhaseCheck(tokenAmountToReceive);

        totalSold += tokenAmountToReceive;
        require(totalSold <= maxSupply, "Max supply exceeded");

        balances[msg.sender] += tokenAmountToReceive;

        (bool success,) = internalWallet.call{value: msg.value}("");
        require(success, "Transfer failed");

        emit BuyToken(msg.sender, tokenAmountToReceive);
    }

    function getEtherPriceWith18Decimals() internal returns(uint256) {
        // Returns a price with 8 decimals
        (, int256 answer,,,) = IAggregator(dataFeedAddress).latestRoundData();
        uint256 price = uint256(answer * (10**10));  // Ether price represented with 18 decimals (8+10)
        return price
    }

    function emergencyTokenWithdraw(address token_, uint256 amount_) onlyOwner external {
        IERC20(token_).safeTransfer(msg.sender, amount_);
    }

    function emergencyEtherWithdraw() onlyOwner external {
        uint256 balance = address(this).balance;
        (bool success,) = msg.sender.call{value: balance}("");
        require(success, "Transfer failed");
    }

    // Internal functions

    /**
    * Internal function to calculate the number of tokens to return for a given amount (in USDT or 
    * a similar token representing USD). It also adjusts the number of decimals required to return 
    * a value that can be represented with exactly 18 decimals.
    * @param tokenUsedToBuy_ the address of the token used to buy (must be an allowed token)
    * @param amount_ amount in dollars (USDC, USDT...) used to buy our token
    */
    function calculateTokenAmountToReceive(
        address tokenUsedToBuy_,
        uint256 amount_
    ) internal returns(uint256) {
        uint256 price = phases[currentPhase_][1];  // Price in USDT format (6 decimals)
        uint256 resultDecimals = 18;
        uint256 priceDecimals = 6;
        uint256 amountDecimals = IERC20(tokenUsedToBuy_).decimals();
        // resultDec = amountDec - priceDec + adjustmentDec --> We can get adjustmentDec
        uint256 adjustmentDecimals = resultDecimals + priceDecimals - amountDecimals;
        return (amount * 10**adjustmentDecimals) / price;
    }

    function calculateTokenAmountToReceiveFromEther(uint256 etherPriceInUsd_, uint256 amount_) internal returns(uint256) {
        uint256 decimalAdjustment = 10**18;  // amount_ has 18 decimals
        uint256 usdAmount = etherPriceInUsd_ * amount_ / decimalAdjustment;  // usdAmount has 18 decimals
        uint256 tokenPrice = phases[currentPhase][1];  // tokenPrice has 6 decimals
        uint256 decimalAdjustment = 10**6;  // Compensates the 6 decimals in tokenPrice
        return (usdAmount * decimalAdjustment) / tokenPrice;
    }

    function currentPhaseCheck(uint256 amount_) internal returns(uint256) {
        if (currentPhase >= 3) {
            return currentPhase;
        }
        if (isAmountLimitExceeded(amount_) || isTimeLimitExceeded()) {
            currentPhase++;
        }
        return currentPhase;
    }

    function isAmountLimitExceeded(uint256 amount_) internal returns(bool) {
        return totalSold + amount_ > phases[currentPhase][0];
    }

    function isTimeLimitExceeded() internal returns(bool) {
        return block.timestamp >= phases[currentPhase][2];
    }

}