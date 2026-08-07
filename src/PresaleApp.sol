// SPDX-License-Identifier: MIT

pragma solidity 0.8.34;

import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";


contract PresaleApp is Ownable {

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
        uint256[][3] phases_
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

    function buyWithStable() banCheck() {
        // TODO
    }

}