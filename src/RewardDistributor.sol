// SPDX-License-Identifier: BUSL-1.1
// Read full license and terms at https://github.com/contextwtf/contracts
pragma solidity ^0.8.19;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {OwnableRoles} from "solady/auth/OwnableRoles.sol";
import {MerkleProofLib} from "solady/utils/MerkleProofLib.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";

/**
 * @title Reward Distributor
 * @notice Distributes USDC rewards to users based on merkle proofs for each epoch
 */
contract RewardDistributor is OwnableRoles {
    IERC20 public usdc;

    uint256 public constant ADMIN_ROLE = 1 << 0;

    mapping(uint256 => bytes32) public epochRoots; // epochId => merkle root
    mapping(uint256 => mapping(address => bool)) public epochClaimed; // epochId => user => claimed

    event RewardClaimed(uint256 indexed epochId, address indexed user, uint256 amount);
    event EpochRootSet(uint256 indexed epochId, bytes32 merkleRoot);

    error EpochAlreadySet();
    error InvalidProof();
    error AlreadyClaimed();
    error EpochNotSet();
    error UsdcTransferFailed();
    error MismatchedArrays();

    constructor(address _usdc, address _owner) {
        _initializeOwner(_owner);
        usdc = IERC20(_usdc);
    }

    // ========== CLAIM ==========

    /**
     * @notice Claims reward for a specific epoch using a merkle proof
     * @dev Transfers USDC to the caller if the proof is valid and not already claimed
     * @param epochId The epoch ID to claim rewards for
     * @param amount The amount of USDC to claim
     * @param proof Merkle proof verifying the claim
     */
    function claimReward(uint256 epochId, uint256 amount, bytes32[] calldata proof) external {
        _claimRewardNoTransfer(msg.sender, epochId, amount, proof);
        if (amount > 0) {
            if (!usdc.transfer(msg.sender, amount)) revert UsdcTransferFailed();
        }
    }

    /**
     * @notice Claims rewards for multiple epochs in a single transaction
     * @dev Validates all proofs and transfers the total USDC amount at once
     * @param epochIds_ Array of epoch IDs to claim rewards for
     * @param amounts Array of USDC amounts to claim for each epoch
     * @param proofs Array of merkle proofs for each claim
     */
    function batchClaimRewards(uint256[] calldata epochIds_, uint256[] calldata amounts, bytes32[][] calldata proofs)
        external
    {
        uint256 length = epochIds_.length;
        if (length != amounts.length || length != proofs.length) {
            revert MismatchedArrays();
        }

        uint256 totalAmount = 0;
        for (uint256 i = 0; i < length; i++) {
            _claimRewardNoTransfer(msg.sender, epochIds_[i], amounts[i], proofs[i]);
            totalAmount += amounts[i];
        }

        if (totalAmount > 0) {
            if (!usdc.transfer(msg.sender, totalAmount)) revert UsdcTransferFailed();
        }
    }

    function _claimRewardNoTransfer(address caller, uint256 epochId, uint256 amount, bytes32[] calldata proof)
        internal
    {
        if (epochRoots[epochId] == bytes32(0)) revert EpochNotSet();
        if (epochClaimed[epochId][caller]) revert AlreadyClaimed();

        bytes32 leaf = EfficientHashLib.hash(abi.encodePacked(caller, amount));
        if (!MerkleProofLib.verify(proof, epochRoots[epochId], leaf)) {
            revert InvalidProof();
        }

        epochClaimed[epochId][caller] = true;
        emit RewardClaimed(epochId, caller, amount);
    }

    // ========== ADMIN ==========

    function setEpochRoot(uint256 epochId, bytes32 merkleRoot) external onlyRoles(ADMIN_ROLE) {
        _setEpochRoot(epochId, merkleRoot);
    }

    function setEpochRoots(uint256[] calldata epochIds_, bytes32[] calldata merkleRoots)
        external
        onlyRoles(ADMIN_ROLE)
    {
        if (epochIds_.length != merkleRoots.length) revert MismatchedArrays();
        for (uint256 i = 0; i < epochIds_.length; i++) {
            _setEpochRoot(epochIds_[i], merkleRoots[i]);
        }
    }

    function _setEpochRoot(uint256 epochId, bytes32 merkleRoot) internal {
        if (_epochExists(epochId)) {
            revert EpochAlreadySet();
        }
        epochRoots[epochId] = merkleRoot;
        emit EpochRootSet(epochId, merkleRoot);
    }

    function replaceEpochRoot(uint256 epochId, bytes32 merkleRoot) external onlyRoles(ADMIN_ROLE) {
        if (!_epochExists(epochId)) {
            revert EpochNotSet();
        }
        epochRoots[epochId] = merkleRoot;
        emit EpochRootSet(epochId, merkleRoot);
    }

    // ========== VIEW ==========

    function _epochExists(uint256 epochId) internal view returns (bool) {
        return epochRoots[epochId] != bytes32(0);
    }

    /**
     * @notice Checks if a user has already claimed rewards for a specific epoch
     * @param user The address to check
     * @param epochId The epoch ID to check
     * @return True if the user has already claimed for this epoch
     */
    function hasClaimedEpoch(address user, uint256 epochId) external view returns (bool) {
        return epochClaimed[epochId][user];
    }
}
