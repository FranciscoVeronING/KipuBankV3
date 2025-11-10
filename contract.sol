// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*//////////////////////////////////////////////////////////////////////////
//                                  IMPORTS
////////////////////////////////////////////////////////////////////////*/

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title KipuBankV3
 * @author Francisco Veron 
 * @notice A multi-asset (ETH & ERC20) digital vault that auto-swaps deposits to USDC.
 * @dev This contract uses:
 * - AccessControl: For a flexible ADMIN_ROLE.
 * - Pausable: To halt deposits/withdrawals in an emergency.
 * - ReentrancyGuard: To protect state-changing functions.
 * - Uniswap V2 Router: To swap all incoming assets to USDC.
 * - SafeERC20: For robust token transfers.
 * @dev All user balances are stored and managed in USDC.
 */
contract KipuBankV3 is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////////////////
    //                                  CONSTANTS
    ////////////////////////////////////////////////////////////////////////*/

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    // We still use address(0) to represent native ETH in event logs
    address public constant NATIVE_ETH = address(0);
    uint8 public constant USD_DECIMALS = 6; // Decimals for USDC

    /*//////////////////////////////////////////////////////////////////////////
    //                              STATE VARIABLES
    ////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice The maximum value (in USD, 6 decimals) allowed per single withdrawal.
     */
    uint256 public immutable i_maxWithdraw;

    /**
     * @notice The maximum total value (in USDC) the bank can hold.
     */
    uint256 public immutable i_bankCap;

    /**
     * @notice Slippage tolerance in basis points (e.g., 50 = 0.5%).
     */
    uint256 public immutable i_slippageBps;

    // --- User Balances (NOW ONLY IN USDC) ---
    /**
     * @notice Mapping of user balances, stored *only* in USDC.
     * @dev s_balances[user_address] = usdc_amount
     */
    mapping(address => uint256) private s_balances;

    uint256 public s_depositCount;
    uint256 public s_withdrawCount;

    // --- Protocol Addresses ---
    address public immutable i_USDC;
    address public immutable i_WETH;
    IUniswapV2Router02 public immutable i_uniswapRouter;

    /*//////////////////////////////////////////////////////////////////////////
    //                                  EVENTS
    ////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when a user deposits any token, which is then converted to USDC.
     * @param user The user's address.
     * @param token The original token address deposited (address(0) for ETH).
     * @param amountToken The amount of the original token.
     * @param amountUSDC The amount of USDC credited to the user's balance.
     */
    event Deposit(
        address indexed user,
        address indexed token,
        uint256 amountToken,
        uint256 amountUSDC
    );

    /**
     * @notice Emitted when a user withdraws USDC.
     * @param user The user's address.
     * @param token The token withdrawn (always USDC).
     * @param amount The amount of USDC withdrawn.
     */
    event Withdraw(
        address indexed user,
        address indexed token,
        uint256 amount
    );

    /*//////////////////////////////////////////////////////////////////////////
    //                                  ERRORS
    ////////////////////////////////////////////////////////////////////////*/

    error WithdrawExceedsLimit(uint256 requested, uint256 max);
    error DepositExceedsBankCap(uint256 current, uint256 deposit, uint256 cap);
    error TransferFailed();
    error InsufficientBalance(uint256 requested, uint256 available);
    error InvalidAmount();
    error InvalidAddress();
    error InvalidBankCap();
    error InvalidSlippageBps();
    error InvalidSwapFailed();
    error InvalidUnsupportedToken(); // Thrown if a swap path doesn't exist

    /*//////////////////////////////////////////////////////////////////////////
    //                                 MODIFIERS
    ////////////////////////////////////////////////////////////////////////*/

    modifier nonZeroAddress(address _addr) {
        if (_addr == address(0)) revert InvalidAddress();
        _;
    }

    modifier isAmountPositive(uint256 _amount) {
        if (_amount == 0) revert InvalidAmount();
        _;
    }

    /**
     * @dev Reverts if the `msg.sender` does not have enough USDC balance.
     */
    modifier checkSufficientBalance(uint256 _amount) {
        uint256 balance = s_balances[msg.sender];
        if (balance < _amount) {
            revert InsufficientBalance(_amount, balance);
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////////////////
    //                               CONSTRUCTOR
    ////////////////////////////////////////////////////////////////////////*/

    /**
     * @param _bankCap The total USDC capacity of the bank.
     * @param _maxWithdraw Max USDC value for a single withdrawal.
     * @param _slippageBps Slippage tolerance (e.g., 50 for 0.5%).
     * @param _admin The address to be granted ADMIN_ROLE.
     * @param _USDC The address of the USDC token.
     * @param _uniswapRouter The address of the Uniswap V2 Router.
     */
    constructor(
        uint256 _bankCap,
        uint256 _maxWithdraw,
        uint256 _slippageBps,
        address _admin,
        address _USDC,
        address _uniswapRouter
    ) {
        if (_bankCap == 0) revert InvalidBankCap();
        if (_maxWithdraw == 0) revert InvalidAmount();
        if (_slippageBps == 0 || _slippageBps > 500) revert InvalidSlippageBps(); // Cap slippage at 5%
        if (_admin == NATIVE_ETH) revert InvalidAddress();
        if (_USDC == NATIVE_ETH) revert InvalidAddress();
        if (_uniswapRouter == NATIVE_ETH) revert InvalidAddress();

        // Assign core bank limits
        i_bankCap = _bankCap;
        i_maxWithdraw = _maxWithdraw;
        i_slippageBps = _slippageBps;

        // Assign administrator roles
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);

        // Assign protocol addresses
        i_USDC = _USDC;
        i_uniswapRouter = IUniswapV2Router02(_uniswapRouter);
        i_WETH = i_uniswapRouter.WETH();
        s_depositCount = 0;
        s_withdrawCount = 0;
    }

    /*//////////////////////////////////////////////////////////////////////////
    //                       ETH RECEPTION (receive/fallback)
    ////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Receives native ETH, swaps it to USDC, and credits the user.
     */
    receive() external payable nonReentrant whenNotPaused {
        _depositETH(msg.value);
    }

    /**
     * @notice Fallback function, routes to ETH deposit logic.
     */
    fallback() external payable nonReentrant whenNotPaused {
        _depositETH(msg.value);
    }

    /*//////////////////////////////////////////////////////////////////////////
    //                           USER FUNCTIONS (Public)
    ////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposits ERC20 tokens.
     * @dev If token is USDC, credits directly.
     * @dev If token is not USDC, swaps to USDC via Uniswap, then credits.
     * @param _token The address of the token to deposit.
     * @param _amount The amount of the token to deposit.
     */
    function depositToken(address _token, uint256 _amount)
        external
        nonReentrant
        whenNotPaused
        nonZeroAddress(_token)
        isAmountPositive(_amount)
    {
        if (_token == i_USDC) {
            _depositUSDC(_amount);
        } else {
            _depositSwapToken(_token, _amount);
        }
    }

    /**
     * @notice Withdraws USDC from the user's balance.
     * @param _amount The amount of USDC to withdraw.
     */
    function withdraw(uint256 _amount)
        external
        whenNotPaused
        nonReentrant
        isAmountPositive(_amount)
        checkSufficientBalance(_amount)
    {
        // === CHECKS ===
        if (_amount > i_maxWithdraw) {
            revert WithdrawExceedsLimit(_amount, i_maxWithdraw);
        }

        // === EFFECTS ===
        s_balances[msg.sender] -= _amount;
        s_withdrawCount += 1;

        // === INTERACTION ===
        IERC20(i_USDC).safeTransfer(msg.sender, _amount);

        emit Withdraw(msg.sender, i_USDC, _amount);
    }

    /*//////////////////////////////////////////////////////////////////////////
    //                           VIEW FUNCTIONS (Public)
    ////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Gets the user's balance (which is always in USDC).
     * @return uint256 The amount of USDC the user has deposited.
     */
    function getUserBalance() external view returns (uint256) {
        return s_balances[msg.sender];
    }

    /**
     * @notice Gets the total USDC balance held by this contract.
     */
    function getBankBalance() public view returns (uint256) {
        return IERC20(i_USDC).balanceOf(address(this));
    }

    /*//////////////////////////////////////////////////////////////////////////
    //                        ADMIN FUNCTIONS (Restricted)
    ////////////////////////////////////////////////////////////////////////*/

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////////////////
    //                       INTERNAL & PRIVATE FUNCTIONS
    ////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Internal function to handle native ETH deposits.
     */
    function _depositETH(uint256 _amountETH) internal {
        uint256 usdcReceived = _swapETHToUSDC(_amountETH);
        _creditDeposit(msg.sender, NATIVE_ETH, _amountETH, usdcReceived);
    }

    /**
     * @notice Internal function to handle direct USDC deposits.
     */
    function _depositUSDC(uint256 _amountUSDC) internal {
        IERC20(i_USDC).safeTransferFrom(
            msg.sender,
            address(this),
            _amountUSDC
        );
        _creditDeposit(msg.sender, i_USDC, _amountUSDC, _amountUSDC);
    }

    /**
     * @notice Internal function to handle deposits of other ERC20 tokens.
     */
    function _depositSwapToken(address _token, uint256 _amountToken) internal {
        // 1. Pull tokens from user
        IERC20(_token).safeTransferFrom(
            msg.sender,
            address(this),
            _amountToken
        );

        // 2. Approve Router to spend the tokens we just received.
        // We approve 0 first to handle tokens like USDT that fail on re-approval.
        IERC20(_token).safeApprove(address(i_uniswapRouter), 0);
        IERC20(_token).safeApprove(address(i_uniswapRouter), _amountToken);

        // 3. Swap tokens to USDC
        uint256 usdcReceived = _swapTokenToUSDC(_token, _amountToken);

        // 4. Credit user's balance
        _creditDeposit(msg.sender, _token, _amountToken, usdcReceived);
    }

    /**
     * @notice The central logic for crediting a user's USDC balance.
     * @dev This function checks the bank cap *before* crediting the balance.
     */
    function _creditDeposit(
        address _user,
        address _token,
        uint256 _amountToken,
        uint256 _amountUSDC
    ) internal {
        uint256 currentBankBalance = getBankBalance();
        uint256 newBankBalance = currentBankBalance + _amountUSDC;

        // Check the bank cap
        if (newBankBalance > i_bankCap) {
            revert DepositExceedsBankCap(
                currentBankBalance,
                _amountUSDC,
                i_bankCap
            );
        }

        s_balances[_user] += _amountUSDC;
        s_depositCount++;

        emit Deposit(_user, _token, _amountToken, _amountUSDC);
    }

    /**
     * @notice Swaps native ETH for USDC.
     */
    function _swapETHToUSDC(uint256 _amountETH)
        internal
        returns (uint256 usdcReceived)
    {
        address[] memory path = new address[](2);
        path[0] = i_WETH;
        path[1] = i_USDC;

        uint256 amountOutMin = _getAmountOutMin(_amountETH, path);

        try
            i_uniswapRouter.swapExactETHForTokens{value: _amountETH}(
                amountOutMin,
                path,
                address(this),
                block.timestamp
            )
        returns (uint[] memory amounts) {
            usdcReceived = amounts[amounts.length - 1];
        } catch {
            revert InvalidSwapFailed();
        }
    }

   
    function _swapTokenToUSDC(address _token, uint256 _amountToken)
        internal
        returns (uint256 usdcReceived)
    {
        address[] memory directPath;
        directPath = new address[](2);
        directPath[0] = token;
        directPath[1] = i_USDC;

        uint256 amountOutMinDirect = _getAmountOutMin(amountToken, directPath);
        try i_uniswapRouter.swapExactTokensForTokens(
            amountToken,
            amountOutMinDirect,
            directPath,
            address(this),
            block.timestamp
        ) returns (uint[] memory amounts) {
            return amounts[amounts.length - 1];
        } catch {
        }

        address[] memory path;
        path = new address[](3);
        path[0] = token;
        path[1] = i_WETH;
        path[2] = i_USDC;

        uint256 amountOutMin = _getAmountOutMin(amountToken, path);

        try i_uniswapRouter.swapExactTokensForTokens(
            amountToken,
            amountOutMin,
            path,
            address(this),
            block.timestamp
        ) returns (uint[] memory amounts) {
            usdcReceived = amounts[amounts.length - 1];
        } catch {
            revert InvalidSwapFailed();
        }
    }

    /**
     * @notice Calculates the minimum output amount for a swap, respecting slippage.
     */
    function _getAmountOutMin(uint256 _amountIn, address[] memory _path)
        internal
        view
        returns (uint256)
    {
        try i_uniswapRouter.getAmountsOut(_amountIn, _path) returns (
            uint[] memory amountsOut
        ) {
            uint256 amountOut = amountsOut[amountsOut.length - 1];
            // Apply slippage. 10000 = 100%
            uint256 amountOutMin = (amountOut * (10000 - i_slippageBps)) /
                10000;

            if (amountOutMin == 0) revert InvalidUnsupportedToken();
            return amountOutMin;
        } catch {
            // This fails if no liquidity pair exists
            revert InvalidUnsupportedToken();
        }
    }
}