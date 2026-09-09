// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {ICreditLine} from "./interfaces/ICreditLine.sol";
import {IJobRouter} from "./interfaces/IJobRouter.sol";
import {CapitalPool} from "./CapitalPool.sol";
import {AgentRegistry} from "./AgentRegistry.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract CreditLine is ICreditLine, Ownable {
    using SafeERC20 for IERC20;
    CapitalPool pool;
    AgentRegistry registry;
    IJobRouter router;
    address token;
    uint256 constant ABSOLUTE_CAP = 10_000e6;
    uint256[4] public UTIL = [5000, 7000, 8500, 9500]; // bps, tiers 0–3 — the ladder, pinned

    mapping(bytes32 => Debt) debts; // agentId -> debt

    struct Debt {
        uint128 principal; // principal-only: no interest, no accrual checkpoints
        address wallet;
    }
    bool public lendingEnabled; // dual-gate: false in v1; pool-side gate is the second gate

    // limit(agent)   = min(bondOf(agent), ABSOLUTE_CAP)
    // usable(agent)  = UTIL[tier] × limit − principal
    // UTIL           = [50%, 70%, 85%, 95%] for tiers 0–3   (compile-time constants)
    // ABSOLUTE_CAP   = 10_000 USDC (v1 bootstrap bound)

    constructor(address _pool, address _registry, address _token, address _router, address _owner) Ownable(_owner) {
        pool = CapitalPool(_pool);
        registry = AgentRegistry(_registry);
        router = IJobRouter(_router);
        token = _token;
    }

    function draw(bytes32 agentId, uint256 amount) external override {
        if (!lendingEnabled) revert LendingDisabled(); // dual gate, credit side
        if (msg.sender != address(router)) revert NotRouter(); // router state + constructor param
        address agent = registry.agentIdOwnerOf(agentId); // ← R2's owner-map IS the agentId→wallet bridge
        if (agent == address(0) || !registry.isEligible(agent)) revert NotEligible();

        uint256 limit = Math.min(registry.bondOf(agent), ABSOLUTE_CAP);
        uint256 headroom = (limit * UTIL[registry.tier(agent)]) / 10_000;
        uint256 principal = debts[agentId].principal;
        uint256 available = headroom > principal ? headroom - principal : 0; // tier-decay clamp, no underflow
        if (amount > available) revert ExceedsLimit(); // ← direction fixed

        bool firstDraw = principal == 0;
        if (debts[agentId].wallet != address(0) && debts[agentId].wallet != agent) revert(); // one wallet per ledger
        // amount ≤ available ≤ headroom ≤ min(bond, ABSOLUTE_CAP) — fits uint128
        // forge-lint: disable-next-line(unsafe-typecast)
        debts[agentId].principal += uint128(amount);
        debts[agentId].wallet = agent;
        if (firstDraw) registry.setDebtLock(agent, true); // 0→positive only
        pool.lendTo(agent, amount);
        emit Drawn(agentId, amount);
    }

    function repay(bytes32 agentId, uint256 amount) external override {
        uint128 principal = debts[agentId].principal;
        if (amount == 0 || amount > principal) revert(); // over-repayment guard
        IERC20(token).safeTransferFrom(msg.sender, address(pool), amount); // payer can be anyone
        pool.receiveRepayment(amount); // ledger down, pps unchanged
        // over-repayment guard above bounds amount ≤ principal → fits uint128
        // forge-lint: disable-next-line(unsafe-typecast)
        debts[agentId].principal = principal - uint128(amount);
        if (debts[agentId].principal == 0) registry.setDebtLock(debts[agentId].wallet, false);
        emit Repaid(agentId, amount, debts[agentId].principal);
    }

    function applySlashCoverage(bytes32 agentId, uint256 coverage) external override {
        if (msg.sender != address(router)) revert NotRouter(); // seizure already landed via registry.slash
        uint128 covered = uint128(Math.min(coverage, debts[agentId].principal));
        debts[agentId].principal -= covered;
        pool.receiveRepayment(covered); // pool re-acquired the collateral
        emit Slashed(agentId, covered, debts[agentId].principal);
    }

    function limitOf(address agent) public view override returns (uint256) {
        return Math.min(registry.bondOf(agent), ABSOLUTE_CAP);
    }

    function availableOf(address agent) external view override returns (uint256) {
        uint256 headroom = (limitOf(agent) * UTIL[registry.tier(agent)]) / 10_000;
        uint256 principal = debts[registry.agentIdOf(agent)].principal;
        return headroom > principal ? headroom - principal : 0; // tier-decay clamp, no underflow
    }

    function debtOf(address agent) external view override returns (uint256 principal) {
        return debts[registry.agentIdOf(agent)].principal;
    }

    function absoluteCap() public pure override returns (uint256) {
        return ABSOLUTE_CAP; // compile-time constant, not an owner dial (P7)
    }

    function setRouter(address router_) external override onlyOwner {
        if (address(router_) == address(0)) revert();
        router = IJobRouter(router_);
    }

    function setAbsoluteCap(uint256 cap) external override onlyOwner {}

    function setLendingEnabled(bool active) public override onlyOwner {
        lendingEnabled = active;
    }

    function shortfallOf(bytes32 agentId) external view returns (uint256) {
        uint256 d = debts[agentId].principal;
        uint256 b = registry.bondOf(debts[agentId].wallet);
        return d > b ? d - b : 0;
    }
}
