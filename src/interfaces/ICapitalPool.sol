// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/// @title ICapitalPool
/// @notice USDC vault for capital providers. ERC-4626 with settlement-split LP yield.
interface ICapitalPool {
    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error NotCreditLine();
    error NotJobRouter();
    /// @notice Withdrawal exceeds the caller's share balance.
    error InsufficientShares();
    /// @notice Withdrawal exceeds currently free liquidity.
    error InsufficientLiquidity();
    /// @notice `lendTo` called while the pool-side lending gate is OFF.
    error PoolLendingPaused();
    /// @notice Setting `lendEnabled` is a timelocked, irreversible-per-direction action.
    error LendingGateLocked();
    error Paused();
    error NonzeroShortfall();
    error NotConfigOwner();
    error NotEmergencyOps();
    error ZeroShares();

    // ---------------------------------------------------------------------
    // Capital providers
    // ---------------------------------------------------------------------

    /// @notice Deposit USDC; mints shares pro rata.
    function deposit(uint256 amount) external returns (uint256 sharesMinted);

    /// @notice Burn shares and receive principal plus pro-rata settlement revenue.
    function withdraw(uint256 shares) external returns (uint256 amountOut);

    // ---------------------------------------------------------------------
    // Credit line interface (authorized caller only)
    // ---------------------------------------------------------------------

    /// @notice Lend USDC to an agent wallet on behalf of a draw.
    /// @param to Agent wallet receiving the working capital.
    /// @param amount USDC to lend.
    function lendTo(address to, uint256 amount) external;

    /// @notice Record a repayment already transferred in.
    function receiveRepayment(uint256 principal) external;

    /// @notice Route the LP slice of a settlement into the pool.
    function receiveRevenue(uint256 amount) external;

    /// @notice Realize a loss; mark share price down immediately.
    /// @param agentId Canonical id of the defaulted agent.
    /// @param jobId Job whose settlement triggered the write-off.
    function reportLoss(bytes32 agentId, uint256 jobId) external;
    function unpause() external;
    function emergencyPaused() external view returns (bool);
    function pause() external;
    function setRouter(address router_) external;
    function setCreditLine(address creditLine_) external;

    // ---------------------------------------------------------------------
    // Reading
    // ---------------------------------------------------------------------

    function sharesOf(address lp) external view returns (uint256);
    /// @notice USDC value of one whole share, scaled 1e18.
    function pricePerShare() external view returns (uint256);
    /// @notice USDC actually withdrawable right now (contract balance).
    function freeLiquidity() external view returns (uint256);
    /// @notice Aggregate outstanding draw principal lent to agents.
    function outstandingPrincipal() external view returns (uint256);
    /// @notice Pool-side lending gate of the dual-gate defense-in-depth.
    function lendEnabled() external view returns (bool);

    function lossToReport(bytes32 agentId) external view returns (bool hasLoss, uint256 shortFall);

    // ---------------------------------------------------------------------
    // Parameters (timelocked owner; hard bounds per architecture §7)
    // ---------------------------------------------------------------------

    /// @notice Flip the pool-side lending gate. Timelocked.
    function setLendEnabled(bool enabled) external;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event Deposited(address indexed lp, uint256 amount, uint256 sharesMinted);
    event Withdrawn(address indexed lp, uint256 sharesBurned, uint256 amountOut);
    /// @notice LP-slice of a settlement landed here; share price rose, no shares minted.
    event RevenueReceived(uint256 amount, uint256 priceAfter);
    /// @notice Pool-side lending gate changed state.
    event LendEnabled(bool enabled);
    /// @notice Emitted same-block as any share-price markdown. The audit trail:
    ///         total flows reconcile from these events alone.
    event LossReported(bytes32 indexed agentId, uint256 indexed jobId, uint256 shortfall, uint256 newIndexAfter);
    event EmergencyPaused();
    event EmergencyResumed();
}
