// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
    Walk the Plank - V1 Skeleton

    Design:
    - Native ETH entry only
    - Public queue per (playerCount, entryFee)
    - 2 to 5 players
    - Fixed entry tiers only
    - Turn-based loser selection via Pyth Entropy callback
    - Auto-payout winners on resolution, with claim fallback on failed transfers
    - Claim model for refunds
    - 5% protocol fee
*/

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import { IEntropyConsumer } from "@pythnetwork/entropy-sdk-solidity/IEntropyConsumer.sol";
import { IEntropyV2 } from "@pythnetwork/entropy-sdk-solidity/IEntropyV2.sol";

contract WalkThePlanck is Ownable, ReentrancyGuard, Pausable, IEntropyConsumer {
    // =============================================================
    //                           CONSTANTS
    // =============================================================

    uint256 public constant HOUSE_BPS = 500; // 5.00%
    uint256 public constant BPS_DENOMINATOR = 10_000;

    uint8 public constant MIN_PLAYERS = 2;
    uint8 public constant MAX_PLAYERS = 5;

    // =============================================================
    //                            ERRORS
    // =============================================================

    error InvalidPlayerCount();
    error InvalidEntryFee();
    error IncorrectEthAmount();
    error AlreadyJoined();
    error MatchNotOpen();
    error MatchNotExpired();
    error MatchNotResolved();
    error MatchNotCancelled();
    error NothingToClaim();
    error NothingToRefund();
    error InvalidMatch();
    error UnauthorizedCallback();
    error TransferFailed();
    error ZeroAddress();
    error InvalidState();
    error InsufficientEntropyBalance(uint256 required, uint256 available);
    error InsufficientMatchPot(uint256 required, uint256 available);

    // =============================================================
    //                            ENUMS
    // =============================================================

    enum Status {
        Open,
        Resolving,
        Resolved,
        Cancelled
    }

    // =============================================================
    //                           STRUCTS
    // =============================================================

    struct Match {
        uint256 id;
        uint8 maxPlayers;
        uint8 playerCount;
        uint256 entryFee;
        uint256 entropyFee;
        uint256 totalPot;
        uint256 deadline;
        Status status;
        uint8 loserIndex;
        uint8 deathTurn;
        uint64 sequenceNumber;
        address loser;
        address[] players;
        address[] turnOrder;
    }

    struct ActiveMatchBucket {
        uint256 matchId;
        uint8 maxPlayers;
        uint8 playerCount;
        uint256 entryFee;
        uint256 deadline;
        Status status;
        address[] players;
    }

    // =============================================================
    //                          STORAGE
    // =============================================================

    uint256 public nextMatchId = 1;
    uint256 public matchExpiration = 10 minutes;

    address public treasury;
    IEntropyV2 public entropy; // Pyth Entropy contract

    uint256 public protocolFeesAccrued;

    mapping(uint256 => Match) public matches;

    // queueKey => active open match id
    mapping(bytes32 => uint256) public activeMatchByQueueKey;

    // entropy sequence => match id
    mapping(uint64 => uint256) public sequenceToMatchId;

    // matchId => player => joined?
    mapping(uint256 => mapping(address => bool)) public joined;

    // matchId => player => winnings claimable
    mapping(uint256 => mapping(address => uint256)) public claimable;

    // matchId => player => refund claimable
    mapping(uint256 => mapping(address => uint256)) public refundable;

    // player => all matches they joined
    mapping(address => uint256[]) private playerMatchIds;

    // player => matches with deferred winnings available to claim
    mapping(address => uint256[]) private claimableMatchIds;

    // player => matches with refunds available to claim
    mapping(address => uint256[]) private refundableMatchIds;

    // 1-based positions for O(1) removal from claimable/refundable lists
    mapping(address => mapping(uint256 => uint256)) private claimableMatchIndex;
    mapping(address => mapping(uint256 => uint256)) private refundableMatchIndex;

    // fixed allowed entry tiers
    mapping(uint256 => bool) public allowedEntryFees;
    uint256[] private knownEntryFees;
    mapping(uint256 => uint256) private knownEntryFeeIndex;

    // =============================================================
    //                            EVENTS
    // =============================================================

    event MatchCreated(
        uint256 indexed matchId,
        uint8 indexed maxPlayers,
        uint256 entryFee,
        uint256 deadline
    );

    event PlayerJoined(
        uint256 indexed matchId,
        address indexed player,
        uint8 playerCount,
        uint8 maxPlayers
    );

    event MatchResolving(
        uint256 indexed matchId,
        uint64 indexed sequenceNumber
    );

    event MatchResolved(
        uint256 indexed matchId,
        address indexed loser,
        uint8 loserIndex,
        uint256 payoutPerSurvivor,
        uint256 houseFee,
        uint256 dust
    );
    event WinningsPaid(uint256 indexed matchId, address indexed player, uint256 amount);
    event WinningsDeferred(uint256 indexed matchId, address indexed player, uint256 amount);

    event MatchCancelled(uint256 indexed matchId);
    event MatchNotRunnable(uint256 indexed matchId);
    event MatchNotFound(uint256 indexed sequenceNumber);
    event MatchRunFailed(uint256 indexed matchId, uint8 playerCount);

    event Claimed(
        uint256 indexed matchId,
        address indexed player,
        uint256 amount
    );

    event RefundClaimed(
        uint256 indexed matchId,
        address indexed player,
        uint256 amount
    );

    event AllowedEntryFeeSet(uint256 entryFee, bool allowed);
    event MatchExpirationSet(uint256 newDuration);
    event TreasurySet(address indexed newTreasury);
    event EntropyRouterSet(address indexed newRouter);

    event ProtocolFeesWithdrawn(address indexed to, uint256 amount);

    // =============================================================
    //                         CONSTRUCTOR
    // =============================================================

    constructor(address initialOwner, address initialTreasury, address entropyAddress) Ownable(initialOwner) {
        if (initialTreasury == address(0)) revert ZeroAddress();
        treasury = initialTreasury;

        if(entropyAddress == address(0))
        revert ZeroAddress();
        entropy = IEntropyV2(entropyAddress);
        
        _setAllowedEntryFee(0.0005 ether, true);
        _setAllowedEntryFee(0.001 ether, true);
        _setAllowedEntryFee(0.0025 ether, true);
        _setAllowedEntryFee(0.005 ether, true);
        _setAllowedEntryFee(0.01 ether, true);
    }

    // =============================================================
    //                        EXTERNAL USER
    // =============================================================

    function joinQueue(uint8 maxPlayers, uint256 entryFee)
    external
    payable
    nonReentrant
    whenNotPaused
    returns (uint256 matchId)
    {
        _validatePlayerCount(maxPlayers);
        _validateEntryFee(entryFee);

        bytes32 key = _queueKey(maxPlayers, entryFee);
        matchId = activeMatchByQueueKey[key];

        if (matchId != 0) {
            Match storage existingMatch = matches[matchId];
            
            //Allow match counter to advance if stale/unresolved
            bool stale =
                existingMatch.status != Status.Open ||
                block.timestamp > existingMatch.deadline ||
                existingMatch.playerCount >= existingMatch.maxPlayers;

            if (stale) {
                activeMatchByQueueKey[key] = 0;
                matchId = 0;
            }
        }

        if (matchId == 0) {
            matchId = _createMatch(maxPlayers, entryFee);
            activeMatchByQueueKey[key] = matchId;
        }

        Match storage matchData = matches[matchId];
        if (msg.value != matchData.entryFee) revert IncorrectEthAmount();
        if (joined[matchId][msg.sender]) revert AlreadyJoined();

        joined[matchId][msg.sender] = true;
        playerMatchIds[msg.sender].push(matchId);
        matchData.players.push(msg.sender);
        matchData.playerCount += 1;
        matchData.totalPot += msg.value;

        emit PlayerJoined(matchId, msg.sender, matchData.playerCount, matchData.maxPlayers);

        if (matchData.playerCount == matchData.maxPlayers) {
            activeMatchByQueueKey[key] = 0;

            matchData.status = Status.Resolving;
            uint64 sequenceNumber = _requestEntropy(matchId);
            matchData.sequenceNumber = sequenceNumber;
            sequenceToMatchId[sequenceNumber] = matchId;

            emit MatchResolving(matchId, sequenceNumber);
        }
    }


    function cancelExpiredMatch(uint256 matchId)
        external
        nonReentrant
        whenNotPaused
    {
        Match storage matchData = matches[matchId];
        if (matchData.id == 0) revert InvalidMatch();
        if (matchData.status != Status.Open) revert MatchNotOpen();
        if (block.timestamp <= matchData.deadline) revert MatchNotExpired();

        matchData.status = Status.Cancelled;

        bytes32 key = _queueKey(matchData.maxPlayers, matchData.entryFee);
        if (activeMatchByQueueKey[key] == matchId) {
            activeMatchByQueueKey[key] = 0;
        }

        _creditCancellationRefunds(matchId);

        emit MatchCancelled(matchId);
    }

    function claim(uint256 matchId)
        external
        nonReentrant
        whenNotPaused
    {
        Match storage matchData = matches[matchId];
        if (matchData.id == 0) revert InvalidMatch();
        if (matchData.status != Status.Resolved) revert MatchNotResolved();

        uint256 amount = claimable[matchId][msg.sender];
        if (amount == 0) revert NothingToClaim();

        claimable[matchId][msg.sender] = 0;
        _removeClaimableMatch(msg.sender, matchId);

        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit Claimed(matchId, msg.sender, amount);
    }

    function claimRefund(uint256 matchId)
        external
        nonReentrant
        whenNotPaused
    {
        Match storage matchData = matches[matchId];
        if (matchData.id == 0) revert InvalidMatch();
        if (matchData.status != Status.Cancelled) revert MatchNotCancelled();

        uint256 amount = refundable[matchId][msg.sender];
        if (amount == 0) revert NothingToRefund();

        refundable[matchId][msg.sender] = 0;
        _removeRefundableMatch(msg.sender, matchId);

        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit RefundClaimed(matchId, msg.sender, amount);
    }

    // =============================================================
    //                      ENTROPY CALLBACK ENTRY
    // =============================================================

    // @param sequenceNumber The sequence number of the request.
    // @param provider The address of the provider that generated the random number. If your app uses multiple providers, you can use this argument to distinguish which one is calling the app back.
    // @param randomNumber The generated random number.
    // This method is called by the entropy contract when a random number is generated.
    // This method **must** be implemented on the same contract that requested the random number.
    // This method should **never** return an error -- if it returns an error, then the keeper will not be able to invoke the callback.
    // If you are having problems receiving the callback, the most likely cause is that the callback is erroring.
    // See the callback debugging guide here to identify the error https://docs.pyth.network/entropy/debug-callback-failures
    function entropyCallback(
    uint64 sequenceNumber,
    address,
    bytes32 randomNumber
    ) internal override {

        uint256 matchId = sequenceToMatchId[sequenceNumber];
        if (matchId == 0)
        { 
            emit MatchNotFound(sequenceNumber);
            return;
        }

        Match storage matchData = matches[matchId];
        if (matchData.status != Status.Resolving) 
        { 
            emit MatchNotRunnable(matchId);
            return;
        }

        _runGame(matchId, randomNumber);

        delete sequenceToMatchId[sequenceNumber];
    }

    // =============================================================
    //                        OWNER FUNCTIONS
    // =============================================================

    function setAllowedEntryFee(uint256 entryFee, bool allowed) external onlyOwner {
        _setAllowedEntryFee(entryFee, allowed);
        emit AllowedEntryFeeSet(entryFee, allowed);
    }

    function setMatchExpiration(uint256 newDuration) external onlyOwner {
        require(newDuration >= 1 minutes, "duration too short");
        matchExpiration = newDuration;
        emit MatchExpirationSet(newDuration);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        treasury = newTreasury;
        emit TreasurySet(newTreasury);
    }

    function setEntropyRouter(address newEntropy) external onlyOwner {
        if (newEntropy == address(0)) revert ZeroAddress();
        entropy = IEntropyV2(newEntropy);
        emit EntropyRouterSet(newEntropy);
    }

    function getEntropyRequestFee() external view returns (uint256) {
        return entropy.getFeeV2();
    }

    function withdrawProtocolFees(address to, uint256 amount)
        external
        onlyOwner
        nonReentrant
    {
        if (to == address(0)) revert ZeroAddress();
        require(amount <= protocolFeesAccrued, "insufficient accrued");

        protocolFeesAccrued -= amount;

        (bool ok, ) = payable(to).call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit ProtocolFeesWithdrawn(to, amount);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // =============================================================
    //                         VIEW FUNCTIONS
    // =============================================================

    function getMatchPlayers(uint256 matchId) external view returns (address[] memory) {
        if (matches[matchId].id == 0) revert InvalidMatch();
        return matches[matchId].players;
    }

    function getPlayerMatches(address player) external view returns (uint256[] memory) {
        return playerMatchIds[player];
    }

    function getClaimableMatches(address player) external view returns (uint256[] memory) {
        return claimableMatchIds[player];
    }

    function getRefundableMatches(address player) external view returns (uint256[] memory) {
        return refundableMatchIds[player];
    }

    function getTurnOrder(uint256 matchId) external view returns (address[] memory) {
        if (matches[matchId].id == 0) revert InvalidMatch();
        return matches[matchId].turnOrder;
    }

    function getActiveMatch(uint8 maxPlayers, uint256 entryFee) external view returns (uint256) {
        uint256 matchId = activeMatchByQueueKey[_queueKey(maxPlayers, entryFee)];
        if (!_isActiveMatch(matchId, maxPlayers, entryFee)) return 0;
        return matchId;
    }

    function getActiveMatchBuckets() external view returns (ActiveMatchBucket[] memory) {
        uint256 bucketCount = 0;

        for (uint8 maxPlayers = MIN_PLAYERS; maxPlayers <= MAX_PLAYERS; maxPlayers++) {
            for (uint256 i = 0; i < knownEntryFees.length; i++) {
                uint256 entryFee = knownEntryFees[i];
                uint256 matchId = activeMatchByQueueKey[_queueKey(maxPlayers, entryFee)];
                if (_isActiveMatch(matchId, maxPlayers, entryFee)) {
                    bucketCount += 1;
                }
            }
        }

        ActiveMatchBucket[] memory buckets = new ActiveMatchBucket[](bucketCount);
        uint256 bucketIndex = 0;

        for (uint8 maxPlayers = MIN_PLAYERS; maxPlayers <= MAX_PLAYERS; maxPlayers++) {
            for (uint256 i = 0; i < knownEntryFees.length; i++) {
                uint256 entryFee = knownEntryFees[i];
                uint256 matchId = activeMatchByQueueKey[_queueKey(maxPlayers, entryFee)];
                if (!_isActiveMatch(matchId, maxPlayers, entryFee)) continue;

                Match storage matchData = matches[matchId];
                buckets[bucketIndex] = ActiveMatchBucket({
                    matchId: matchId,
                    maxPlayers: matchData.maxPlayers,
                    playerCount: matchData.playerCount,
                    entryFee: matchData.entryFee,
                    deadline: matchData.deadline,
                    status: matchData.status,
                    players: matchData.players
                });
                bucketIndex += 1;
            }
        }

        return buckets;
    }

    function getKnownEntryFees() external view returns (uint256[] memory) {
        return knownEntryFees;
    }

    function isAllowedEntryFee(uint256 entryFee) external view returns (bool) {
        return allowedEntryFees[entryFee];
    }

    function previewPayout(uint8 maxPlayers, uint256 entryFee) external view returns (uint256) {
        if (maxPlayers < MIN_PLAYERS || maxPlayers > MAX_PLAYERS) revert InvalidPlayerCount();
        _validateEntryFee(entryFee);

        uint256 totalPot = uint256(maxPlayers) * entryFee;
        uint256 entropyFee = entropy.getFeeV2();
        if (totalPot <= entropyFee) return 0;

        totalPot -= entropyFee;
        uint256 houseFee = (totalPot * HOUSE_BPS) / BPS_DENOMINATOR;
        uint256 survivorPool = totalPot - houseFee;
        return survivorPool / (maxPlayers - 1);
    }

    function previewJoinCost(uint8 maxPlayers, uint256 entryFee) external view returns (uint256) {
        if (maxPlayers < MIN_PLAYERS || maxPlayers > MAX_PLAYERS) revert InvalidPlayerCount();
        _validateEntryFee(entryFee);

        return entryFee;
    }

    function queueKeyOf(uint8 maxPlayers, uint256 entryFee) external pure returns (bytes32) {
        return _queueKey(maxPlayers, entryFee);
    }

    // =============================================================
    //                       INTERNAL FUNCTIONS
    // =============================================================

    function _createMatch(uint8 maxPlayers, uint256 entryFee) internal returns (uint256 matchId) {
        matchId = nextMatchId++;
        Match storage matchData = matches[matchId];
        uint256 entropyFee = entropy.getFeeV2();

        matchData.id = matchId;
        matchData.maxPlayers = maxPlayers;
        matchData.entryFee = entryFee;
        matchData.entropyFee = entropyFee;
        matchData.deadline = block.timestamp + matchExpiration;
        matchData.status = Status.Open;

        emit MatchCreated(matchId, maxPlayers, entryFee, matchData.deadline);
    }

    function _requestEntropy(uint256 matchId) internal returns (uint64 sequenceNumber) {
        Match storage matchData = matches[matchId];
        uint256 fee = matchData.entropyFee;
        uint256 available = address(this).balance;

        if (available < fee) {
            revert InsufficientEntropyBalance(fee, available);
        }

        if (matchData.totalPot < fee) {
            revert InsufficientMatchPot(fee, matchData.totalPot);
        }

        matchData.totalPot -= fee;
        sequenceNumber = entropy.requestV2{ value: fee }();
    }

    function _creditCancellationRefunds(uint256 matchId) internal {
        Match storage matchData = matches[matchId];
        uint256 playerCount = matchData.players.length;
        if (playerCount == 0) return;

        uint256 refundPerPlayer = matchData.totalPot / playerCount;
        uint256 dust = matchData.totalPot - (refundPerPlayer * playerCount);

        for (uint256 i = 0; i < playerCount; i++) {
            address player = matchData.players[i];
            refundable[matchId][player] += refundPerPlayer;
            _addRefundableMatch(player, matchId);
        }

        protocolFeesAccrued += dust;
    }

    function _runGame(uint256 matchId, bytes32 randomNumber) internal {
        Match storage matchData = matches[matchId];

        if (matchData.playerCount < MIN_PLAYERS) {
            _creditCancellationRefunds(matchId);

            matchData.status = Status.Cancelled;
            emit MatchRunFailed(matchId, matchData.playerCount);
            emit MatchCancelled(matchId);
            return;
        }

        matchData.turnOrder = matchData.players;

        bytes32 orderSeed = keccak256(abi.encode(randomNumber, "ORDER"));

        for (uint256 i = matchData.turnOrder.length - 1; i > 0; i--) {
            uint256 j = uint256(keccak256(abi.encode(orderSeed, i))) % (i + 1);

            address temp = matchData.turnOrder[i];
            matchData.turnOrder[i] = matchData.turnOrder[j];
            matchData.turnOrder[j] = temp;
        }

        bytes32 deathSeed = keccak256(abi.encode(randomNumber, "DEATH"));
        matchData.deathTurn = uint8(uint256(deathSeed) % matchData.playerCount);
        _resolveMatch(matchId, matchData.turnOrder[matchData.deathTurn]);
    }

    function _resolveMatch(uint256 matchId, address loserOnTurn) internal {
        Match storage matchData = matches[matchId];

        matchData.loser = loserOnTurn;
        matchData.status = Status.Resolved;

        uint256 houseFee = (matchData.totalPot * HOUSE_BPS) / BPS_DENOMINATOR;
        uint256 survivorPool = matchData.totalPot - houseFee;
        uint256 survivorCount = matchData.playerCount - 1;
        uint256 payoutPerSurvivor = survivorPool / survivorCount;
        uint256 dust = survivorPool - (payoutPerSurvivor * survivorCount);

        protocolFeesAccrued += houseFee + dust;

        for (uint256 i = 0; i < matchData.players.length; i++) {
            if (matchData.players[i] == loserOnTurn) {
                matchData.loserIndex = uint8(i);
                break;
            }
        }

        for (uint256 i = 0; i < matchData.turnOrder.length; i++) {
            address player = matchData.turnOrder[i];
            if (player == loserOnTurn) continue;
            _payWinnerOrCreditClaim(matchId, player, payoutPerSurvivor);
        }

        emit MatchResolved(
            matchId,
            loserOnTurn,
            matchData.loserIndex,
            payoutPerSurvivor,
            houseFee,
            dust
        );
    }

    function _validatePlayerCount(uint8 maxPlayers) internal pure {
        if (maxPlayers < MIN_PLAYERS || maxPlayers > MAX_PLAYERS) {
            revert InvalidPlayerCount();
        }
    }

    function _payWinnerOrCreditClaim(uint256 matchId, address player, uint256 amount) internal {
        (bool ok, ) = payable(player).call{value: amount}("");
        if (ok) {
            emit WinningsPaid(matchId, player, amount);
            return;
        }

        claimable[matchId][player] += amount;
        _addClaimableMatch(player, matchId);
        emit WinningsDeferred(matchId, player, amount);
    }

    function _addClaimableMatch(address player, uint256 matchId) internal {
        if (claimableMatchIndex[player][matchId] != 0) return;

        claimableMatchIds[player].push(matchId);
        claimableMatchIndex[player][matchId] = claimableMatchIds[player].length;
    }

    function _removeClaimableMatch(address player, uint256 matchId) internal {
        uint256 index = claimableMatchIndex[player][matchId];
        if (index == 0) return;

        _removeIndexedMatch(claimableMatchIds[player], claimableMatchIndex[player], matchId, index);
    }

    function _addRefundableMatch(address player, uint256 matchId) internal {
        if (refundableMatchIndex[player][matchId] != 0) return;

        refundableMatchIds[player].push(matchId);
        refundableMatchIndex[player][matchId] = refundableMatchIds[player].length;
    }

    function _removeRefundableMatch(address player, uint256 matchId) internal {
        uint256 index = refundableMatchIndex[player][matchId];
        if (index == 0) return;

        _removeIndexedMatch(refundableMatchIds[player], refundableMatchIndex[player], matchId, index);
    }

    function _removeIndexedMatch(
        uint256[] storage matchIds,
        mapping(uint256 => uint256) storage indexMap,
        uint256 matchId,
        uint256 index
    ) internal {
        uint256 lastIndex = matchIds.length;
        if (index != lastIndex) {
            uint256 movedMatchId = matchIds[lastIndex - 1];
            matchIds[index - 1] = movedMatchId;
            indexMap[movedMatchId] = index;
        }

        matchIds.pop();
        delete indexMap[matchId];
    }

    function _validateEntryFee(uint256 entryFee) internal view {
        if (!allowedEntryFees[entryFee]) revert InvalidEntryFee();
    }

    function _setAllowedEntryFee(uint256 entryFee, bool allowed) internal {
        allowedEntryFees[entryFee] = allowed;

        if (knownEntryFeeIndex[entryFee] == 0) {
            knownEntryFees.push(entryFee);
            knownEntryFeeIndex[entryFee] = knownEntryFees.length;
        }
    }

    function _isActiveMatch(
        uint256 matchId,
        uint8 maxPlayers,
        uint256 entryFee
    ) internal view returns (bool) {
        if (matchId == 0) return false;

        Match storage matchData = matches[matchId];
        if (matchData.id == 0) return false;
        if (matchData.status != Status.Open) return false;
        if (matchData.deadline < block.timestamp) return false;
        if (matchData.playerCount >= matchData.maxPlayers) return false;
        if (matchData.maxPlayers != maxPlayers) return false;
        if (matchData.entryFee != entryFee) return false;

        return true;
    }

    function _queueKey(uint8 maxPlayers, uint256 entryFee) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(maxPlayers, entryFee));
    }

    // This method is required by the IEntropyConsumer interface.
    // It returns the address of the entropy contract which will call the callback.
    function getEntropy() internal view override returns (address) {
        return address(entropy);
    }

    // =============================================================
    //                           RECEIVE
    // =============================================================

    receive() external payable {}
}
