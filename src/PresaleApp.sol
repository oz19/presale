// SPDX-License-Identifier: MIT

pragma solidity 0.8.34;

import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "src/interfaces/IAggregator.sol";


contract PresaleApp is Ownable {

    using SafeERC20 for IERC20;

    address public saleTokenAddress;
    address public internalWallet;
    address public usdtAddress;
    address public usdcAddress;
    address public dataFeedAddress;
    uint256 public maxSupply;
    uint256 public totalSold;
    uint256 public startTime;
    uint256 public endTime;
    uint256[][3] public phases;
    uint256 public currentPhase;
    mapping(address => bool) public isBanned;
    mapping(address => bool) public allowedPayingTokens;
    mapping(address => uint256) public balances;

    modifier banCheck() {
        require(!isBanned[msg.sender], "User is banned");
        _;
    }

    event BuyToken(address buyer, uint256 amount);

    constructor (
        address saleTokenAddress_,
        address internalWallet_,
        address usdtAddress_,
        address usdcAddress_,
        address dataFeedAddress_,
        uint256 maxSupply_,
        uint256 startTime_,
        uint256 endTime_,
        uint256[][3] memory phases_
    ) Ownable(msg.sender) {
        saleTokenAddress = saleTokenAddress_;
        internalWallet = internalWallet_;
        usdtAddress = usdtAddress_;
        usdcAddress = usdcAddress_;
        maxSupply = maxSupply_;
        startTime = startTime_;
        endTime = endTime_;
        phases = phases_;
        dataFeedAddress = dataFeedAddress_;

        require(endTime > startTime, "Start time should be before End time");

        allowedPayingTokens[usdtAddress] = true;
        allowedPayingTokens[usdcAddress] = true;

        IERC20(saleTokenAddress).safeTransferFrom(msg.sender, address(this), maxSupply);
    }

    function ban(address user_) onlyOwner external {
        isBanned[user_] = true;
    }

    function removeBan(address user_) onlyOwner external {
        delete isBanned[user_];
    }

    function buyWithStable(address tokenUsedToBuy_, uint256 amount_) external banCheck {
        require(block.timestamp >= startTime && block.timestamp <= endTime, "Out of presale period");
        require(allowedPayingTokens[tokenUsedToBuy_], "Paying token not allowed");
        require(currentPhase < 3, "All phases completed");

        uint256 tokenAmountToReceive = calculateTokenAmountToReceive(tokenUsedToBuy_, amount_);
        currentPhaseCheck(tokenAmountToReceive);

        totalSold += tokenAmountToReceive;
        require(totalSold <= maxSupply, "Max supply exceeded");

        balances[msg.sender] += tokenAmountToReceive;

        IERC20(tokenUsedToBuy_).safeTransferFrom(msg.sender, internalWallet, amount_);

        emit BuyToken(msg.sender, tokenAmountToReceive);
    }

    function buyWithEther() external payable banCheck {
        require(block.timestamp >= startTime && block.timestamp <= endTime, "Out of presale period");
        require(currentPhase < 3, "All phases completed");

        uint256 ethUsdPrice = getEthUsdPriceWith18Decimals();
        uint256 tokenAmountToReceive = calculateTokenAmountToReceiveFromEther(
            ethUsdPrice,
            msg.value
        );
        currentPhaseCheck(tokenAmountToReceive);

        totalSold += tokenAmountToReceive;
        require(totalSold <= maxSupply, "Max supply exceeded");

        balances[msg.sender] += tokenAmountToReceive;

        (bool success,) = internalWallet.call{value: msg.value}("");
        require(success, "Transfer failed");

        emit BuyToken(msg.sender, tokenAmountToReceive);
    }

    function getEthUsdPriceWith18Decimals() internal view returns(uint256) {
        (, int256 answer,,,) = IAggregator(dataFeedAddress).latestRoundData();
        require(answer > 0, "Invalid oracle price");
        uint256 price = uint256(answer * (10**10));
        return price;
    }

    function claim() external {
        require(block.timestamp > endTime, "Still in Presale period");

        uint256 amount = balances[msg.sender];
        delete balances[msg.sender];

        IERC20(saleTokenAddress).safeTransfer(msg.sender, amount);
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

    function calculateTokenAmountToReceive(
        address tokenUsedToBuy_,
        uint256 amount_
    ) internal view returns(uint256) {
        uint256 price = phases[currentPhase][1];
        uint256 resultDecimals = 18;
        uint256 priceDecimals = 6;
        uint256 amountDecimals = IERC20Metadata(tokenUsedToBuy_).decimals();
        uint256 adjustmentDecimals = resultDecimals + priceDecimals - amountDecimals;
        return (amount_ * 10**adjustmentDecimals) / price;
    }

    function calculateTokenAmountToReceiveFromEther(uint256 etherPriceInUsd_, uint256 amount_) internal view returns(uint256) {
        uint256 decimalAdjustment = 10**18;
        uint256 usdAmount = etherPriceInUsd_ * amount_ / decimalAdjustment;
        uint256 tokenPrice = phases[currentPhase][1];
        decimalAdjustment = 10**6;
        return (usdAmount * decimalAdjustment) / tokenPrice;
    }

    function currentPhaseCheck(uint256 amount_) internal returns(uint256) {
        if (isAmountLimitExceeded(amount_) || isTimeLimitExceeded()) {
            currentPhase++;
        }
        return currentPhase;
    }

    function isAmountLimitExceeded(uint256 amount_) internal view returns(bool) {
        return totalSold + amount_ > phases[currentPhase][0];
    }

    function isTimeLimitExceeded() internal view returns(bool) {
        return block.timestamp >= phases[currentPhase][2];
    }

}
