// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./IGCPI.sol";
import "./CopraTokenV2.sol";
import "../gcpi/GCPITypes.sol";

/**
 * @title CopraManagerV2
 * @author Copra Protocol (https://copra.dev)
 * @notice COPRA-001 §5, §8, §9, §11, §12: overcollateralized positions, forward-priced
 *         redemption, liquidation and bad-debt redistribution. No owner, no upgrade path, no
 *         pause, no setter: every parameter is immutable, and the $COPRA token is deployed
 *         from this constructor so the wiring is atomic. State-changing functions:
 *         open, deposit, mint, repay, withdraw, close, liquidate, requestRedeem, settle,
 *         cancel, claimFees, syncPosition (pinned by test_TrustAssumption_*).
 *
 * @dev Accumulator design. Redemption takes debt in proportion to debt and collateral in
 *      proportion to collateral, so every position covers its share by construction —
 *      including in shortfall, where debt-proportional collateral takes can exceed an
 *      underwater position's collateral with no O(1) way to find the deficit. #96 measured
 *      the two rules as economically equivalent and named this one the tested-equivalent
 *      alternative; implementability promotes it here (see the #97 PR).
 *
 *      Per position (rebased to the current epoch on every touch):
 *        debt = (debtBase + collBase * (redist - redistSnapshot) / 1e18) * debtScale / 1e18
 *        collateral = collBase * collScale / 1e18
 *      settle() scales debtScale by (D-A)/D and collScale by (C-paid)/C; liquidation moves
 *      bad debt B by adding B*collScale/(C*debtScale) to redist, which attributes B*c/C
 *      to each position. All three updates are O(1) and exact up to dust (§3 rounding
 *      rule): debt balances round down so positions stay repayable, collateral and
 *      payouts round down so dust favors the system.
 *
 *      A settle that redeems the entire supply would zero debtScale and orphan every stored
 *      base, so it opens a new epoch instead: the old scales are saved, fresh ones start,
 *      and positions hop epochs lazily. syncPosition() advances anyone's position (bounded),
 *      and every mutating touch requires the current epoch. Full-supply redemption is
 *      vanishingly rare; the machinery is documented, not expected, to run.
 */
contract CopraManagerV2 is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /// @notice Collateral token (USDC on every deployment); any ERC-20 the deployer wires.
    IERC20 public immutable collateralToken;
    /// @notice Collateral decimals (6 for USDC); at most 18.
    uint8 public immutable collateralDecimals;
    /// @notice The GCPI adapter bound at deployment (§4.1).
    IGCPI public immutable gcpi;
    /// @notice The $COPRA token, deployed by this constructor; only this manager mints/burns.
    CopraTokenV2 public immutable copraToken;
    /// @notice Immutable recipient of the protocol fee share (§10.4).
    address public immutable feeRecipient;

    /// @notice Minimum ratio after minting or withdrawing, in bps (25000 = 250%).
    uint256 public immutable mcrBps;
    /// @notice Liquidation threshold, in bps (16000 = 160%). Below MCR.
    uint256 public immutable lrBps;
    /// @notice Liquidator bonus, in bps of the repaid value (500 = 5%).
    uint256 public immutable liqBonusBps;
    /// @notice Smallest debt a mint or partial liquidation may leave (100e18 $COPRA).
    uint256 public immutable minDebt;
    /// @notice Oldest usable GCPI finalization (45 days).
    uint256 public immutable maxPriceAge;
    /// @notice Wait before a priceless redemption may cancel (183 days ≈ 6 periods).
    uint256 public immutable redeemExpiry;
    /// @notice Mint fee, in bps of the minted value, charged from collateral (50 = 0.5%).
    uint256 public immutable mintFeeBps;
    /// @notice Protocol share of the mint fee, in bps of the fee (5000 = 50%).
    uint256 public immutable mintFeeProtocolShareBps;
    /// @notice Redemption fee, in bps of gross, retained by positions (100 = 1%).
    uint256 public immutable redeemFeeBps;
    /// @notice Settler refund per settle() call, in collateral units, from the reserve.
    uint256 public immutable settleCap;

    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public constant SCALE = 1e18;
    /// @notice GCPI price decimals (COPRA-001 §3).
    uint256 public constant PRICE_DECIMALS = 8;
    /// @notice Most redemption ids per settle() call: grouping is quadratic, so it is capped.
    uint256 public constant MAX_SETTLE_IDS = 100;
    /// @notice Most periods any GCPI scan crosses: 256 months is past any plausible outage.
    uint256 public constant SCAN_CAP = 256;
    /// @notice Most epochs one syncPosition() folds; full-supply redemptions are that rare.
    uint256 public constant MAX_SYNC_EPOCHS = 32;

    /// @notice COPRA-001 §12, computed from the price input and positions on every call.
    enum ProtocolState {
        NORMAL,
        PRICE_UNAVAILABLE,
        SHORTFALL
    }

    struct Position {
        address owner;
        uint64 epoch;
        // Debt at last touch per unit debtScale, 1e18 (rounded up).
        uint256 debtBase;
        // Collateral at last touch per unit collScale, 1e18 (rounded down).
        uint256 collBase;
        // Redistributive accumulator at last touch, 1e18.
        uint256 redistSnapshot;
    }

    struct Redemption {
        address owner;
        uint256 amount;
        // Request period k: the GCPI period containing the request timestamp (§8.2).
        uint256 k;
        uint256 requestedAt;
        bool pending;
    }

    struct EpochEnd {
        uint256 debtScale;
        uint256 collScale;
        uint256 redist;
    }

    uint256 public nextPositionId;
    uint256 public nextRequestId;
    mapping(uint256 => Position) private _positions;
    mapping(uint256 => Redemption) private _requests;

    /// @notice Exact sum of position debt (Invariant 2: equals $COPRA totalSupply).
    uint256 public totalDebt;
    /// @notice Exact position collateral in the pool (Invariant 3, first pocket).
    uint256 public totalColl;
    /// @notice Exact unclaimed protocol fees in the pool (Invariant 3, second pocket).
    uint256 public protocolFees;
    /// @notice Exact settler-refund reserve in the pool (Invariant 3, third pocket).
    uint256 public settleReserve;

    uint256 public debtScale = SCALE;
    uint256 public collScale = SCALE;
    uint256 public redist;
    uint64 public epoch;
    mapping(uint64 => EpochEnd) public epochEnds;
    /// @notice Settlement haircut per period (§11.3, Invariant 7), pinned by the first
    ///         settle at that period so every redemption settling there shares one rate
    ///         no matter how settles are batched or ordered. Stored plus one; 0 = unset.
    mapping(uint256 => uint256) private _periodHaircut;

    event PositionOpened(uint256 indexed id, address indexed owner);
    event Deposited(uint256 indexed id, address indexed from, uint256 amount);
    event Minted(uint256 indexed id, address indexed owner, uint256 amount, uint256 fee);
    event Repaid(uint256 indexed id, address indexed payer, uint256 amount);
    event Withdrawn(uint256 indexed id, address indexed owner, uint256 amount);
    event PositionClosed(uint256 indexed id, address indexed owner);
    event PositionSynced(uint256 indexed id, uint64 fromEpoch, uint64 toEpoch);
    event Liquidated(uint256 indexed id, address indexed liquidator, uint256 repaid, uint256 seized, uint256 badDebt);
    event RedemptionRequested(uint256 indexed id, address indexed owner, uint256 amount, uint256 k);
    event RedemptionSettled(uint256 indexed id, address indexed owner, uint256 amount, uint256 period, uint256 payout);
    event RedemptionCancelled(uint256 indexed id, address indexed owner, uint256 amount);
    event FeesClaimed(address indexed recipient, uint256 amount);
    event SettlerRefunded(address indexed settler, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error InsufficientCollateral();
    error BadParams();
    error NotOwner();
    error NoUsablePrice();
    error InShortfall();
    error BelowMCR();
    error BelowMinDebt();
    error NoDebt();
    error NotLiquidatable();
    error CannotCover();
    error OverRepayment(uint256 amount, uint256 debt);
    error WorsensRatio();
    error RequestSettled();
    error NotSettleable();
    error MixedPeriods();
    error TooManyIds();
    error MustSettle();
    error NotExpired();
    error NothingToClaim();
    error NeedsSync();
    error ScaleUnderflow();

    constructor(
        address _collateral,
        uint8 _collateralDecimals,
        address _gcpi,
        address _feeRecipient,
        uint256 _mcrBps,
        uint256 _lrBps,
        uint256 _liqBonusBps,
        uint256 _minDebt,
        uint256 _maxPriceAge,
        uint256 _redeemExpiry,
        uint256 _mintFeeBps,
        uint256 _mintFeeProtocolShareBps,
        uint256 _redeemFeeBps,
        uint256 _settleCap
    ) {
        if (
            _collateral == address(0) || _gcpi == address(0) || _feeRecipient == address(0) || _collateralDecimals > 18
                || _minDebt == 0 || _maxPriceAge == 0 || _redeemExpiry == 0 || _settleCap == 0
        ) revert ZeroAddress();
        if (
            _mcrBps <= _lrBps || _lrBps <= BPS_DENOMINATOR || _liqBonusBps >= BPS_DENOMINATOR
                || _mintFeeBps >= BPS_DENOMINATOR || _mintFeeProtocolShareBps > BPS_DENOMINATOR || _redeemFeeBps == 0
                || _redeemFeeBps >= BPS_DENOMINATOR
        ) revert BadParams();
        collateralToken = IERC20(_collateral);
        collateralDecimals = _collateralDecimals;
        gcpi = IGCPI(_gcpi);
        feeRecipient = _feeRecipient;
        mcrBps = _mcrBps;
        lrBps = _lrBps;
        liqBonusBps = _liqBonusBps;
        minDebt = _minDebt;
        maxPriceAge = _maxPriceAge;
        redeemExpiry = _redeemExpiry;
        mintFeeBps = _mintFeeBps;
        mintFeeProtocolShareBps = _mintFeeProtocolShareBps;
        redeemFeeBps = _redeemFeeBps;
        settleCap = _settleCap;
        copraToken = new CopraTokenV2();
    }

    // ------------------------------------------------------------------------
    // Price input (§4) and protocol state (§12)
    // ------------------------------------------------------------------------

    /**
     * @notice The usable price: the latest finalized VALID price whose finalization is no
     *         older than MAX_PRICE_AGE (§4.2). Reads (false, 0, 0) without one; the protocol
     *         never substitutes a default or a value from any other source. Propagates
     *         IGCPI.ScanTooLong past SCAN_CAP periods without a VALID record (a dead index).
     */
    function usablePrice() public view returns (bool ok, uint256 price, uint256 finalizedAt) {
        (bool found,, uint256 p, uint256 f) = gcpi.latestValid(SCAN_CAP);
        if (!found) return (false, 0, 0);
        if (block.timestamp - f > maxPriceAge) return (false, 0, 0);
        return (true, p, f);
    }

    /// @notice COPRA-001 §12, from the price input and the system ratio at the usable price.
    ///         Shortfall is TCR < 100%: the debt value (rounded up) exceeds the collateral.
    function protocolState() public view returns (ProtocolState) {
        (bool ok, uint256 price,) = usablePrice();
        if (!ok) return ProtocolState.PRICE_UNAVAILABLE;
        if (_inShortfall(price)) return ProtocolState.SHORTFALL;
        return ProtocolState.NORMAL;
    }

    /// @dev Shortfall at `price`, for callers that already resolved the usable price.
    function _inShortfall(uint256 price) internal view returns (bool) {
        return totalDebt > 0 && _debtValueUp(totalDebt, price) > totalColl;
    }

    /**
     * @notice First finalized VALID period id at or after `from`, via the adapter's bounded
     *         scan. A manager-side view for keepers and tests; settle and cancel call the
     *         adapter directly so their stack stays small.
     */
    function firstValidAtOrAfter(uint256 from) public view returns (bool found, uint256 id, uint256 price) {
        return gcpi.firstValidAtOrAfter(from, SCAN_CAP);
    }

    // ------------------------------------------------------------------------
    // Fixed-point arithmetic (§3). Debt values in ratio checks round up; debt balances
    // in the scale accounting round down, so realized position debt never exceeds the
    // debt that exists and every position stays repayable. Collateral and payouts
    // round down. Fees round up, in the system's favor.
    // ------------------------------------------------------------------------

    /// @notice USD value of `debt` $COPRA at `price`, in collateral units, rounded up.
    function _debtValueUp(uint256 debt, uint256 price) internal view returns (uint256) {
        uint256 usd18 = Math.mulDiv(debt, price, 10 ** PRICE_DECIMALS, Math.Rounding.Ceil);
        return _toCollateralUp(usd18);
    }

    /// @notice USD value of `debt` $COPRA at `price`, in collateral units, rounded down.
    function _debtValueDown(uint256 debt, uint256 price) internal view returns (uint256) {
        uint256 usd18 = Math.mulDiv(debt, price, 10 ** PRICE_DECIMALS);
        return _toCollateralDown(usd18);
    }

    function _toCollateralUp(uint256 usd18) internal view returns (uint256) {
        if (collateralDecimals < 18) return Math.ceilDiv(usd18, 10 ** (18 - collateralDecimals));
        return usd18 * 10 ** (collateralDecimals - 18);
    }

    function _toCollateralDown(uint256 usd18) internal view returns (uint256) {
        if (collateralDecimals < 18) return usd18 / 10 ** (18 - collateralDecimals);
        return usd18 * 10 ** (collateralDecimals - 18);
    }

    /// @notice System ratio at `price`, 1e18 (100% = 1e18), rounded down. Infinite (type max)
    ///         with no debt.
    function _systemRatio(uint256 price) internal view returns (uint256) {
        if (totalDebt == 0) return type(uint256).max;
        uint256 debtVal = _debtValueUp(totalDebt, price);
        if (debtVal == 0) return type(uint256).max;
        return Math.mulDiv(totalColl, SCALE, debtVal);
    }

    // ------------------------------------------------------------------------
    // Positions (§5): realization, epochs, operations
    // ------------------------------------------------------------------------

    /**
     * @notice The position's current (collateral, debt), folding every epoch since its last
     *         touch. Debt rounds up, collateral down. Unbounded in epochs only past more
     *         full-supply redemptions than any caller will cross; mutating touches require
     *         the current epoch instead (see syncPosition).
     */
    function positionOf(uint256 id) public view returns (address owner, uint256 coll, uint256 debt) {
        Position storage p = _positions[id];
        (coll, debt) = _realize(p, epoch);
        owner = p.owner;
    }

    /// @dev Realizes `p` through the ends of every epoch before `toEpoch`, then the live scales.
    function _realize(Position storage p, uint64 toEpoch) internal view returns (uint256 coll, uint256 debt) {
        uint256 dBase = p.debtBase;
        uint256 cBase = p.collBase;
        uint256 snap = p.redistSnapshot;
        uint64 e = p.epoch;
        while (e < toEpoch) {
            (dBase, cBase, snap) = _foldEpoch(dBase, cBase, snap, e);
            unchecked {
                ++e;
            }
        }
        coll = Math.mulDiv(cBase, collScale, SCALE);
        debt = Math.mulDiv(dBase + Math.mulDiv(cBase, redist - snap, SCALE), debtScale, SCALE);
    }

    /// @dev One epoch hop: balances at the end of epoch `e`, rebased onto fresh scales.
    function _foldEpoch(uint256 dBase, uint256 cBase, uint256 snap, uint64 e)
        internal
        view
        returns (uint256 dBaseNext, uint256 cBaseNext, uint256 snapNext)
    {
        EpochEnd storage end = epochEnds[e];
        cBaseNext = Math.mulDiv(cBase, end.collScale, SCALE);
        dBaseNext = Math.mulDiv(dBase + Math.mulDiv(cBase, end.redist - snap, SCALE), end.debtScale, SCALE);
        snapNext = 0;
    }

    /**
     * @notice Advances `id` toward the current epoch, at most MAX_SYNC_EPOCHS per call, so no
     *         call does unbounded work. Permissionless: syncing only rebases the accounting to
     *         identical balances. Every mutating touch requires the current epoch first.
     */
    function syncPosition(uint256 id) external nonReentrant {
        Position storage p = _positions[id];
        uint64 e = p.epoch;
        uint64 target = epoch;
        uint256 hops;
        uint256 dBase = p.debtBase;
        uint256 cBase = p.collBase;
        uint256 snap = p.redistSnapshot;
        while (e < target && hops < MAX_SYNC_EPOCHS) {
            (dBase, cBase, snap) = _foldEpoch(dBase, cBase, snap, e);
            unchecked {
                ++e;
                ++hops;
            }
        }
        p.debtBase = dBase;
        p.collBase = cBase;
        p.redistSnapshot = snap;
        emit PositionSynced(id, p.epoch, e);
        p.epoch = e;
    }

    /// @dev Realizes a current-epoch position. Reverts NeedsSync otherwise.
    function _current(uint256 id) internal view returns (Position storage p, uint256 coll, uint256 debt) {
        p = _positions[id];
        if (p.epoch != epoch) revert NeedsSync();
        coll = Math.mulDiv(p.collBase, collScale, SCALE);
        debt = Math.mulDiv(p.debtBase + Math.mulDiv(p.collBase, redist - p.redistSnapshot, SCALE), debtScale, SCALE);
    }

    /// @dev Rebases `p` onto the live scales at balances (`coll`, `debt`).
    function _rebase(Position storage p, uint256 coll, uint256 debt) internal {
        p.collBase = Math.mulDiv(coll, SCALE, collScale);
        p.debtBase = Math.mulDiv(debt, SCALE, debtScale);
        p.redistSnapshot = redist;
        p.epoch = epoch;
    }

    /// @notice Opens a position owned by the caller. Always available (§5.3).
    function open() external nonReentrant returns (uint256 id) {
        id = nextPositionId++;
        Position storage p = _positions[id];
        p.owner = msg.sender;
        p.epoch = epoch;
        p.redistSnapshot = redist;
        emit PositionOpened(id, msg.sender);
    }

    /// @notice Adds collateral to any position, from anyone, in every state (§5.3).
    function deposit(uint256 id, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        (Position storage p, uint256 coll, uint256 debt) = _current(id);
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        totalColl += amount;
        _rebase(p, coll + amount, debt);
        emit Deposited(id, msg.sender, amount);
    }

    /**
     * @notice Mints `amount` $COPRA to the owner against position `id`, charging the mint fee
     *         from its collateral (§5.3, §10.1). Owner only; needs a usable price, no shortfall,
     *         MIN_DEBT after, and MCR after.
     */
    function mint(uint256 id, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        (bool ok, uint256 price,) = usablePrice();
        if (!ok) revert NoUsablePrice();
        if (_inShortfall(price)) revert InShortfall();
        (Position storage p, uint256 coll, uint256 debt) = _current(id);
        if (msg.sender != p.owner) revert NotOwner();
        uint256 newDebt = debt + amount;
        if (newDebt < minDebt) revert BelowMinDebt();
        uint256 fee = Math.mulDiv(_debtValueUp(amount, price), mintFeeBps, BPS_DENOMINATOR, Math.Rounding.Ceil);
        if (fee > coll) revert InsufficientCollateral();
        uint256 collAfter = coll - fee;
        if (collAfter * BPS_DENOMINATOR < mcrBps * _debtValueUp(newDebt, price)) revert BelowMCR();
        uint256 protocolShare = (fee * mintFeeProtocolShareBps) / BPS_DENOMINATOR;
        protocolFees += protocolShare;
        settleReserve += fee - protocolShare;
        totalColl -= fee;
        totalDebt += amount;
        copraToken.mint(p.owner, amount);
        _rebase(p, collAfter, newDebt);
        emit Minted(id, p.owner, amount, fee);
    }

    /**
     * @notice Burns `amount` $COPRA from the caller and reduces position `id` by it. Anyone
     *         may repay any position, in every state, with no price (§5.3). Reverts past the
     *         position's debt rather than silently under-repaying.
     */
    function repay(uint256 id, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        (Position storage p, uint256 coll, uint256 debt) = _current(id);
        if (amount > debt) revert OverRepayment(amount, debt);
        copraToken.burnFromManager(msg.sender, amount);
        totalDebt -= amount;
        _rebase(p, coll, debt - amount);
        emit Repaid(id, msg.sender, amount);
    }

    /**
     * @notice Sends `amount` collateral to the owner. Owner only. Debt-free positions withdraw
     *         in every state with no price; positions with debt need a usable price, no
     *         shortfall, and MCR after (§5.3).
     */
    function withdraw(uint256 id, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        (Position storage p, uint256 coll, uint256 debt) = _current(id);
        if (msg.sender != p.owner) revert NotOwner();
        if (amount > coll) revert InsufficientCollateral();
        if (debt > 0) {
            (bool ok, uint256 price,) = usablePrice();
            if (!ok) revert NoUsablePrice();
            if (_inShortfall(price)) revert InShortfall();
            if ((coll - amount) * BPS_DENOMINATOR < mcrBps * _debtValueUp(debt, price)) {
                revert BelowMCR();
            }
        }
        totalColl -= amount;
        collateralToken.safeTransfer(p.owner, amount);
        _rebase(p, coll - amount, debt);
        emit Withdrawn(id, p.owner, amount);
    }

    /**
     * @notice Repays all of position `id` from the caller and withdraws all collateral to the
     *         owner: repay then debt-free withdraw, hence available in every state (§5.3).
     *         The caller must hold the position's debt in $COPRA.
     */
    function close(uint256 id) external nonReentrant {
        (Position storage p, uint256 coll, uint256 debt) = _current(id);
        if (msg.sender != p.owner) revert NotOwner();
        address owner = p.owner;
        if (debt > 0) {
            copraToken.burnFromManager(msg.sender, debt);
            totalDebt -= debt;
            emit Repaid(id, msg.sender, debt);
        }
        if (coll > 0) {
            totalColl -= coll;
            collateralToken.safeTransfer(p.owner, coll);
            emit Withdrawn(id, p.owner, coll);
        }
        delete _positions[id];
        emit PositionClosed(id, owner);
    }

    // ------------------------------------------------------------------------
    // Liquidation (§9, §11.1)
    // ------------------------------------------------------------------------

    /**
     * @notice The terms of liquidating `id` with `repayAmount` ($COPRA, type max for full) at
     *         the usable price: debt repaid x, collateral seized, and bad debt (0 unless the
     *         collateral cannot cover x with the bonus). For keepers and tests.
     */
    function quoteLiquidate(uint256 id, uint256 repayAmount)
        external
        view
        returns (uint256 x, uint256 seized, uint256 bad)
    {
        (bool ok, uint256 price,) = usablePrice();
        if (!ok) revert NoUsablePrice();
        (, uint256 coll, uint256 debt) = positionOf(id);
        if (debt == 0) revert NoDebt();
        x = repayAmount >= debt ? debt : repayAmount;
        (x, seized, bad) = _liquidationTerms(coll, debt, x, price);
    }

    /// @dev (repaid, seized, bad debt) for repaying `x` of a (`coll`, `debt`) position:
    ///      covered with the bonus, seized with it; a full repayment that covers the debt but
    ///      not the bonus seizes all collateral with no bad debt (§9.2 min); a full repayment
    ///      below the debt value repays only what the collateral covers (§11.1); a partial
    ///      repayment that misses the bonus cannot cover and reverts.
    function _liquidationTerms(uint256 coll, uint256 debt, uint256 x, uint256 price)
        internal
        view
        returns (uint256, uint256 seized, uint256 bad)
    {
        uint256 full = Math.mulDiv(_debtValueDown(x, price), BPS_DENOMINATOR + liqBonusBps, BPS_DENOMINATOR);
        if (full <= coll) return (x, full, 0);
        if (x < debt) revert CannotCover();
        if (coll * 1e26 >= debt * price * 10 ** collateralDecimals) return (x, coll, 0);
        uint256 repayValue = Math.mulDiv(coll, BPS_DENOMINATOR, BPS_DENOMINATOR + liqBonusBps);
        x = _fromCollateralUp(repayValue, price);
        return (x, coll, debt - x);
    }

    /// @notice Debt $COPRA worth `collValue` collateral at `price`, rounded up.
    function _fromCollateralUp(uint256 collValue, uint256 price) internal view returns (uint256) {
        uint256 usd18 = collValue * 10 ** (18 - collateralDecimals);
        return Math.mulDiv(usd18, 10 ** PRICE_DECIMALS, price, Math.Rounding.Ceil);
    }

    /**
     * @notice Repays `repayAmount` of position `id` with the caller's $COPRA (type max for
     *         all of it) and takes the collateral with the bonus. Anyone may liquidate a
     *         position below LR at the usable price; no liquidation without one (§9). A partial
     *         liquidation must leave zero debt or at least MIN_DEBT, and must not lower the
     *         ratio (exact cross-multiplication, no rounding). Bad debt redistributes over
     *         collateral (§11.1), or stays on the husk when no collateral exists anywhere.
     */
    function liquidate(uint256 id, uint256 repayAmount) external nonReentrant {
        (bool ok, uint256 price,) = usablePrice();
        if (!ok) revert NoUsablePrice();
        (Position storage p, uint256 coll, uint256 debt) = _current(id);
        if (debt == 0) revert NoDebt();
        if (coll * BPS_DENOMINATOR >= lrBps * _debtValueUp(debt, price)) revert NotLiquidatable();
        uint256 x = repayAmount >= debt ? debt : repayAmount;
        if (x == 0) revert ZeroAmount();
        uint256 seized;
        uint256 bad;
        (x, seized, bad) = _liquidationTerms(coll, debt, x, price);
        if (x > 0) copraToken.burnFromManager(msg.sender, x);
        totalDebt -= x;
        totalColl -= seized;
        if (seized > 0) collateralToken.safeTransfer(msg.sender, seized);
        if (bad > 0) {
            if (totalColl > 0) {
                // Attribute B*c/C to each position, rounding down (§3): the dust stays
                // in totalDebt and remains redeemable.
                redist += Math.mulDiv(Math.mulDiv(bad, collScale, totalColl), SCALE, debtScale);
                delete _positions[id];
            } else {
                // With no collateral anywhere the husk keeps its debt: repayable, and
                // liquidatable again once collateral exists. Invariant 2 stays exact.
                _rebase(p, 0, bad);
            }
        } else {
            uint256 debtAfter = debt - x;
            if (debtAfter > 0) {
                if (debtAfter < minDebt) revert BelowMinDebt();
                if ((coll - seized) * debt < coll * debtAfter) revert WorsensRatio();
            }
            _rebase(p, coll - seized, debtAfter);
        }
        emit Liquidated(id, msg.sender, x, seized, bad);
    }

    // ------------------------------------------------------------------------
    // Forward-priced redemption (§8)
    // ------------------------------------------------------------------------

    /**
     * @notice Escrows `amount` $COPRA for redemption. Records the request in period k, the
     *         GCPI period containing this block (§8.2); it settles at the first VALID period
     *         s ≥ k+1. Allowed in every state, with no price (§12).
     */
    function requestRedeem(uint256 amount) external nonReentrant returns (uint256 id) {
        if (amount == 0) revert ZeroAmount();
        copraToken.transferFrom(msg.sender, address(this), amount);
        id = nextRequestId++;
        _requests[id] = Redemption(msg.sender, amount, gcpi.periodOf(block.timestamp), block.timestamp, true);
        emit RedemptionRequested(id, msg.sender, amount, _requests[id].k);
    }

    /// @notice A redemption request and, when one exists, its settlement period and price.
    function requestOf(uint256 id)
        external
        view
        returns (address owner, uint256 amount, uint256 k, uint256 requestedAt, bool pending)
    {
        Redemption storage r = _requests[id];
        return (r.owner, r.amount, r.k, r.requestedAt, r.pending);
    }

    /**
     * @notice Whether `id` can settle now, and at which period and price. For keepers: the
     *         request settles at the first finalized VALID period s ≥ k+1 (§8.2).
     */
    function settleable(uint256 id) external view returns (bool ok, uint256 s, uint256 price) {
        Redemption storage r = _requests[id];
        if (!r.pending) return (false, 0, 0);
        return gcpi.firstValidAtOrAfter(r.k + 1, SCAN_CAP);
    }

    /**
     * @notice Settles pending requests that all share one settlement period s: each request's
     *         first VALID period at or after k+1 (§8.2), resolved per request and required
     *         equal, so every requester in the batch provably receives the same price
     *         (§8.2.4, Invariant 7) with no dependence on input order. Requests settling at
     *         different periods settle in separate calls; keepers group by settleable(). Anyone
     *         may settle anyone's requests; payouts go to the requesters. In shortfall every
     *         requester takes the same pro-rata haircut (§11.3). The caller is refunded up to
     *         SETTLE_CAP from the reserve (§10.2); an empty reserve settles unreimbursed.
     */
    function settle(uint256[] calldata ids) external nonReentrant {
        uint256 n = ids.length;
        if (n == 0 || n > MAX_SETTLE_IDS) revert TooManyIds();
        // Pass 1: every id pending and settleable at one shared s; mark spent up front, which
        // also rejects duplicate ids (the second sighting is already spent).
        uint256 s;
        uint256 price;
        uint256 amount;
        for (uint256 i; i < n; ++i) {
            Redemption storage r = _requests[ids[i]];
            if (!r.pending) revert NotSettleable();
            (bool found, uint256 si, uint256 pi) = gcpi.firstValidAtOrAfter(r.k + 1, SCAN_CAP);
            if (!found) revert NotSettleable();
            if (i == 0) {
                (s, price) = (si, pi);
            } else if (si != s) {
                revert MixedPeriods();
            }
            amount += r.amount;
            r.pending = false;
        }
        // Pass 2: one atomic update — burn escrow, shrink the scales, pay floored shares.
        uint256 payout = _burnForGroup(amount, price, s);
        uint256 paid;
        for (uint256 i; i < n; ++i) {
            uint256 requestAmount = _requests[ids[i]].amount;
            uint256 share = Math.mulDiv(requestAmount, payout, amount);
            paid += share;
            address owner = _requests[ids[i]].owner;
            if (share > 0) collateralToken.safeTransfer(owner, share);
            emit RedemptionSettled(ids[i], owner, requestAmount, s, share);
        }
        // A zero payout moves nothing; skipping the ratio update also avoids a
        // division by zero when the pool holds no collateral, so redemptions of
        // worthless debt still settle (burning escrow for zero) instead of sticking.
        if (paid > 0) {
            totalColl -= paid;
            collScale = Math.mulDiv(collScale, totalColl, totalColl + paid);
        }
        if (totalDebt == 0) {
            // Full-supply redemption: the epoch ends with debt scale exactly 0 (every
            // unit of debt was redeemed) and the post-payout collateral scale, so lazy
            // survivors fold to zero debt and their haircut share of any leftover. A
            // zero recorded collateral scale is exact here, not precision loss.
            epochEnds[epoch] = EpochEnd(0, collScale, redist);
            unchecked {
                ++epoch;
            }
            debtScale = SCALE;
            collScale = SCALE;
            redist = 0;
        } else {
            if (collScale == 0) revert ScaleUnderflow();
            // Rounds down (§3): debt removed from positions rounds down, so position
            // debt never exceeds the debt that exists and every position stays
            // repayable and closeable. Rounding up here would strand unrepayable dust.
            debtScale = Math.mulDiv(debtScale, totalDebt, totalDebt + amount);
        }
        uint256 refund = settleCap < settleReserve ? settleCap : settleReserve;
        if (refund > 0) {
            settleReserve -= refund;
            collateralToken.safeTransfer(msg.sender, refund);
            emit SettlerRefunded(msg.sender, refund);
        }
    }

    /// @dev Burns the batch's escrow, reduces total debt, and returns the batch's total
    ///      payout after haircut and fee. Scale and epoch updates happen in the caller
    ///      after the payout is applied, so a full-supply redemption records the true
    ///      terminal scales (debt exactly 0, post-payout collateral).
    function _burnForGroup(uint256 amount, uint256 price, uint256 s) internal returns (uint256 payout) {
        uint256 haircut = _haircutForPeriod(s, price);
        uint256 gross = Math.mulDiv(_debtValueDown(amount, price), haircut, SCALE);
        uint256 fee = Math.mulDiv(gross, redeemFeeBps, BPS_DENOMINATOR, Math.Rounding.Ceil);
        payout = gross - fee;
        copraToken.burnFromManager(address(this), amount);
        totalDebt -= amount;
    }

    /// @dev The settlement haircut for period `s`: the live system ratio (capped at
    ///      par), pinned on first use so later settles at `s` share the rate.
    function _haircutForPeriod(uint256 s, uint256 price) internal returns (uint256) {
        uint256 pinned = _periodHaircut[s];
        if (pinned != 0) return pinned - 1;
        uint256 haircut = _systemRatio(price);
        if (haircut > SCALE) haircut = SCALE;
        _periodHaircut[s] = haircut + 1;
        return haircut;
    }

    /**
     * @notice Returns the escrowed $COPRA when no VALID period at or after k+1 finalized
     *         within REDEEM_EXPIRY of the request (§8.4). Requester only. Past expiry with a
     *         settlement price in existence the request must settle instead — cancelling
     *         would be a free option against minters. Past SCAN_CAP finalized periods
     *         without a VALID record the scan reverts (a dead index); the escrow waits
     *         for a reachable settlement period rather than cancelling against one.
     */
    function cancel(uint256 id) external nonReentrant {
        Redemption storage r = _requests[id];
        if (!r.pending) revert RequestSettled();
        if (msg.sender != r.owner) revert NotOwner();
        (bool found,,) = gcpi.firstValidAtOrAfter(r.k + 1, SCAN_CAP);
        if (found) revert MustSettle();
        if (block.timestamp < r.requestedAt + redeemExpiry) revert NotExpired();
        r.pending = false;
        copraToken.transfer(r.owner, r.amount);
        emit RedemptionCancelled(id, r.owner, r.amount);
    }

    /**
     * @notice Sends accumulated protocol fees to the immutable recipient. Permissionless to
     *         trigger; the destination is fixed (§10.1, §10.4).
     */
    function claimFees() external nonReentrant {
        uint256 fees = protocolFees;
        if (fees == 0) revert NothingToClaim();
        protocolFees = 0;
        collateralToken.safeTransfer(feeRecipient, fees);
        emit FeesClaimed(feeRecipient, fees);
    }

    /// @notice Epochs `id` still lags; 0 means every mutating touch is available.
    ///         Reads 0 for unknown or deleted positions, which need no sync.
    function epochsBehind(uint256 id) external view returns (uint64) {
        if (_positions[id].owner == address(0)) return 0;
        return epoch - _positions[id].epoch;
    }
}
