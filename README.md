# KipuBankV3 - Uniswap V2 Auto-Swapping Vault

This repository contains the final version of `KipuBankV3`, a significant evolution of `KipuBankV2`.
 This contract transforms the vault from a multi-token storage system into a DeFi application that **integrates the Uniswap V2 router to automatically convert all deposits into USDC.**

All user balances are stored and managed exclusively in USDC, which simplifies accounting and resolves the volatility issues from the previous version.

## Core Features

* **Uniswap V2 Integration:** Uses `IUniswapV2Router02` to execute swaps.
* **USDC-Only Accounting:** All deposits (ETH or other ERC20s) are automatically converted to USDC. User balances are stored solely in USDC.
* **Universal Deposits:**
    * **Native ETH:** Accepted via `receive()` and swapped for USDC.
    * **USDC:** Accepted directly with no swap.
    * **Any ERC20:** Accepts any token with liquidity on Uniswap V2, swaps it for USDC (assuming a `Token -> WETH -> USDC` path), and credits the balance.
* **Functional Bank Cap:** By storing only USDC, the `bankCap` is once again a safe and functional feature, as the stored asset is stable.
* **Withdrawal Limit:** Maintains a per-transaction withdrawal limit (`i_maxWithdraw`), also in USDC.
* **Slippage Protection:** The constructor requires an `i_slippageBps` (basis points) to protect the user from excessive volatility during the swap.
* **Security and Control:** Maintains the robust features from V2:
    * `AccessControl` for an `ADMIN_ROLE`.
    * `Pausable` to halt deposits and withdrawals in emergencies.
    * `ReentrancyGuard` on all critical functions.
    * `SafeERC20` for token transfers.

## Architectural Decisions & Improvements (The "Why")

The transition to `KipuBankV3` is based on solving a fundamental design flaw in `KipuBankV2`.

### The V2 Problem: The Volatility Flaw

In `KipuBankV2`, we attempted to maintain a bank cap (`i_bankCapUSD`) while storing volatile assets (like ETH). This had a critical flaw:

1.  **Historical Value vs. Real Value:** If a user deposited 1 ETH (worth $2,000), our `s_totalValueUSD` would increase by 2,000.
2.  **The Flaw:** If the price of ETH rose to $3,000 and the user withdrew their 1 ETH, the `_getUsdValue` function would calculate the *current* value ($3,000) and subtract it from the total.
3.  **The Result:** `s_totalValueUSD` would end up with a negative value or, worse, suffer an *underflow*, breaking the contract's accounting.

### The V3 Solution: The "Swap-to-Stable" Pattern

`KipuBankV3` solves this by radically changing the logic: **Do not store volatile assets.**

1.  **Everything to USDC:** All deposits (ETH, LINK, WETH, etc.) are immediately converted to USDC at the time of deposit. The user's balance is credited with the amount of USDC received from the swap.
2.  **Simple & Safe Accounting:** The contract only holds one asset: USDC. This makes accounting trivial. The bank's balance is simply `IERC20(i_USDC).balanceOf(address(this))`.
3.  **The `bankCap` Works Again:** Since the stored asset is stable, the `i_bankCap` now works perfectly. We can safely limit the total amount of USDC the bank can hold.
4.  **Simplified Logic:** All the complexity from V2 is removed:
    * No more `s_priceFeeds`.
    * No more `s_tokenDecimals` or `s_priceFeedDecimals`.
    * No more `checkNoFrozenAssets` (there are no "supported" tokens anymore).
    * The Admin's only responsibility is to `pause`/`unpause`.

### Trade-Offs

* **Gas Cost for User:** Deposits are more expensive. The user depositing ETH or an ERC20 token now pays the gas cost for the Uniswap swap in addition to the deposit.
* **Token Approval:** For every ERC20 token swap, the contract must approve the Uniswap Router. The current implementation uses `safeApprove(0)` then `safeApprove(amount)` to handle tokens like USDT, which adds a slight gas overhead.
* **Fixed Swap Path:** The contract assumes a `Token -> WETH -> USDC` swap path. This works for the vast majority of tokens but could fail for exotic tokens that only have direct liquidity with USDC and not WETH.

## How to Deploy and Interact

### Deployment

To deploy `KipuBankV3`, you will need the Uniswap V2 Router and USDC addresses for your target network (e.g., Sepolia).

* **Uniswap V2 Router (Sepolia):** `0xC532a74256D3Db42D0Bf7a0400f40cb3629bEa45`
* **USDC (Sepolia):** `0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4c8` (There are several; this is a common one).

Your deployment script must pass 6 arguments to the constructor:

1.  `_bankCap`: Max USDC capacity (e.g., `1000000 * 10**6` for 1,000,000 USDC).
2.  `_maxWithdraw`: Per-tx withdrawal limit (e.g., `1000 * 10**6` for 1,000 USDC).
3.  `_slippageBps`: Slippage basis points (e.g., `50` for 0.5%).
4.  `_admin`: Your wallet address (you will be the admin).
5.  `_USDC`: The USDC address on Sepolia.
6.  `_uniswapRouter`: The V2 Router address on Sepolia.

### Interaction Flow

#### As a User

**To Deposit ETH:**
Simply send ETH (e.g., 0.1 ETH) directly to the `KipuBankV3` contract address. The `receive()` function will handle it, swap it for USDC, and credit your balance.

**To Deposit USDC (the base token):**
1.  **Approve:** Call `approve()` on the USDC token contract, approving `KipuBankV3` to spend your USDC.
    ```javascript
    // On the USDC Contract
    usdc.approve(KIPUBANK_ADDRESS, 500 * 10**6); // Approve 500 USDC
    ```
2.  **Deposit:** Call `depositToken()` on `KipuBankV3`.
    ```javascript
    // On KipuBankV3
    kipuBank.depositToken(USDC_ADDRESS, 500 * 10**6);
    ```

**To Deposit another ERC20 (e.g., LINK):**
1.  **Approve:** Call `approve()` on the LINK token contract.
    ```javascript
    // On the LINK Contract
    link.approve(KIPUBANK_ADDRESS, 10 * 10**18); // Approve 10 LINK
    ```
2.  **Deposit:** Call `depositToken()` on `KipuBankV3`.
    ```javascript
    // On KipuBankV3
    kipuBank.depositToken(LINK_ADDRESS, 10 * 10**18);
    ```
    *The contract will receive the 10 LINK, swap them for USDC, and credit your balance with the resulting USDC.*

**To Check Balance:**
Call the `getUserBalance()` function.
```javascript
// On KipuBankV3
kipuBank.getUserBalance(); // Returns your balance in USDC (with 6 decimals)