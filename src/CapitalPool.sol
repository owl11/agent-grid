// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ICapitalPool} from "../src/interfaces/ICapitalPool.sol";
import {ICreditLine} from "../src/interfaces/ICreditLine.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
// CAN be share-attacked (donation/rounding theft);
//  constructor commits the virtual-offset guard —
// the pool's security is the ledger-led price + dead shares,
//  not "lending is off."

contract CapitalPool is ERC4626, ICapitalPool {
    using SafeERC20 for IERC20;
    using Math for uint256;
    IERC20 public immutable usdc;
    address public emergencyOps;
    address public router;
    address public creditLine;
    uint256 public totalPrincipal; // outstanding draw principal via CreditLine
    bool public lendEnabled; // dual-gate: false in v1; CreditLine's flag is the second gate
    bool public paused;

    constructor(IERC20 underlying_, address _router, address _creditLine)
        ERC20("PoolShare", "POOL")
        ERC4626(underlying_)
    {
        emergencyOps = msg.sender;
        usdc = underlying_;
        router = _router;
        creditLine = _creditLine;
    }

    /// @notice Locked one-arg entry — ≡ 4626 deposit(amount, msg.sender).
    /// @notice P6/P8 mandatory as the FIRST guard; P9 mint round-down.
    /// Locked one-arg shape (backwards compat) = 4626 `deposit(amount, msg.sender)`.
    /// `totalShares` ≡ ERC20 `_totalSupply` (OZ ERC4626); `Shares[msg.sender]` ≡ `balanceOf`.
    function deposit(uint256 amount) external override returns (uint256 sharesMinted) {
        sharesMinted = deposit(amount, msg.sender); // 4626 flow: pause (P8) → preview → pull → mint
        // emit Deposited(msg.sender, amount, sharesMinted); // legacy event alongside 4626 Deposit
    }

    /// @notice Locked one-arg exit — ≡ 4626 redeem(shares, msg.sender, msg.sender).
    /// Shares-IN (not assets); never pause-blocked (entry-only pause).
    function withdraw(uint256 shares) external override returns (uint256 amountOut) {
        amountOut = redeem(shares, msg.sender, msg.sender); // capped maxRedeem → burn → pay
        // emit Withdrawn(msg.sender, shares, amountOut); // sharesBurned = shares, NOT pre-burn balance
    }

    /// @notice Pool-side gate of the dual gate. P8 first, then gate, then auth, then cap.
    function lendTo(address to, uint256 amount) external override {
        if (paused) revert Paused(); // P8 — checked FIRST
        if (!lendEnabled) revert PoolLendingPaused(); // I6 pool-side gate
        if (msg.sender != creditLine) revert NotCreditLine();
        if (amount > usdc.balanceOf(address(this)) - totalPrincipal) revert InsufficientLiquidity(); // P5
        totalPrincipal += amount;
        usdc.safeTransfer(to, amount); // balance −amount; pps unchanged (NAV keeps principal)
    }

    /// @notice Record a repayment already pulled in by the caller. Wind-down path:
    /// live regardless of gate AND pause state.
    function receiveRepayment(uint256 principal) external override {
        if (msg.sender != creditLine) revert NotCreditLine(); // NOT router — that's receiveRevenue
        totalPrincipal -= principal; // underflow reverts = over-repayment guard; pps unchanged
    }

    /// @notice LP-slice of a settlement landed here; pps rises, NO shares minted (P7).
    /// JobRouter only — funds were already transferred in by the caller.
    function receiveRevenue(uint256 amount) external override {
        if (msg.sender != router) revert NotJobRouter();
        emit RevenueReceived(amount, pricePerShare());
    }

    function reportLoss(bytes32 agentId, uint256 jobId) external override {
        if (msg.sender != creditLine) revert NotCreditLine();
        uint256 shortfall = ICreditLine(msg.sender).shortfallOf(agentId); // derived, zero-trust
        shortfall = Math.min(shortfall, totalPrincipal); // never underflow the ledger
        totalPrincipal -= shortfall; // the pps markdown, same block
        if (shortfall != 0) _emergencyPause();
        emit LossReported(agentId, jobId, shortfall, pricePerShare()); // price AFTER write-down
    }

    function lossToReport(bytes32 agentId) external view override returns (bool hasLoss, uint256 shortFall) {
        uint256 s = ICreditLine(creditLine).shortfallOf(agentId);
        return (s != 0, s);
    }

    function sharesOf(address lp) external view override returns (uint256) {
        return balanceOf(lp);
    }

    function pricePerShare() public view override returns (uint256) {
        return convertToAssets(1 ether);
    }

    function freeLiquidity() public view override returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    function outstandingPrincipal() external view override returns (uint256) {
        return totalPrincipal;
    }

    function emergencyPaused() external view override returns (bool) {
        return paused;
    }

    function _emergencyPause() internal returns (bool) {
        if (!paused) {
            paused = true;
            emit EmergencyPaused();
        }

        return paused;
    }

    function setLendEnabled(bool enabled) external override {
        if (msg.sender != emergencyOps) revert NotConfigOwner();
        lendEnabled = enabled;
        emit LendEnabled(enabled);
    }

    function setRouter(address router_) external override {
        // gated to emergencyOps (the deployer/ops) so the pool can be wired post-deploy;
        // NOT self-gated to `router` (which would make this setter structurally unreachable)
        if (msg.sender != emergencyOps) revert NotConfigOwner();
        router = router_;
    }

    function setCreditLine(address creditLine_) external override {
        if (msg.sender != emergencyOps) revert NotConfigOwner(); // same deployer identity
        creditLine = creditLine_;
    }

    function pause() external override {
        if (msg.sender != emergencyOps) revert NotEmergencyOps();
        if (!paused) {
            paused = true;
            emit EmergencyPaused();
        }
    }

    function unpause() external override {
        if (msg.sender != emergencyOps) revert NotEmergencyOps();
        if (paused) {
            paused = false;
            emit EmergencyResumed();
        }
    }

    function totalAssets() public view override returns (uint256) {
        return usdc.balanceOf(address(this)) + totalPrincipal;
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        if (paused) revert Paused();
        if (shares == 0) revert ZeroShares();
        super._deposit(caller, receiver, assets, shares);
    }

    function _withdraw(address caller, address receiver, address _owner, uint256 assets, uint256 shares)
        internal
        override
    {
        if (assets > freeLiquidity()) revert InsufficientLiquidity();
        super._withdraw(caller, receiver, _owner, assets, shares);
    }

    function maxRedeem(address owner) public view override returns (uint256 result) {
        // `min(balanceOf, convertToShares(freeLiquidity()))`;
        // maxWithdraw = `previewRedeem(maxRedeem)`
        result = Math.min(balanceOf(owner), convertToShares(freeLiquidity()));
        return result;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return previewRedeem(maxRedeem(owner));
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 12;
    }

    function decimals() public view virtual override returns (uint8) {
        return ERC20(address(usdc)).decimals() + _decimalsOffset(); // _decimalsOffset() defaults to 0
    }
}
