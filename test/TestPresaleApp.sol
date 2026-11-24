// SPDX-License-Identifier: MIT

pragma solidity 0.8.34;

import "lib/forge-std/src/Test.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "src/PresaleApp.sol";
import "src/interfaces/IAggregator.sol";

// ─── Mocks ───────────────────────────────────────────────────────────────────

contract MockERC20 is ERC20 {
    uint8 private _dec;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _dec = decimals_;
    }

    function decimals() public view override returns (uint8) { return _dec; }

    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockAggregator is IAggregator {
    int256 private _price;

    constructor(int256 price_) { _price = price_; }

    function setPrice(int256 price_) external { _price = price_; }

    function latestRoundData() external view override returns (
        uint80, int256, uint256, uint256, uint80
    ) {
        return (0, _price, 0, block.timestamp, 0);
    }
}

/// @dev Rejects ETH — used to test transfer-failure branches.
contract NoReceive {}

/// @dev Calls emergencyEtherWithdraw as owner while rejecting ETH back.
contract OwnerRejecter {
    function callEmergencyEtherWithdraw(PresaleApp presale_) external {
        presale_.emergencyEtherWithdraw();
    }
    // No receive() — this contract rejects ETH
}

// ─── Tests ───────────────────────────────────────────────────────────────────

contract TestPresaleApp is Test {

    PresaleApp presale;

    MockERC20 saleToken;
    MockERC20 usdt;
    MockERC20 usdc;
    MockAggregator aggregator;

    address internal wallet = address(100);
    address user = vm.addr(1);
    address bannedUser = vm.addr(2);

    uint256 constant ETH_PRICE_8DEC = 2000e8;   // $2000 per ETH (Chainlink 8 dec)
    uint256 constant TOKEN_PRICE    = 100_000;   // 0.1 USDT per token (6 dec)
    uint256 constant MAX_SUPPLY     = 1_000_000 ether; // 1M tokens

    uint256 startTime;
    uint256 endTime;

    function _buildPhases() internal view returns (uint256[][3] memory p) {
        // Phase 0: limit 300k tokens, price 0.1 USDT, end in 10 days
        p[0] = new uint256[](3);
        p[0][0] = 300_000 ether;
        p[0][1] = TOKEN_PRICE;
        p[0][2] = startTime + 10 days;

        // Phase 1: limit 600k tokens, price 0.2 USDT, end in 20 days
        p[1] = new uint256[](3);
        p[1][0] = 600_000 ether;
        p[1][1] = 200_000;
        p[1][2] = startTime + 20 days;

        // Phase 2: limit 1M tokens, price 0.3 USDT, end in 30 days
        p[2] = new uint256[](3);
        p[2][0] = MAX_SUPPLY;
        p[2][1] = 300_000;
        p[2][2] = startTime + 30 days;
    }

    function _deployPresale(
        uint256 maxSupply_,
        address wallet_,
        uint256[][3] memory phases_
    ) internal returns (PresaleApp) {
        saleToken.mint(address(this), maxSupply_);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        saleToken.approve(predicted, maxSupply_);
        return new PresaleApp(
            address(saleToken),
            wallet_,
            address(usdt),
            address(usdc),
            address(aggregator),
            maxSupply_,
            startTime,
            endTime,
            phases_
        );
    }

    function setUp() public {
        startTime = block.timestamp + 1 hours;
        endTime   = block.timestamp + 1000 days;

        saleToken  = new MockERC20("SaleToken", "STK", 18);
        usdt       = new MockERC20("USDT", "USDT", 6);
        usdc       = new MockERC20("USDC", "USDC", 6);
        aggregator = new MockAggregator(int256(ETH_PRICE_8DEC));

        presale = _deployPresale(MAX_SUPPLY, wallet, _buildPhases());

        usdt.mint(user, 1_000_000 * 1e6);  // 1M USDT
        usdc.mint(user, 1_000_000 * 1e6);
        vm.deal(user, 1000 ether);

        presale.ban(bannedUser);
    }

    // ── Initialization ────────────────────────────────────────────────────────

    function testConstructorReverts_InvalidTimeRange() public {
        saleToken.mint(address(this), MAX_SUPPLY);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        saleToken.approve(predicted, MAX_SUPPLY);
        vm.expectRevert("Start time should be before End time");
        new PresaleApp(
            address(saleToken), wallet, address(usdt), address(usdc),
            address(aggregator), MAX_SUPPLY,
            block.timestamp + 10 days,  // startTime
            block.timestamp + 1 days,   // endTime < startTime
            _buildPhases()
        );
    }

    function testIsCorrectlyInitialized() public view {
        assertEq(presale.saleTokenAddress(), address(saleToken));
        assertEq(presale.internalWallet(), wallet);
        assertEq(presale.usdtAddress(), address(usdt));
        assertEq(presale.usdcAddress(), address(usdc));
        assertEq(presale.maxSupply(), MAX_SUPPLY);
        assertEq(presale.startTime(), startTime);
        assertEq(presale.endTime(), endTime);
        assertEq(presale.currentPhase(), 0);
        assertEq(presale.totalSold(), 0);
        assertEq(saleToken.balanceOf(address(presale)), MAX_SUPPLY);
        assertTrue(presale.allowedPayingTokens(address(usdt)));
        assertTrue(presale.allowedPayingTokens(address(usdc)));
    }

    // ── Ban / unban ───────────────────────────────────────────────────────────

    function testBanAndRemoveBan() public {
        address target = vm.addr(99);
        presale.ban(target);
        assertTrue(presale.isBanned(target));
        presale.removeBan(target);
        assertFalse(presale.isBanned(target));
    }

    // ── buyWithStable ─────────────────────────────────────────────────────────

    function testBuyWithStableReverts_OutOfPresalePeriod() public {
        // Before start
        vm.startPrank(user);
        usdt.approve(address(presale), type(uint256).max);
        vm.expectRevert("Out of presale period");
        presale.buyWithStable(address(usdt), 1e6);
        vm.stopPrank();
    }

    function testBuyWithStableReverts_BannedUser() public {
        vm.warp(startTime);
        vm.startPrank(bannedUser);
        vm.expectRevert("User is banned");
        presale.buyWithStable(address(usdt), 1e6);
        vm.stopPrank();
    }

    function testBuyWithStableReverts_TokenNotAllowed() public {
        vm.warp(startTime);
        MockERC20 randomToken = new MockERC20("Random", "RND", 6);
        vm.startPrank(user);
        randomToken.mint(user, 100e6);
        randomToken.approve(address(presale), type(uint256).max);
        vm.expectRevert("Paying token not allowed");
        presale.buyWithStable(address(randomToken), 1e6);
        vm.stopPrank();
    }

    function testBuyWithStableReverts_AllPhasesCompleted() public {
        // Warp past all phase time limits (still within presale endTime)
        vm.warp(startTime + 31 days);

        vm.startPrank(user);
        usdt.approve(address(presale), type(uint256).max);
        // Three buys advance currentPhase from 0 → 1 → 2 → 3
        presale.buyWithStable(address(usdt), 1e6);
        presale.buyWithStable(address(usdt), 1e6);
        presale.buyWithStable(address(usdt), 1e6);

        vm.expectRevert("All phases completed");
        presale.buyWithStable(address(usdt), 1e6);
        vm.stopPrank();
    }

    function testBuyWithStableReverts_MaxSupplyExceeded() public {
        // Deploy a presale with tiny maxSupply = 1 token
        uint256 tiny = 1 ether;
        MockERC20 tinyToken = new MockERC20("Tiny", "TNY", 18);
        tinyToken.mint(address(this), tiny);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        tinyToken.approve(predicted, tiny);
        uint256[][3] memory phases = _buildPhases();
        PresaleApp tinyPresale = new PresaleApp(
            address(tinyToken), wallet, address(usdt), address(usdc),
            address(aggregator), tiny, startTime, endTime, phases
        );

        vm.warp(startTime);
        usdt.mint(address(this), 1000e6);
        usdt.approve(address(tinyPresale), type(uint256).max);

        // 100 USDT = 1000 tokens → exceeds maxSupply of 1 token
        vm.expectRevert("Max supply exceeded");
        tinyPresale.buyWithStable(address(usdt), 100e6);
    }

    function testBuyWithStableCorrectly() public {
        vm.warp(startTime);
        uint256 usdtAmount = 10e6; // 10 USDT → 100 tokens at 0.1 USDT/token

        vm.startPrank(user);
        usdt.approve(address(presale), usdtAmount);

        uint256 walletBefore = usdt.balanceOf(wallet);

        vm.expectEmit(true, false, false, true);
        emit PresaleApp.BuyToken(user, 100 ether);
        presale.buyWithStable(address(usdt), usdtAmount);

        assertEq(presale.balances(user), 100 ether);
        assertEq(presale.totalSold(), 100 ether);
        assertEq(usdt.balanceOf(wallet), walletBefore + usdtAmount);
        vm.stopPrank();
    }

    function testBuyWithStableWorksWithUsdc() public {
        vm.warp(startTime);
        usdc.mint(user, 10e6);

        vm.startPrank(user);
        usdc.approve(address(presale), 10e6);
        presale.buyWithStable(address(usdc), 10e6);
        assertEq(presale.balances(user), 100 ether);
        vm.stopPrank();
    }

    // ── buyWithEther ──────────────────────────────────────────────────────────

    function testBuyWithEtherReverts_MaxSupplyExceeded() public {
        // Deploy presale with tiny maxSupply = 1 token; 1 ETH = 20,000 tokens → exceeds it
        uint256 tiny = 1 ether;
        MockERC20 tinyToken = new MockERC20("Tiny", "TNY", 18);
        tinyToken.mint(address(this), tiny);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        tinyToken.approve(predicted, tiny);
        PresaleApp tinyPresale = new PresaleApp(
            address(tinyToken), wallet, address(usdt), address(usdc),
            address(aggregator), tiny, startTime, endTime, _buildPhases()
        );

        vm.warp(startTime);
        vm.expectRevert("Max supply exceeded");
        vm.prank(user);
        tinyPresale.buyWithEther{value: 1 ether}();
    }

    function testBuyWithEtherReverts_OutOfPresalePeriod() public {
        vm.expectRevert("Out of presale period");
        vm.prank(user);
        presale.buyWithEther{value: 1 ether}();
    }

    function testBuyWithEtherReverts_BannedUser() public {
        vm.warp(startTime);
        vm.deal(bannedUser, 1 ether);
        vm.prank(bannedUser);
        vm.expectRevert("User is banned");
        presale.buyWithEther{value: 1 ether}();
    }

    function testBuyWithEtherReverts_AllPhasesCompleted() public {
        vm.warp(startTime + 31 days);

        vm.startPrank(user);
        // Three buys to exhaust all phases by time
        presale.buyWithEther{value: 0.001 ether}();
        presale.buyWithEther{value: 0.001 ether}();
        presale.buyWithEther{value: 0.001 ether}();

        vm.expectRevert("All phases completed");
        presale.buyWithEther{value: 0.001 ether}();
        vm.stopPrank();
    }

    function testBuyWithEtherReverts_InvalidOraclePrice() public {
        vm.warp(startTime);
        aggregator.setPrice(0);
        vm.expectRevert("Invalid oracle price");
        vm.prank(user);
        presale.buyWithEther{value: 1 ether}();
    }

    function testBuyWithEtherReverts_TransferFailed() public {
        // Deploy NoReceive first so its nonce is consumed before we predict the PresaleApp address
        address noReceive = address(new NoReceive());
        saleToken.mint(address(this), MAX_SUPPLY);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        saleToken.approve(predicted, MAX_SUPPLY);
        PresaleApp badPresale = new PresaleApp(
            address(saleToken), noReceive, address(usdt), address(usdc),
            address(aggregator), MAX_SUPPLY, startTime, endTime, _buildPhases()
        );

        vm.warp(startTime);
        vm.expectRevert("Transfer failed");
        vm.prank(user);
        badPresale.buyWithEther{value: 1 ether}();
    }

    function testBuyWithEtherCorrectly() public {
        vm.warp(startTime);
        // 1 ETH at $2000, token price 0.1 USDT → 20,000 tokens
        uint256 expectedTokens = 20_000 ether;

        uint256 walletBefore = wallet.balance;

        vm.expectEmit(true, false, false, true);
        emit PresaleApp.BuyToken(user, expectedTokens);
        vm.prank(user);
        presale.buyWithEther{value: 1 ether}();

        assertEq(presale.balances(user), expectedTokens);
        assertEq(presale.totalSold(), expectedTokens);
        assertEq(wallet.balance, walletBefore + 1 ether);
    }

    // ── Claim ─────────────────────────────────────────────────────────────────

    function testClaimReverts_StillInPresalePeriod() public {
        vm.warp(startTime);
        vm.startPrank(user);
        usdt.approve(address(presale), 10e6);
        presale.buyWithStable(address(usdt), 10e6);

        vm.expectRevert("Still in Presale period");
        presale.claim();
        vm.stopPrank();
    }

    function testClaimCorrectly() public {
        vm.warp(startTime);
        vm.startPrank(user);
        usdt.approve(address(presale), 10e6);
        presale.buyWithStable(address(usdt), 10e6);
        vm.stopPrank();

        vm.warp(endTime + 1);

        uint256 tokensBefore = saleToken.balanceOf(user);
        vm.prank(user);
        presale.claim();

        assertEq(saleToken.balanceOf(user), tokensBefore + 100 ether);
        assertEq(presale.balances(user), 0);
    }

    // ── Phase advancement ─────────────────────────────────────────────────────

    function testPhaseAdvancesOnAmountLimit() public {
        vm.warp(startTime);
        // Phase 0 limit is 300k tokens. At price 0.1 USDT, buying 300,001 tokens in total
        // triggers advancement. First buy: exactly 300k tokens = 30,000 USDT.
        // Second buy: 1 extra token → isAmountLimitExceeded → phase advances to 1.
        vm.startPrank(user);
        usdt.approve(address(presale), type(uint256).max);

        presale.buyWithStable(address(usdt), 30_000e6); // 300k tokens → still phase 0
        assertEq(presale.currentPhase(), 0);

        presale.buyWithStable(address(usdt), 1e6); // 10 more → exceeds phase 0 limit
        assertEq(presale.currentPhase(), 1);
        vm.stopPrank();
    }

    function testPhaseAdvancesOnTimeLimit() public {
        vm.warp(startTime + 10 days + 1); // past phase 0 endTime
        vm.startPrank(user);
        usdt.approve(address(presale), type(uint256).max);

        presale.buyWithStable(address(usdt), 1e6); // triggers phase 0 → 1 on first buy
        assertEq(presale.currentPhase(), 1);
        vm.stopPrank();
    }

    // ── Emergency withdrawals ─────────────────────────────────────────────────

    function testEmergencyTokenWithdraw() public {
        uint256 ownerBefore = saleToken.balanceOf(address(this));
        presale.emergencyTokenWithdraw(address(saleToken), 1 ether);
        assertEq(saleToken.balanceOf(address(this)), ownerBefore + 1 ether);
    }

    function testEmergencyEtherWithdraw() public {
        vm.deal(address(presale), 2 ether);
        uint256 ownerBefore = address(this).balance;
        presale.emergencyEtherWithdraw();
        assertEq(address(this).balance, ownerBefore + 2 ether);
    }

    function testEmergencyEtherWithdrawReverts_TransferFailed() public {
        OwnerRejecter rejecter = new OwnerRejecter();
        presale.transferOwnership(address(rejecter));
        vm.deal(address(presale), 1 ether);

        vm.expectRevert("Transfer failed");
        rejecter.callEmergencyEtherWithdraw(presale);
    }

    // Allow test contract to receive ETH
    receive() external payable {}

}
