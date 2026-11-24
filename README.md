# Presale

Multi-phase token presale. Buyers pay with USDT, USDC, or ETH. Each phase has its own token price and limits; phases advance automatically when their token or time limit is exceeded. Tokens are claimed once the presale window closes.

## Contract

`PresaleApp.sol`

| Function | Who | Description |
|---|---|---|
| `buyWithStable(token, amount)` | Buyer | Buys sale tokens with USDT or USDC. |
| `buyWithEther()` | Buyer | Buys sale tokens with ETH (price from Chainlink oracle). |
| `claim()` | Buyer | Claims purchased tokens after `endTime`. |
| `ban(user)` / `removeBan(user)` | Owner | Bans or unbans a buyer. |
| `emergencyTokenWithdraw(token, amount)` | Owner | Withdraws any ERC20 from the contract. |
| `emergencyEtherWithdraw()` | Owner | Withdraws all ETH from the contract. |

**Constructor parameters**

| Parameter | Description |
|---|---|
| `saleTokenAddress_` | Token being sold |
| `internalWallet_` | Receives all incoming funds |
| `usdtAddress_` / `usdcAddress_` | Accepted stablecoins |
| `dataFeedAddress_` | Chainlink ETH/USD price feed |
| `maxSupply_` | Total tokens for sale (18 dec) |
| `startTime_` / `endTime_` | Presale window (Unix timestamps) |
| `phases_` | Three phases: `[tokenLimit, priceUsdt6Dec, phaseEndTime]` |

## Phase system

```
phases[i][0]  cumulative token limit for phase i (18 dec)
phases[i][1]  token price in USDT with 6 decimals
phases[i][2]  Unix timestamp at which phase i expires
```

A phase advances when either limit is hit on the next purchase. If all three phases complete before `endTime`, further purchases revert with "All phases completed".

## Security notes

- `require(currentPhase < 3)` guards both buy functions before the phase array is accessed, preventing an out-of-bounds panic when all phases complete.
- `require(answer > 0)` guards the oracle response against zero or negative prices.
- CEI pattern followed: state is updated before external calls in both `buy*` functions and in `claim`.
- Uses `SafeERC20` for token transfers.

## Usage

```shell
forge build
forge test
forge coverage
```
