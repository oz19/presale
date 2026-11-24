// SPDX-License-Identifier: MIT

pragma solidity 0.8.34;

import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "src/interfaces/IAggregator.sol";

/**
 * @title PresaleApp
 * @notice Multi-phase token presale. Buyers pay with USDT, USDC, or ETH during a
 *         defined time window and claim their tokens once the presale ends.
 * @dev Phases advance automatically when their token-amount limit or time limit is
 *      exceeded. The ETH/USD price is sourced from a Chainlink-compatible aggregator.
 */
contract PresaleApp is Ownable {

    using SafeERC20 for IERC20;

    /// @notice Address of the token being sold in the presale.
    address public saleTokenAddress;

    /// @notice Destination for all incoming funds (stablecoins and ETH).
    address public internalWallet;

    /// @notice Address of the USDT stablecoin accepted as payment.
    address public usdtAddress;

    /// @notice Address of the USDC stablecoin accepted as payment.
    address public usdcAddress;

    /// @notice Address of the Chainlink-compatible ETH/USD price feed.
    address public dataFeedAddress;

    /// @notice Maximum number of sale tokens available (18 decimals).
    uint256 public maxSupply;

    /// @notice Total sale tokens sold so far (18 decimals).
    uint256 public totalSold;

    /// @notice Unix timestamp at which purchases become possible.
    uint256 public startTime;

    /// @notice Unix timestamp after which purchases are no longer possible and claims open.
    uint256 public endTime;

    /**
     * @notice Three phases, each defined by [tokenLimit, priceInUsdt6Dec, phaseEndTime].
     * @dev phases[i][0] = cumulative token limit for phase i (18 dec).
     *      phases[i][1] = token price in USDT with 6 decimals.
     *      phases[i][2] = Unix timestamp at which the phase expires.
     */
    uint256[][3] public phases;

    /// @notice Index of the active phase (0–2). Advances automatically.
    uint256 public currentPhase;

    /// @notice True if an address is banned from purchasing.
    mapping(address => bool) public isBanned;

    /// @notice True if a token is accepted as payment.
    mapping(address => bool) public allowedPayingTokens;

    /// @notice Unclaimed sale-token balance per buyer.
    mapping(address => uint256) public balances;

    /**
     * @notice Reverts if the caller is banned.
     */
    modifier banCheck() {
        require(!isBanned[msg.sender], "User is banned");
        _;
    }

    /**
     * @notice Emitted when a buyer purchases sale tokens.
     * @param buyer The address of the purchaser.
     * @param amount The number of sale tokens purchased (18 decimals).
     */
    event BuyToken(address buyer, uint256 amount);

    /**
     * @notice Deploys the presale and transfers maxSupply_ sale tokens into the contract.
     * @dev The deployer must approve this contract for maxSupply_ sale tokens before deployment.
     * @param saleTokenAddress_ Token sold in the presale.
     * @param internalWallet_ Destination for all incoming funds.
     * @param usdtAddress_ USDT token address.
     * @param usdcAddress_ USDC token address.
     * @param dataFeedAddress_ Chainlink-compatible ETH/USD price feed.
     * @param maxSupply_ Total sale tokens available (18 decimals).
     * @param startTime_ Unix timestamp at which purchases open.
     * @param endTime_ Unix timestamp at which purchases close and claims open.
     * @param phases_ Three phases, each [tokenLimit, priceUsdt6Dec, phaseEndTime].
     */
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

    /**
     * @notice Bans an address from purchasing.
     * @param user_ Address to ban.
     */
    function ban(address user_) onlyOwner external {
        isBanned[user_] = true;
    }

    /**
     * @notice Removes a ban from an address.
     * @param user_ Address to unban.
     */
    function removeBan(address user_) onlyOwner external {
        delete isBanned[user_];
    }

    /**
     * @notice Buys sale tokens using a stablecoin (USDT or USDC).
     * @dev The token amount is calculated from amount_ and the current phase price.
     *      Caller must approve this contract for amount_ of tokenUsedToBuy_.
     * @param tokenUsedToBuy_ Stablecoin used for payment (must be USDT or USDC).
     * @param amount_ Amount of stablecoin to spend.
     */
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

    /**
     * @notice Buys sale tokens using ETH. The ETH/USD conversion uses the price feed.
     * @dev msg.value is forwarded to internalWallet.
     */
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

    /**
     * @notice Claims all purchased sale tokens after the presale ends.
     * @dev Clears the caller's balance before transferring to prevent re-entrancy.
     */
    function claim() external {
        require(block.timestamp > endTime, "Still in Presale period");

        uint256 amount = balances[msg.sender];
        delete balances[msg.sender];

        IERC20(saleTokenAddress).safeTransfer(msg.sender, amount);
    }

    /**
     * @notice Withdraws any ERC20 token from the contract. Emergency use only.
     * @param token_ Token address to withdraw.
     * @param amount_ Amount to withdraw.
     */
    function emergencyTokenWithdraw(address token_, uint256 amount_) onlyOwner external {
        IERC20(token_).safeTransfer(msg.sender, amount_);
    }

    /**
     * @notice Withdraws all ETH from the contract. Emergency use only.
     */
    function emergencyEtherWithdraw() onlyOwner external {
        uint256 balance = address(this).balance;
        (bool success,) = msg.sender.call{value: balance}("");
        require(success, "Transfer failed");
    }


    // Internal functions

    /**
     * @notice Calculates how many sale tokens (18 dec) the buyer receives for amount_ stablecoins.
     * @param tokenUsedToBuy_ Stablecoin address (used to fetch its decimal count).
     * @param amount_ Amount of stablecoin with its native decimals.
     * @return Token amount with 18 decimals.
     */
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

    /**
     * @notice Calculates how many sale tokens (18 dec) the buyer receives for amount_ wei.
     * @param etherPriceInUsd_ ETH/USD price with 18 decimals.
     * @param amount_ ETH amount in wei (18 decimals).
     * @return Token amount with 18 decimals.
     */
    function calculateTokenAmountToReceiveFromEther(uint256 etherPriceInUsd_, uint256 amount_) internal view returns(uint256) {
        uint256 decimalAdjustment = 10**18;
        uint256 usdAmount = etherPriceInUsd_ * amount_ / decimalAdjustment;
        uint256 tokenPrice = phases[currentPhase][1];
        decimalAdjustment = 10**6;
        return (usdAmount * decimalAdjustment) / tokenPrice;
    }

    /**
     * @notice Advances currentPhase by 1 if the amount or time limit of the current phase is exceeded.
     * @param amount_ Token amount about to be purchased (used to check the amount limit).
     * @return The (possibly updated) currentPhase index.
     */
    function currentPhaseCheck(uint256 amount_) internal returns(uint256) {
        if (isAmountLimitExceeded(amount_) || isTimeLimitExceeded()) {
            currentPhase++;
        }
        return currentPhase;
    }

    /**
     * @notice Returns true if adding amount_ tokens would exceed the current phase token limit.
     * @param amount_ Token amount about to be purchased.
     */
    function isAmountLimitExceeded(uint256 amount_) internal view returns(bool) {
        return totalSold + amount_ > phases[currentPhase][0];
    }

    /**
     * @notice Returns true if the current phase's time limit has been reached.
     */
    function isTimeLimitExceeded() internal view returns(bool) {
        return block.timestamp >= phases[currentPhase][2];
    }

    /**
     * @notice Fetches the ETH/USD price from the aggregator and converts it to 18 decimals.
     * @return ETH/USD price with 18 decimals.
     */
    function getEthUsdPriceWith18Decimals() internal view returns(uint256) {
        (, int256 answer,,,) = IAggregator(dataFeedAddress).latestRoundData();
        require(answer > 0, "Invalid oracle price");
        uint256 price = uint256(answer * (10**10));
        return price;
    }

}
