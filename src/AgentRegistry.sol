// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/// @title AgentRegistry
/// @notice Bonding, pluggable identity, append-only reputation. No discretionary score adjustments, ever (P2, P5).

import {IAgentIdentity} from "../src/interfaces/IAgentIdentity.sol";
import {IAgentRegistry} from "../src/interfaces/IAgentRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract AgentRegistry is IAgentRegistry {
    using SafeERC20 for IERC20;

    uint256 constant ALPHA = 97 * 1e16; // 97% retention per outcome (half-life ~30 days equivalent)
    uint256 constant BASE_WEIGHT = 1e18; // weight per settled job
    uint256 constant DEFAULT_REP = 0.5e18; // 50% default for new agents
    uint256 constant VOL_CAP = 100_000e6; // $100k USDC cap for volume factor

    uint256 public MIN_BOND;
    IERC20 public SETTLEMENT_TOKEN;
    uint64 public DELAY;
    address public ROUTER;
    address public immutable POOL; // R6: slash proceeds land here (I3)
    address public creditLine;
    address public owner;

    constructor(
        address settlementToken,
        uint256 _minBond,
        uint64 delay,
        address _router,
        address pool_,
        address _owner
    ) {
        SETTLEMENT_TOKEN = IERC20(settlementToken);
        MIN_BOND = _minBond;
        DELAY = delay;
        ROUTER = _router;
        POOL = pool_;
        owner = _owner;
    }

    mapping(address => Agent) private agents;
    mapping(address => AgentRep) private reps;
    mapping(bytes32 => address) private agentIdOwner;
    mapping(address => bool) private debtLocks;

    struct Agent {
        uint256 bond;
        uint64 registeredAt;
        uint64 unlockAt;
        bytes32 agentId;
        IAgentIdentity adapter;
        uint256 externalId;
        bool revoked;
    }

    struct AgentRep {
        uint256 num; // Weighted successes
        uint256 den; // Weighted total observations
        uint256 totalVolume; // Capped settled volume for volumeFactor
    }

    /// @notice Become a bonded agent: escrow `amount >= minBond` USDC and bind an identity.
    /// @param adapter Identity adapter (bare mode = IAgentIdentity(0)).
    /// @param externalId Token id on the source registry (0 in bare mode).
    /// @param amount USDC to escrow.
    function bondIn(IAgentIdentity adapter, uint256 externalId, uint256 amount) external override {
        if (agents[msg.sender].bond != 0) revert AlreadyBonded();
        if (amount < MIN_BOND) revert BelowMinBond();
        bytes32 agentId = _deriveAgentId(adapter, externalId, msg.sender);
        if (agentIdOwner[agentId] != address(0) && agentIdOwner[agentId] != msg.sender) {
            revert AgentIdAlreadyBound(agentId);
        }

        if (address(adapter) != address(0) && !adapter.verifyOwnership(externalId, msg.sender)) {
            revert UnverifiedIdentity();
        }
        SETTLEMENT_TOKEN.safeTransferFrom(msg.sender, address(this), amount);
        agents[msg.sender] = Agent({
            bond: amount,
            registeredAt: uint64(block.timestamp),
            unlockAt: 0,
            agentId: agentId,
            adapter: adapter,
            externalId: externalId,
            revoked: false
        });
        agentIdOwner[agentId] = msg.sender; // ← ③ the write — the only thing missing

        emit BondedIn(msg.sender, agentId, address(adapter), amount);
    }

    function addBond(uint256 amount) external override {
        if (agents[msg.sender].bond == 0) revert NotBonded();
        agents[msg.sender].bond += amount;
        SETTLEMENT_TOKEN.safeTransferFrom(msg.sender, address(this), amount);
        emit BondAdded(msg.sender, agents[msg.sender].bond);
    }

    function requestExit() external override {
        Agent storage a = agents[msg.sender];
        if (a.bond == 0) revert NotBonded();
        if (debtLocks[msg.sender]) revert ExitBlockedByDebt();
        a.unlockAt = uint64(block.timestamp) + DELAY;
        emit ExitRequested(msg.sender, a.unlockAt);
    }

    function completeExit() external override {
        Agent storage a = agents[msg.sender];
        uint256 amount = a.bond;
        if (amount == 0) revert NotBonded();
        if (a.unlockAt == 0 || block.timestamp < a.unlockAt) revert UnlockPending();
        SETTLEMENT_TOKEN.safeTransfer(msg.sender, amount);
        // delete agents[msg.sender]; we cant delete agents from our registry since it can be taken advantage off to cleanse bad reputation
        emit Exited(msg.sender, amount);
    }

    function slash(address agent, uint256 amount, bytes32 reasonHash) external override {
        if (msg.sender != ROUTER) revert UnauthorizedCaller();
        Agent storage a = agents[agent];
        if (a.bond == 0) revert NotBonded();
        if (amount > a.bond) revert SlashExceedsBond();
        a.bond -= amount;
        SETTLEMENT_TOKEN.safeTransfer(POOL, amount); // R6: seized collateral lands in the pool (I3)
        emit Slashed(agent, amount, reasonHash);
    }

    function isEligible(address wallet) public view override returns (bool) {
        Agent storage a = agents[wallet];
        if (a.bond == 0 || a.unlockAt != 0 || debtLocks[wallet]) return false;
        if (address(a.adapter) != address(0)) return !a.adapter.isRevoked(a.externalId);
        return true;
    }

    function recordOutcome(address agent, uint256 jobId, Outcome outcome, uint256 volume) external override {
        if (msg.sender != ROUTER) revert UnauthorizedCaller();
        Agent storage a = agents[agent];
        if (a.bond == 0) revert NotBonded();

        AgentRep storage r = reps[agent];

        // R5: NEUTRAL (mutual cancel / OOPS) is WEIGHT-ZERO — no score update, no
        // decay tick, no volume (anti-wash: friendly exits buy nothing, cost nothing).
        // FRAUD enters the EWMA at 5x a failure's weight (den only — zero successes).
        if (outcome != Outcome.NEUTRAL) {
            bool success = outcome == Outcome.SUCCESS;
            uint256 weight = outcome == Outcome.FRAUD ? 5 * BASE_WEIGHT : BASE_WEIGHT;

            // Streaming EWMA: decay history, add today's observation
            r.num = (r.num * ALPHA) / 1e18 + (success ? BASE_WEIGHT : 0);
            r.den = (r.den * ALPHA) / 1e18 + weight;

            // Cap totalVolume at VOL_CAP for volumeFactor
            uint256 next = r.totalVolume + volume;
            r.totalVolume = next > VOL_CAP ? VOL_CAP : next;
        }

        uint256 ewmaAfter = r.den == 0 ? DEFAULT_REP : (r.num * 1e18) / r.den;
        emit OutcomeRecorded(jobId, agent, outcome, volume, ewmaAfter);
    }

    function setDebtLock(address agent, bool locked) external override {
        // Credit state is written by the credit line (or the coordinator it routes
        // through). Unguarded writes could lift an exit lock or block exits — gated.
        if (msg.sender != creditLine && msg.sender != ROUTER) revert UnauthorizedCaller();
        debtLocks[agent] = locked;
    }

    function setRouter(address router) public {
        if (msg.sender != owner) revert();
        ROUTER = router;
    }

    function setCreditLine(address cl) external {
        if (msg.sender != owner) revert();
        creditLine = cl;
    }

    function bondOf(address agent) external view override returns (uint256) {
        return agents[agent].bond;
    }

    function agentIdOf(address agent) external view override returns (bytes32) {
        return agents[agent].agentId;
    }

    function repScore(address agent) public view override returns (uint256) {
        AgentRep storage r = reps[agent];
        if (r.den == 0) return DEFAULT_REP;
        uint256 ewma = (r.num * 1e18) / r.den;
        return (ewma * volumeFactor(agent)) / 1e18; // ewma x volumeFactor
    }

    function volumeFactor(address agent) public view override returns (uint256) {
        return (reps[agent].totalVolume * 1e18) / VOL_CAP;
    }

    function tier(address agent) external view override returns (uint8) {
        uint256 s = repScore(agent);
        uint256 vf = volumeFactor(agent);
        if (s >= 0.9e18 && vf >= 0.75e18) return 3;
        if (s >= 0.75e18) return 2;
        if (s >= 0.5e18) return 1;
        return 0;
    }

    function unlockAt(address agent) external view override returns (uint64) {
        return agents[agent].unlockAt;
    }

    function isDebtLocked(address agent) external view override returns (bool) {
        return debtLocks[agent];
    }

    function minBond() external view override returns (uint256) {
        return MIN_BOND;
    }

    function unlockDelay() external view override returns (uint64) {
        return DELAY;
    }
    // --- observability getters (not part of the cross-contract API) ---

    function repOfWallet(address wallet) external view returns (uint256 num, uint256 den, uint256 totalVolume) {
        AgentRep storage r = reps[wallet];
        return (r.num, r.den, r.totalVolume);
    }

    function agentIdOwnerOf(bytes32 agentId) external view returns (address) {
        return agentIdOwner[agentId];
    }

    function agentRecord(address wallet)
        external
        view
        returns (
            uint256 bond,
            uint64 registeredAt,
            uint64 exitAt,
            bytes32 agentId,
            IAgentIdentity adapter,
            uint256 externalId,
            bool revoked
        )
    {
        Agent storage a = agents[wallet];
        return (a.bond, a.registeredAt, a.unlockAt, a.agentId, a.adapter, a.externalId, a.revoked);
    }

    /// @dev Pure math: (provider, subject) -> primary key. No claims checked here.
    function _deriveAgentId(IAgentIdentity adapter, uint256 externalId, address wallet)
        internal
        pure
        returns (bytes32)
    {
        if (address(adapter) == address(0)) {
            return bytes32(uint256(uint160(wallet)));
        }
        // identifiers must be forge-stable across adapters; the asm keccak variant
        // adds audit risk for zero gain on this derivation path
        // forge-lint: disable-next-line(asm-keccak256)
        return keccak256(abi.encodePacked(address(adapter), externalId));
    }
}
