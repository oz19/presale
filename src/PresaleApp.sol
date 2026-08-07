// SPDX-License-Identifier: MIT

pragma solidity 0.8.34;

import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";


contract PresaleApp is Ownable {

    using SafeERC20 for IERC20;

    address public internalWallet;  // Funds will be stored here
    address public usdtAddress;
    address public usdcAddress;
    uint256 public maxSupply;
    uint256[][3] public phases;
    mapping(address => bool) public isBanned;

    modifier BanCheck() {
        require(!isBanned[msg.sender], "User is banned");
        _;
    }

    constructor (
        address internalWallet_,
        address usdtAddress_,
        address usdcAddress_,
        uint256 maxSupply_,
        uint256[][3] memory phases_
    ) Ownable(msg.sender) {
        internalWallet = internalWallet_;
        usdtAddress = usdtAddress_;
        usdcAddress = usdcAddress_;
        maxSupply = maxSupply_;
        phases = phases_;
    }

    function ban(address user_) onlyOwner external {
        isBanned[user_] = true;
    }

    function removeBan(address user_) onlyOwner external {
        delete isBanned[user_];
    }

    // function buyWithStable() banCheck external {
    //     // TODO
    // }

    function emergencyTokenWithdraw(address token_, uint256 amount_) onlyOwner external {
        IERC20(token_).safeTransfer(msg.sender, amount_);
    }

    function emergencyEtherWithdraw() onlyOwner external {
        uint256 balance = address(this).balance;
        (bool success,) = msg.sender.call{value: balance}("");
        require(success, "Transfer failed");
    }

}