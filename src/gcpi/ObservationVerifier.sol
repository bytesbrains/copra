// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./GCPIMath.sol";
import "./GCPITypes.sol";

/**
 * @title ObservationVerifier
 * @author Copra Protocol (https://copra.dev)
 * @notice GCPI-001 §11.1 and §5.3–§5.4: accepts an observation when at least `threshold` of the notaries fixed
 *         at deployment attest to it, and keeps it for GCPIEngine. Anyone may submit. Nothing here can be
 *         changed after deployment: there is no owner, and the notary list, the threshold, the series, the
 *         windows and the bonds are all set in the constructor. A new list means a new methodology version and
 *         a new deployment (§13).
 *
 *         What an attestation is: a notary's EIP-712 signature over the observation's commitment
 *         (gcpi/ENGINE.md §7), bound to this contract and chain. A notary signs after it took part in the TLS
 *         session that retrieved the value (§5.3.1), so the signature is its claim about what the source served.
 *         Stake never counts toward accepting a value (§5.4): a signature counts or it does not.
 *
 *         Disputes need no vote (§5.3.2). Two attested observations of one market and period that disagree are
 *         both kept, and the engine makes that market DISPUTED for the period.
 */
contract ObservationVerifier is EIP712, ReentrancyGuard {
    /// @notice What GCPIEngine reads back: the observation and who bonded it.
    struct Stored {
        Observation observation;
        uint32 series;
        uint32 period;
        address submitter;
        bool refunded;
    }

    struct Notary {
        bool listed;
        bool bonded;
        bool slashed;
        uint64 unbondingAt; // 0 while bonded and counting
    }

    bytes32 private constant ATTESTATION_TYPEHASH = keccak256("Attestation(bytes32 commitment)");

    /// @notice §5.3.3: after the publication-lag window, three more days to bring a counter-attestation.
    uint256 public constant CHALLENGE_WINDOW = 3 days;
    /// @notice Bounds the work of one finalization. Each extra observation needs `threshold` notaries.
    uint256 public constant MAX_OBSERVATIONS = 16;

    uint256 public immutable firstPeriod;
    uint256 public immutable maxPublicationLagDays;
    uint256 public immutable threshold;
    uint256 public immutable submitBond;
    uint256 public immutable notaryBond;
    uint256 public immutable unbondingDelay;

    string[] private _series;
    mapping(bytes32 => uint256) private _seriesIndex; // keccak(name) => index + 1
    address[] private _notaries;
    mapping(address => Notary) public notaries;

    mapping(bytes32 => Stored) private _observations;
    mapping(uint256 => mapping(uint256 => bytes32[])) private _commitments; // series => period => commitments

    event ObservationSubmitted(
        bytes32 indexed commitment, uint256 indexed series, uint256 indexed period, address submitter, Observation o
    );
    event BondRefunded(bytes32 indexed commitment, address indexed submitter, uint256 amount);
    event NotaryBonded(address indexed notary);
    event NotaryUnbonding(address indexed notary, uint256 withdrawableAt);
    event NotaryWithdrawn(address indexed notary);
    event NotarySlashed(address indexed notary, address indexed reporter, bytes32 evidence);

    error UnknownSeries();
    error WindowClosed();
    error WindowOpen();
    error PublishedInFuture();
    error PeriodNotBegun();
    error Duplicate();
    error TooManyObservations();
    error WrongBond();
    error NotEnoughAttestations();
    error SignersNotAscending();
    error NotaryCannotAttest(address signer);
    error NotListed();
    error AlreadyBonded();
    error NotBonded();
    error Unbonding();
    error NotYetWithdrawable();
    error NotSlashable();
    error NotSubmitter();
    error AlreadyRefunded();
    error TransferFailed();

    /**
     * @param series_ Markets then signals, in GCPIEngine's order (sorted markets, then signals as listed).
     * @param firstPeriod_ The first period that can be observed, as "YYYY-MM".
     * @param maxPublicationLagDays_ The methodology's freshness window (gcpi/ENGINE.md §1).
     * @param notaries_ The n notaries of §5.3.1.
     * @param threshold_ k: how many distinct listed notaries must attest.
     */
    constructor(
        string[] memory series_,
        string memory firstPeriod_,
        uint256 maxPublicationLagDays_,
        address[] memory notaries_,
        uint256 threshold_,
        uint256 submitBond_,
        uint256 notaryBond_,
        uint256 unbondingDelay_
    ) EIP712("GCPI ObservationVerifier", "1") {
        (bool ok, uint256 first) = GCPIMath.parsePeriod(firstPeriod_);
        // Windows are unsigned timestamps, so periods start in 1970 on-chain; the engine also accepts earlier years.
        if (!ok || first < 1970 * 12) revert Malformed("first");
        if (maxPublicationLagDays_ > 36500) revert Malformed("max_publication_lag_days");
        if (threshold_ == 0 || threshold_ > notaries_.length) revert Malformed("threshold");
        // Bounded so that now + delay fits unbondingAt's 64 bits for any timestamp before the year 584 billion.
        if (unbondingDelay_ > 3650 days) revert Malformed("unbonding_delay");
        for (uint256 i = 0; i < series_.length; i++) {
            bytes32 h = keccak256(bytes(series_[i]));
            if (!GCPIMath.isId(series_[i]) || _seriesIndex[h] != 0) revert Malformed("series");
            _seriesIndex[h] = i + 1;
            _series.push(series_[i]);
        }
        for (uint256 i = 0; i < notaries_.length; i++) {
            if (notaries_[i] == address(0) || notaries[notaries_[i]].listed) revert Malformed("notaries");
            notaries[notaries_[i]].listed = true;
            _notaries.push(notaries_[i]);
        }
        firstPeriod = first;
        maxPublicationLagDays = maxPublicationLagDays_;
        threshold = threshold_;
        submitBond = submitBond_;
        notaryBond = notaryBond_;
        unbondingDelay = unbondingDelay_;
    }

    // ---------------------------------------------------------------------------------------------------
    // Reading.

    function series() external view returns (string[] memory) {
        return _series;
    }

    function notaryList() external view returns (address[] memory) {
        return _notaries;
    }

    /// @notice The time after which period t takes no more observations and can be finalized.
    function closesAt(uint256 t) public view returns (uint256) {
        return uint256(GCPIMath.periodStart(t + 1)) + maxPublicationLagDays * 1 days + CHALLENGE_WINDOW;
    }

    function commitments(uint256 seriesIndex, uint256 t) external view returns (bytes32[] memory) {
        return _commitments[seriesIndex][t];
    }

    function observation(bytes32 c) external view returns (Stored memory) {
        return _observations[c];
    }

    /// @notice What a notary signs for an observation with commitment c.
    function attestationDigest(bytes32 c) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(ATTESTATION_TYPEHASH, c)));
    }

    /// @notice Whether a notary's signature counts now: listed, bonded, not unbonding, never slashed.
    function counts(address notary) public view returns (bool) {
        Notary memory n = notaries[notary];
        return n.listed && n.bonded && !n.slashed && n.unbondingAt == 0;
    }

    // ---------------------------------------------------------------------------------------------------
    // Submitting.

    /**
     * @notice Submit an attested observation, with `submitBond` returned once its period closes.
     * @param signatures From at least `threshold` distinct notaries that count, in ascending signer order.
     */
    function submit(Observation calldata o, bytes[] calldata signatures) external payable returns (bytes32 c) {
        if (msg.value != submitBond) revert WrongBond();
        (uint256 s, uint256 t) = _check(o);
        if (block.timestamp >= closesAt(t)) revert WindowClosed();
        // No notary can have retrieved a publication that has not happened yet (§5.4).
        if (o.published > block.timestamp) revert PublishedInFuture();
        // Nor of a period that has not begun: attesting one is the fault slashPremature punishes, so it is not
        // stored, where it would take one of the period's MAX_OBSERVATIONS slots until the period closed.
        if (GCPIMath.periodStart(t) > int256(block.timestamp)) revert PeriodNotBegun();
        c = GCPIMath.commitment(o);
        if (_observations[c].submitter != address(0)) revert Duplicate();
        if (_commitments[s][t].length >= MAX_OBSERVATIONS) revert TooManyObservations();
        _verify(c, signatures);

        _observations[c] = Stored(o, uint32(s), uint32(t), msg.sender, false);
        _commitments[s][t].push(c);
        emit ObservationSubmitted(c, s, t, msg.sender, o);
    }

    /// @notice Return a submitter's bond once the observation's period has closed.
    function refundBond(bytes32 c) external nonReentrant {
        Stored storage st = _observations[c];
        if (st.submitter != msg.sender) revert NotSubmitter();
        if (st.refunded) revert AlreadyRefunded();
        if (block.timestamp < closesAt(st.period)) revert WindowOpen();
        st.refunded = true;
        emit BondRefunded(c, msg.sender, submitBond);
        _pay(msg.sender, submitBond);
    }

    /// @dev Structural checks, with the engine's codes and in its order (check_observation, then the range).
    function _check(Observation calldata o) private view returns (uint256 s, uint256 t) {
        if (!GCPIMath.isId(o.market)) revert Malformed("observation_id");
        if (bytes(o.source).length != 0 && !GCPIMath.isId(o.source)) revert Malformed("observation_id");
        if (bytes(o.fxSource).length != 0 && !GCPIMath.isId(o.fxSource)) revert Malformed("observation_id");
        if (bytes(o.basis).length != 0 && !GCPIMath.isId(o.basis)) revert Malformed("observation_id");
        bool ok;
        (ok, t) = GCPIMath.parsePeriod(o.period);
        if (!ok) revert Malformed("observation_period");
        if (!o.hasFx && (o.fx != 0 || o.fxExp != 0)) revert Malformed("observation_fx");
        if (!GCPIMath.isCurrency(o.currency)) revert Malformed("observation_currency");
        if (t < firstPeriod) revert Malformed("observation_out_of_range");
        // The engine ignores a series its methodology does not list; here it is refused, with the same effect.
        s = _seriesIndex[keccak256(bytes(o.market))];
        if (s == 0) revert UnknownSeries();
        s -= 1;
    }

    function _verify(bytes32 c, bytes[] calldata signatures) private view {
        if (signatures.length < threshold) revert NotEnoughAttestations();
        bytes32 digest = attestationDigest(c);
        address last = address(0);
        for (uint256 i = 0; i < signatures.length; i++) {
            address signer = ECDSA.recover(digest, signatures[i]);
            // Ascending order makes the signers distinct without a set.
            if (signer <= last) revert SignersNotAscending();
            if (!counts(signer)) revert NotaryCannotAttest(signer);
            last = signer;
        }
    }

    // ---------------------------------------------------------------------------------------------------
    // Notary bonds (§5.4): slashable only for faults a contract can prove.

    function bond() external payable {
        Notary storage n = notaries[msg.sender];
        if (!n.listed) revert NotListed();
        if (n.bonded || n.slashed) revert AlreadyBonded();
        if (msg.value != notaryBond) revert WrongBond();
        n.bonded = true;
        emit NotaryBonded(msg.sender);
    }

    /// @notice Stop attesting and start the delay after which the bond can be withdrawn. It stays slashable meanwhile.
    function beginUnbonding() external {
        Notary storage n = notaries[msg.sender];
        if (!n.bonded || n.slashed) revert NotBonded();
        if (n.unbondingAt != 0) revert Unbonding();
        n.unbondingAt = uint64(block.timestamp + unbondingDelay);
        emit NotaryUnbonding(msg.sender, n.unbondingAt);
    }

    function withdrawBond() external nonReentrant {
        Notary storage n = notaries[msg.sender];
        if (!n.bonded || n.slashed) revert NotBonded();
        if (n.unbondingAt == 0 || block.timestamp < n.unbondingAt) revert NotYetWithdrawable();
        n.bonded = false;
        n.unbondingAt = 0;
        emit NotaryWithdrawn(msg.sender);
        _pay(msg.sender, notaryBond);
    }

    /**
     * @notice Equivocation: one notary attested two different values for the same market, source and period.
     *         "Different" is the engine's DISPUTED rule (gcpi/ENGINE.md §4): a different normalized price, or a
     *         different basis. Neither observation needs to have been submitted.
     */
    function slashEquivocation(Observation calldata a, bytes calldata sigA, Observation calldata b, bytes calldata sigB)
        external
        nonReentrant
    {
        bytes32 ca = GCPIMath.commitment(a);
        bytes32 cb = GCPIMath.commitment(b);
        address notary = ECDSA.recover(attestationDigest(ca), sigA);
        if (ECDSA.recover(attestationDigest(cb), sigB) != notary || !_conflict(a, b)) revert NotSlashable();
        _slash(notary, keccak256(abi.encode(ca, cb)));
    }

    /// @dev Same market, source and period; both usable; a different normalized price or basis.
    function _conflict(Observation calldata a, Observation calldata b) private view returns (bool) {
        if (!_same(a.market, b.market) || !_same(a.source, b.source) || !_same(a.period, b.period)) return false;
        (bool ok, uint256 t) = GCPIMath.parsePeriod(a.period);
        if (!ok) return false;
        (uint256 pa, uint8 ha) = GCPIMath.normalize(a, t, maxPublicationLagDays);
        (uint256 pb, uint8 hb) = GCPIMath.normalize(b, t, maxPublicationLagDays);
        if (ha == GCPIMath.NORM_INVALID || hb == GCPIMath.NORM_INVALID) return false;
        return pa != pb || !_same(a.basis, b.basis);
    }

    /// @notice A notary attested a period that has not begun, or a publication time still in the future.
    function slashPremature(Observation calldata o, bytes calldata sig) external nonReentrant {
        bytes32 c = GCPIMath.commitment(o);
        address notary = ECDSA.recover(attestationDigest(c), sig);
        (bool ok, uint256 t) = GCPIMath.parsePeriod(o.period);
        bool future = o.published > block.timestamp || (ok && GCPIMath.periodStart(t) > int256(block.timestamp));
        if (!future) revert NotSlashable();
        _slash(notary, c);
    }

    /// @dev Half the bond to the reporter; the rest stays in this contract for good. The notary never counts again.
    function _slash(address notary, bytes32 evidence) private {
        Notary storage n = notaries[notary];
        if (!n.listed || !n.bonded || n.slashed) revert NotSlashable();
        n.slashed = true;
        n.bonded = false;
        emit NotarySlashed(notary, msg.sender, evidence);
        _pay(msg.sender, notaryBond / 2);
    }

    function _same(string calldata a, string calldata b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _pay(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
