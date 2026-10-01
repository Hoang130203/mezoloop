// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IERC20} from "./interfaces/IERC20.sol";
import {IBorrowerOperations} from "./interfaces/IBorrowerOperations.sol";
import {ITroveManager} from "./interfaces/ITroveManager.sol";
import {IPriceFeed} from "./interfaces/IPriceFeed.sol";
import {IHintHelpers} from "./interfaces/IHintHelpers.sol";
import {ISwapAdapter} from "./interfaces/ISwapAdapter.sol";

/**
 * @title MezoLoopVault
 * @notice One-click leveraged BTC exposure, built natively on MUSD.
 *
 * Users deposit native BTC and receive mlBTC shares tracking the vault's net
 * equity. The vault owns one pooled MUSD trove and programmatically:
 *   1. deposits BTC collateral (openTrove / addColl, payable in native BTC),
 *   2. borrows MUSD via BorrowerOperations.withdrawMUSD,
 *   3. swaps MUSD -> BTC through a pluggable ISwapAdapter (Mezo Pools),
 *   4. re-deposits that BTC as collateral,
 * converging the trove on `targetICR`. Effective leverage ~= r/(r-1)
 * (e.g. target ICR 150% -> ~3x gross exposure).
 *
 * Exits burn shares and repay pro-rata debt so the trove's ICR is preserved
 * for remaining depositors. MUSD only allows collateral withdrawals while
 * ICR stays above its MCR, so exits/unwinds are executed as a bounded
 * repay<->withdraw loop inside a single transaction.
 *
 * SortedTroves insertion hints can be resolved either on-chain
 * (getApproxHint inside the loop, convenient for small batches) or
 * off-chain via the keeper-style step API — recommended on Mezo testnet
 * where a ~10M block gas limit can make inexact-hint list walks exceed
 * the per-transaction budget.
 *
 * Wave 1 scope: single pooled trove, owner-operated leverage management.
 */
contract MezoLoopVault is ERC20, ReentrancyGuard, Ownable {
    uint256 private constant PRECISION = 1e18;
    uint256 private constant BPS = 10_000;
    uint8 private constant MAX_ITERS = 12;
    /// @dev Refinance calls refresh the trove's debt ceiling (MUSD snapshots
    /// it at openTrove and only recomputes on refinance). A few unlocks are
    /// enough for the loop to converge; each costs ~0.02% of debt.
    uint8 private constant MAX_REFIS = 6;

    uint256 public constant MIN_TARGET_ICR = 1.25e18; // stay clear of MCR (~110%)
    uint256 public constant MAX_TARGET_ICR = 5e18;
    uint256 public constant MIN_LOOP_BORROW = 1e18; // 1 MUSD dust threshold
    /// @notice Convergence tolerance for exits: >=99.5% of the pro-rata
    /// collateral target must actually leave the trove.
    uint256 public constant EXIT_TOLERANCE_BPS = 9950;

    // ---- MUSD core protocol (immutable) ----
    IERC20 public immutable musd;
    IBorrowerOperations public immutable borrowerOperations;
    ITroveManager public immutable troveManager;
    IPriceFeed public immutable priceFeed;
    IHintHelpers public immutable hintHelpers;

    // ---- Strategy config ----
    ISwapAdapter public swapAdapter;
    uint256 public targetICR = 1.5e18; // 150% -> ~3x leverage
    uint256 public unwindFloorICR = 1.15e18; // never push ICR below this
    /// @dev 5% default: testnet MUSD/BTC pool prices ~6% under the oracle.
    /// Tighten toward 100-200 bps for production-priced liquidity.
    uint16 public maxSlippageBps = 500;
    uint8 public hintTrials = 10;
    bool public paused;

    event Deposited(address indexed user, uint256 btcIn, uint256 sharesOut);
    event Exited(address indexed user, uint256 sharesIn, uint256 btcOut);
    event TroveOpened(uint256 coll, uint256 debt);
    event Levered(uint256 musdBorrowed, uint256 btcAdded, uint256 icrAfter);
    event Delevered(uint256 collWithdrawn, uint256 musdRepaid, uint256 icrAfter);
    event AllClosed(uint256 residualDebt, uint256 btcBalance);
    event CapacityRefreshed(uint256 previousCap);
    event SwapAdapterSet(address adapter);
    event TargetICRSet(uint256 targetICR);

    error Paused();
    error ZeroAmount();
    error Slippage(uint256 got, uint256 min);
    error TroveAlreadyActive();
    error NoTrove();
    error DebtTooSmall(uint256 computed, uint256 minNetDebt);
    error InsufficientExitLiquidity();
    error NothingToWithdraw();
    error BadTarget();
    error InsufficientShares();

    modifier notPaused() {
        if (paused) revert Paused();
        _;
    }

    constructor(
        address _musd,
        address _borrowerOperations,
        address _troveManager,
        address _priceFeed,
        address _hintHelpers,
        address _swapAdapter
    ) ERC20("MezoLoop Leveraged BTC", "mlBTC") Ownable(msg.sender) {
        musd = IERC20(_musd);
        borrowerOperations = IBorrowerOperations(_borrowerOperations);
        troveManager = ITroveManager(_troveManager);
        priceFeed = IPriceFeed(_priceFeed);
        hintHelpers = IHintHelpers(_hintHelpers);
        // Verified: MUSD exposes burn(address,uint256) — BorrowerOperations
        // burns the caller's balance directly. Allowance kept as a harmless
        // hedge in case a deployment variant pulls via burnFrom instead.
        musd.approve(_borrowerOperations, type(uint256).max);
        if (_swapAdapter != address(0)) _setSwapAdapter(_swapAdapter);
    }

    receive() external payable {}

    // ------------------------------------------------------------------
    //  Views
    // ------------------------------------------------------------------

    /// @notice Vault trove state: (collateral BTC, debt MUSD, ICR, status).
    function trove()
        public
        view
        returns (uint256 coll, uint256 debt, uint256 icr, uint8 status)
    {
        coll = troveManager.getTroveColl(address(this));
        debt = troveManager.getTroveDebt(address(this));
        status = uint8(troveManager.getTroveStatus(address(this)));
        icr = debt == 0
            ? type(uint256).max
            : troveManager.getCurrentICR(address(this), _price());
    }

    /// @notice Net equity in BTC terms: collateral + free BTC - debt.
    function equityBtc() public view returns (uint256) {
        (uint256 coll, uint256 debt, , ) = trove();
        uint256 debtInBtc = _musdToBtc(debt);
        uint256 collSide = coll + address(this).balance;
        return collSide > debtInBtc ? collSide - debtInBtc : 0;
    }

    /// @notice Effective leverage = gross collateral / net equity (1e18 = 1x).
    function leverage() public view returns (uint256) {
        (uint256 coll, , , uint8 status) = trove();
        if (status != 1 || coll == 0) return PRECISION;
        uint256 eq = equityBtc();
        return eq == 0 ? type(uint256).max : (coll * PRECISION) / eq;
    }

    function navPerShare() public view returns (uint256) {
        uint256 supply = totalSupply();
        return supply == 0 ? PRECISION : (equityBtc() * PRECISION) / supply;
    }

    function btcPrice() public view returns (uint256) {
        return _price();
    }

    // ------------------------------------------------------------------
    //  User entry / exit
    // ------------------------------------------------------------------

    /// @notice Deposit native BTC, receive mlBTC shares priced at NAV.
    /// BTC stays unencumbered in the vault until the operator next calls
    /// enter/loopToTarget (leverage moves are batched to save gas).
    function deposit() external payable nonReentrant notPaused {
        if (msg.value == 0) revert ZeroAmount();
        uint256 supply = totalSupply();
        uint256 preEquity = equityBtc() - msg.value; // msg.value already counted
        uint256 shares = (supply == 0 || preEquity == 0)
            ? msg.value
            : (msg.value * supply) / preEquity;
        if (shares == 0) revert ZeroAmount();
        _mint(msg.sender, shares);
        emit Deposited(msg.sender, msg.value, shares);
    }

    /**
     * @notice Burn shares and withdraw the pro-rata BTC equity.
     * Keeps trove ICR ~constant: repay f*debt MUSD (bought with part of the
     * released collateral) and pull f*coll BTC out, forwarding the net BTC.
     *
     * Because MUSD refuses collateral withdrawals that push ICR under MCR,
     * the unwind runs as a bounded loop (withdraw chunk -> swap -> repay ->
     * repeat), converging inside one transaction for practical exit sizes.
     * Reverts if >0.5% of the target collateral stays trapped.
     */
    function exit(
        uint256 shares,
        uint256 minBtcOut
    ) external nonReentrant returns (uint256 btcToUser) {
        if (shares == 0 || shares > balanceOf(msg.sender))
            revert InsufficientShares();
        uint256 supply = totalSupply(); // pre-burn

        (uint256 coll, uint256 debt, , uint8 status) = trove();
        _burn(msg.sender, shares);

        if (status != 1 || debt == 0 || coll == 0) {
            // No leverage outstanding: plain pro-rata BTC payout.
            btcToUser = (shares * address(this).balance) / supply;
            _sendBtc(msg.sender, btcToUser);
            if (btcToUser < minBtcOut) revert Slippage(btcToUser, minBtcOut);
            emit Exited(msg.sender, shares, btcToUser);
            return btcToUser;
        }

        uint256 collTarget = (coll * shares) / supply; // BTC to release
        uint256 repayTarget = (debt * shares) / supply; // MUSD to repay

        uint256 collWithdrawn;
        uint256 repaid;
        uint256 btcSpent;

        for (uint8 i; i < MAX_ITERS; ++i) {
            if (collWithdrawn >= collTarget) break;
            uint256 step = _withdrawable();
            uint256 want = collTarget - collWithdrawn;
            if (step > want) step = want;
            if (step == 0) break;

            (address up, address lo) = _hints();
            borrowerOperations.withdrawColl(step, up, lo);
            collWithdrawn += step;

            uint256 stillOwed = repayTarget - repaid;
            if (stillOwed > 0) {
                // BTC needed to buy stillOwed MUSD, with slippage headroom.
                uint256 btcNeeded = (stillOwed * PRECISION * (BPS + maxSlippageBps)) /
                    (_price() * BPS);
                uint256 spend = btcNeeded < step ? btcNeeded : step;
                // Per-swap guard: adapter quote minus slippage tolerance.
                uint256 minOut = (swapAdapter.quoteBtcToMusd(spend) *
                    (BPS - maxSlippageBps)) / BPS;
                uint256 musdOut = swapAdapter.swapBtcForMusd{value: spend}(
                    minOut,
                    address(this)
                );
                (, uint256 liveDebt, , ) = trove();
                uint256 pay = musdOut < stillOwed ? musdOut : stillOwed;
                if (pay > liveDebt) pay = liveDebt;
                borrowerOperations.repayMUSD(pay, up, lo);
                repaid += pay;
                btcSpent += spend;
            }
        }

        if (collWithdrawn * BPS < collTarget * EXIT_TOLERANCE_BPS)
            revert InsufficientExitLiquidity();

        btcToUser = collWithdrawn - btcSpent;
        _sendBtc(msg.sender, btcToUser);
        if (btcToUser < minBtcOut) revert Slippage(btcToUser, minBtcOut);
        emit Exited(msg.sender, shares, btcToUser);
    }

    // ------------------------------------------------------------------
    //  Leverage management (operator)
    // ------------------------------------------------------------------

    /**
     * @notice Open the trove with all free BTC, seed it with MUSD debt, swap
     * that MUSD back into BTC collateral, then converge on targetICR.
     * @param initialDebt MUSD to mint at open. Pass 0 to auto-size to a
     * conservative 130% opening ICR. Must satisfy minNetDebt (~1800 MUSD).
     */
    function enter(
        uint256 initialDebt,
        uint8 maxIters
    ) external onlyOwner nonReentrant notPaused {
        (, , , uint8 status) = trove();
        if (status == 1) revert TroveAlreadyActive();
        // Liquity-style systems restrict new debt during recovery mode.
        require(
            !troveManager.checkRecoveryMode(_price()),
            "recovery mode"
        );
        uint256 free = address(this).balance;
        if (free == 0) revert ZeroAmount();

        if (initialDebt == 0) {
            // Conservative opener: 130% ICR, leaving headroom above MCR.
            initialDebt = (free * _price()) / 1.3e18;
        }
        uint256 minDebt = borrowerOperations.minNetDebt();
        if (initialDebt < minDebt) revert DebtTooSmall(initialDebt, minDebt);

        (address up, address lo) = _hints();
        borrowerOperations.openTrove{value: free}(initialDebt, up, lo);
        emit TroveOpened(free, initialDebt);

        // Recycle the freshly minted MUSD into collateral.
        _swapAndTopUp(initialDebt);
        _loopToTarget(maxIters);
    }

    /// @notice Move idle deposited BTC into the trove and re-target leverage.
    /// Call after user deposits accrue while the trove is already active.
    function sweepIdle(uint8 maxIters) external onlyOwner nonReentrant {
        uint256 free = address(this).balance;
        if (free > 0) {
            (address up, address lo) = _hints();
            borrowerOperations.addColl{value: free}(up, lo);
        }
        _loopToTarget(maxIters);
    }

    /**
     * @notice Iterate borrow->swap->addColl (or repay->withdraw) until
     * ICR ~= targetICR. State is re-read each iteration, so borrowing fees
     * and swap slippage are absorbed automatically.
     */
    function loopToTarget(uint8 maxIters) external onlyOwner nonReentrant {
        _loopToTarget(maxIters);
    }

    // ------------------------------------------------------------------
    //  Keeper-style step API (off-chain hints)
    // ------------------------------------------------------------------
    //
    // Mezo testnet blocks cap at ~10M gas. SortedTroves keeps every trove in
    // a linked list sorted by nominal ICR, and inserting with an inexact
    // hint triggers an O(n) list walk inside the protocol — several million
    // gas on a populated list. The canonical Liquity pattern is therefore:
    // resolve (prevId, nextId) OFF-CHAIN via HintHelpers.getApproxHint +
    // SortedTroves.findInsertPosition (both free view calls), then submit a
    // step transaction carrying the exact pair — insert/reInsert validates
    // in O(1) and each step stays well under the block limit.

    /// @notice Plan the next leverage step. `maxBorrowNow` is the protocol
    /// headroom under the trove's lifetime-debt cap; when it is below
    /// `borrowAmount` the keeper should call `refiStep` first, then re-plan.
    function planLeverageStep()
        external
        view
        returns (uint256 borrowAmount, uint256 maxBorrowNow, bool done)
    {
        (uint256 coll, uint256 debt, uint256 icr, uint8 status) = trove();
        if (status != 1 || icr <= targetICR) return (0, 0, true);
        uint256 feeRate = borrowerOperations.borrowingRate();
        uint256 collUsd = (coll * _price()) / PRECISION;
        uint256 dTarget = _borrowToReachTarget(collUsd, debt);
        uint256 dCap = _borrowHeadroom(collUsd, debt, feeRate);
        borrowAmount = dTarget < dCap ? dTarget : dCap;
        uint256 maxCap = troveManager.getTroveMaxBorrowingCapacity(
            address(this)
        );
        maxBorrowNow = maxCap > debt
            ? ((maxCap - debt) * PRECISION) / (PRECISION + feeRate)
            : 0;
        if (borrowAmount < MIN_LOOP_BORROW) {
            borrowAmount = 0;
            done = true;
        }
    }

    /// @notice Open the pooled trove. Hints are computed off-chain for the
    /// post-open nominal ICR: nicr = coll * 1e20 / (debt*(1+fee) + gasComp).
    function openTroveStep(
        uint256 initialDebt,
        address up,
        address lo
    ) external onlyOwner nonReentrant notPaused {
        (, , , uint8 status) = trove();
        if (status == 1) revert TroveAlreadyActive();
        require(
            !troveManager.checkRecoveryMode(_price()),
            "recovery mode"
        );
        uint256 free = address(this).balance;
        if (free == 0) revert ZeroAmount();
        if (initialDebt == 0) {
            initialDebt = (free * _price()) / 1.3e18;
        }
        uint256 minDebt = borrowerOperations.minNetDebt();
        if (initialDebt < minDebt) revert DebtTooSmall(initialDebt, minDebt);
        borrowerOperations.openTrove{value: free}(initialDebt, up, lo);
        emit TroveOpened(free, initialDebt);
    }

    /// @notice Borrow `d` MUSD. Hints are for the post-borrow nominal ICR:
    /// nicr = coll * 1e20 / (debt + d*(1+borrowingRate)).
    function borrowStep(
        uint256 d,
        address up,
        address lo
    ) external onlyOwner nonReentrant {
        borrowerOperations.withdrawMUSD(d, up, lo);
    }

    /// @notice Swap vault-held MUSD to BTC and top up collateral. Hints are
    /// for the post-add nominal ICR using the adapter's quote as the BTC
    /// estimate: nicr = (coll + quoteBtcOut) * 1e20 / debt.
    function swapTopUpStep(
        uint256 musdAmount,
        address up,
        address lo
    ) external onlyOwner nonReentrant {
        uint256 minOut = (swapAdapter.quoteMusdToBtc(musdAmount) *
            (BPS - maxSlippageBps)) / BPS;
        uint256 btcOut = swapAdapter.swapMusdForBtc(
            musdAmount,
            minOut,
            payable(address(this))
        );
        borrowerOperations.addColl{value: btcOut}(up, lo);
        emit Levered(musdAmount, btcOut, _currentICR());
    }

    /// @notice Refresh the trove's maxBorrowingCapacity via refinance().
    /// Hints for the post-refi nominal ICR — the fee-only debt change means
    /// the trove's current nicr is a fine approximation.
    function refiStep(
        address up,
        address lo
    ) external onlyOwner nonReentrant {
        uint256 beforeCap = troveManager.getTroveMaxBorrowingCapacity(
            address(this)
        );
        borrowerOperations.refinance(up, lo);
        emit CapacityRefreshed(beforeCap);
    }

    function _loopToTarget(uint8 maxIters) internal {
        if (maxIters > MAX_ITERS) maxIters = MAX_ITERS;
        uint256 feeRate = borrowerOperations.borrowingRate();
        uint8 refis;
        for (uint8 i; i < maxIters; ++i) {
            (uint256 coll, uint256 debt, uint256 icr, uint8 status) = trove();
            if (status != 1) revert NoTrove();
            if (icr > targetICR) {
                uint256 collUsd = (coll * _price()) / PRECISION;
                // MUSD enforces ICR >= MCR at borrow time — collateral from
                // the swap hasn't landed yet — so each step borrows at most
                // what keeps post-borrow ICR >= unwindFloorICR. Converges
                // geometrically: headroom shrinks as ICR approaches target.
                uint256 dTarget = _borrowToReachTarget(collUsd, debt);
                uint256 dCap = _borrowHeadroom(collUsd, debt, feeRate);
                uint256 d = dTarget < dCap ? dTarget : dCap;
                // MUSD also caps each trove's lifetime debt at
                // getTroveMaxBorrowingCapacity — snapshotted at openTrove
                // (coll*price/110%), lowered on collateral withdrawals, and
                // NOT raised by addColl. refinance() recomputes it from the
                // trove's CURRENT collateral, the protocol-sanctioned way to
                // unlock headroom as swapped collateral lands.
                uint256 maxCap = troveManager.getTroveMaxBorrowingCapacity(
                    address(this)
                );
                uint256 dProto = maxCap > debt
                    ? ((maxCap - debt) * PRECISION) / (PRECISION + feeRate)
                    : 0;
                if (dProto < d && refis < MAX_REFIS) {
                    (address up, address lo) = _hints();
                    try borrowerOperations.refinance(up, lo) {
                        ++refis;
                        emit CapacityRefreshed(maxCap);
                        continue;
                    } catch {}
                }
                if (d > dProto) d = dProto;
                if (d < MIN_LOOP_BORROW) break;
                _borrow(d);
                _swapAndTopUp(d);
            } else {
                if (!_deleverStep(targetICR, false)) break;
            }
        }
    }

    /**
     * @notice Fully unwind: bounded delever -> repay dust -> closeTrove.
     * Afterwards the vault holds plain BTC and exits pay out pro-rata.
     * Idempotent — safe to call again to finish a residual unwind.
     */
    function closeAll(uint8 maxIters) external onlyOwner nonReentrant {
        if (maxIters > MAX_ITERS) maxIters = MAX_ITERS;
        for (uint8 i; i < maxIters; ++i) {
            (, uint256 d0, , uint8 s0) = trove();
            if (s0 != 1 || d0 == 0) break;
            if (!_deleverStep(unwindFloorICR, true)) break;
        }

        (, uint256 debt, , uint8 status) = trove();
        if (status == 1 && debt > 0) {
            // Last mile: repay from vault-held MUSD dust, else buy just
            // enough MUSD with a small collateral slice.
            uint256 bal = musd.balanceOf(address(this));
            if (bal > 0) {
                (address up, address lo) = _hints();
                borrowerOperations.repayMUSD(bal < debt ? bal : debt, up, lo);
            }
            (, uint256 debtNow, , ) = trove();
            if (debtNow > 0 && debtNow < MIN_LOOP_BORROW) {
                uint256 step = _withdrawable();
                uint256 wantBtc = (debtNow *
                    PRECISION *
                    (BPS + 2 * maxSlippageBps)) / (_price() * BPS);
                if (step > wantBtc) step = wantBtc;
                if (step > 0) {
                    (address up2, address lo2) = _hints();
                    borrowerOperations.withdrawColl(step, up2, lo2);
                    uint256 minOut = (swapAdapter.quoteBtcToMusd(step) *
                        (BPS - maxSlippageBps)) / BPS;
                    uint256 musdOut = swapAdapter.swapBtcForMusd{
                        value: step
                    }(minOut, address(this));
                    (, uint256 liveDebt, , ) = trove();
                    borrowerOperations.repayMUSD(
                        musdOut < liveDebt ? musdOut : liveDebt,
                        up2,
                        lo2
                    );
                }
            }
        }
        (, uint256 debtAfter, , uint8 statusAfter) = trove();
        if (statusAfter == 1 && debtAfter == 0) {
            borrowerOperations.closeTrove();
        }
        emit AllClosed(debtAfter, address(this).balance);
    }

    /// @notice Recover collateral surplus after redemptions/liquidations.
    function claimCollateralSurplus() external nonReentrant {
        borrowerOperations.claimCollateral();
    }

    // ------------------------------------------------------------------
    //  Admin
    // ------------------------------------------------------------------

    function setSwapAdapter(address adapter) external onlyOwner {
        _setSwapAdapter(adapter);
    }

    function setTargetICR(uint256 icr) external onlyOwner {
        if (icr < MIN_TARGET_ICR || icr > MAX_TARGET_ICR) revert BadTarget();
        targetICR = icr;
        emit TargetICRSet(icr);
    }

    function setMaxSlippageBps(uint16 bps) external onlyOwner {
        require(bps <= 2000, "slippage too high");
        maxSlippageBps = bps;
    }

    function setUnwindFloorICR(uint256 icr) external onlyOwner {
        require(icr >= 1.05e18 && icr < targetICR, "bad floor");
        unwindFloorICR = icr;
    }

    function setPaused(bool p) external onlyOwner {
        paused = p;
    }

    /// @notice Rescue stray tokens. MUSD is excluded: vault-held MUSD is
    /// earmarked for debt repayment.
    function rescue(address token, address to, uint256 amount) external onlyOwner {
        require(token != address(musd), "no musd rescue");
        IERC20(token).transfer(to, amount);
    }

    // ------------------------------------------------------------------
    //  Internals
    // ------------------------------------------------------------------

    /// @dev One delever step toward `goalICR` — or toward zero debt when
    /// `repayAll` is set (full unwind). Withdraws as much collateral as the
    /// floor allows, swaps it for MUSD, and repays. Returns false when it
    /// cannot safely make progress (goal reached, or floor blocks further
    /// withdrawal — in that regime only externally-supplied MUSD can help).
    function _deleverStep(
        uint256 goalICR,
        bool repayAll
    ) internal returns (bool) {
        (uint256 coll, uint256 debt, , ) = trove();
        uint256 price = _price();
        uint256 collUsd = (coll * price) / PRECISION;

        uint256 repayWanted;
        if (repayAll) {
            repayWanted = debt;
        } else {
            // m = (r*debt - collUsd)/(r - 1) MUSD to repay to reach goal
            uint256 goalDebtUsd = (goalICR * debt) / PRECISION;
            if (collUsd >= goalDebtUsd) return false;
            repayWanted = ((goalDebtUsd - collUsd) * PRECISION) /
                (goalICR - PRECISION);
            // Overshoot by slippage so swap fees don't stall convergence.
            repayWanted = (repayWanted * (BPS + maxSlippageBps)) / BPS;
            if (repayWanted > debt) repayWanted = debt;
        }
        if (repayWanted == 0) return false;

        uint256 step = _withdrawable();
        uint256 wantBtc = (repayWanted * PRECISION * (BPS + maxSlippageBps)) /
            (price * BPS);
        if (step > wantBtc) step = wantBtc;
        if (step == 0) return false;

        (address up, address lo) = _hints();
        borrowerOperations.withdrawColl(step, up, lo);
        // Per-swap floor from the adapter's quote, not the oracle.
        uint256 minOut = (swapAdapter.quoteBtcToMusd(step) *
            (BPS - maxSlippageBps)) / BPS;
        uint256 musdOut = swapAdapter.swapBtcForMusd{value: step}(
            minOut,
            address(this)
        );
        (, uint256 liveDebt, , ) = trove();
        uint256 pay = musdOut < liveDebt ? musdOut : liveDebt;
        borrowerOperations.repayMUSD(pay, up, lo);
        emit Delevered(step, pay, _currentICR());
        return true;
    }

    /// @dev BTC the trove can release right now without dropping below
    /// unwindFloorICR (a margin above MUSD's ~110% MCR).
    function _withdrawable() internal view returns (uint256) {
        (uint256 coll, uint256 debt, , ) = trove();
        if (debt == 0) return coll;
        uint256 price = _price();
        uint256 collUsd = (coll * price) / PRECISION;
        uint256 floorUsd = (unwindFloorICR * debt) / PRECISION;
        if (collUsd <= floorUsd) return 0;
        uint256 btc = ((collUsd - floorUsd) * PRECISION) / price;
        return btc > coll ? coll : btc;
    }

    function _borrow(uint256 d) internal {
        (address up, address lo) = _hints();
        borrowerOperations.withdrawMUSD(d, up, lo);
    }

    /// @dev Swap vault-held MUSD to BTC and re-deposit as collateral.
    /// minOut derives from the adapter's own quote (real pool price), not
    /// the oracle — pools can sit a few % off oracle.
    function _swapAndTopUp(uint256 musdAmount) internal {
        uint256 minOut = (swapAdapter.quoteMusdToBtc(musdAmount) *
            (BPS - maxSlippageBps)) / BPS;
        uint256 btcOut = swapAdapter.swapMusdForBtc(
            musdAmount,
            minOut,
            payable(address(this))
        );
        (address up, address lo) = _hints();
        borrowerOperations.addColl{value: btcOut}(up, lo);
        emit Levered(musdAmount, btcOut, _currentICR());
    }

    /// @dev Borrow size that lands ICR exactly on target post-redeposit:
    /// collUsd + d = r*(debt + d)  =>  d = (collUsd - r*debt) / (r - 1)
    function _borrowToReachTarget(
        uint256 collUsd,
        uint256 debt
    ) internal view returns (uint256 d) {
        uint256 targetDebtUsd = (targetICR * debt) / PRECISION;
        if (collUsd <= targetDebtUsd) return 0;
        d = ((collUsd - targetDebtUsd) * PRECISION) / (targetICR - PRECISION);
    }

    /// @dev Max borrow that keeps post-borrow ICR >= unwindFloorICR,
    /// accounting for the protocol's borrowing fee (debt += d*(1+fee)):
    ///   debt + d(1+f) <= collUsd/floor
    ///   => d <= (collUsd - floor*debt) / (floor*(1+f))
    function _borrowHeadroom(
        uint256 collUsd,
        uint256 debt,
        uint256 feeRate
    ) internal view returns (uint256) {
        uint256 floorUsd = (unwindFloorICR * debt) / PRECISION;
        if (collUsd <= floorUsd) return 0;
        return
            ((collUsd - floorUsd) * PRECISION * PRECISION) /
            (unwindFloorICR * (PRECISION + feeRate));
    }

    /// @dev SortedTroves insertion hints, resolved fully on-chain.
    /// Canonical Liquity pattern: pass getApproxHint(nicr) as BOTH prev and
    /// next id; SortedTroves walks to the exact slot from there.
    function _hints() internal view returns (address up, address lo) {
        uint256 nicr = troveManager.getNominalICR(address(this));
        if (nicr == 0) nicr = type(uint256).max;
        (address hint, , ) = hintHelpers.getApproxHint(
            nicr,
            hintTrials,
            uint256(uint160(address(this))) ^ block.number
        );
        return (hint, hint);
    }

    function _price() internal view returns (uint256) {
        return priceFeed.fetchPrice();
    }

    function _currentICR() internal view returns (uint256) {
        (, , uint256 icr, ) = trove();
        return icr;
    }

    function _musdToBtc(uint256 musdAmount) internal view returns (uint256) {
        return (musdAmount * PRECISION) / _price();
    }

    function _sendBtc(address to, uint256 amount) internal {
        if (amount == 0) revert NothingToWithdraw();
        (bool ok, ) = payable(to).call{value: amount}("");
        require(ok, "BTC send failed");
    }

    function _setSwapAdapter(address adapter) internal {
        if (address(swapAdapter) != address(0)) {
            musd.approve(address(swapAdapter), 0);
        }
        swapAdapter = ISwapAdapter(adapter);
        musd.approve(adapter, type(uint256).max);
        emit SwapAdapterSet(adapter);
    }
}
