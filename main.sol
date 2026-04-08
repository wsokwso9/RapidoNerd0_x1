// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
    Paper Arcades: RapidoNerd0_x1
    --------------------------------
    In the city of laminated neon, collectors don't just mint cards —
    they launch micro-leagues, trade bragging rights, and fuse "social"
    into scarcity. This contract is an NFT launcher and on-chain
    card-trading game with:

    - ERC721 cards with on-chain metadata (compact SVG)
    - Launch phases, allowlist (Merkle), public mint, and pack mint
    - Commit-reveal "ink roll" for traits (anti-front-run friendly)
    - Built-in fixed-price market and peer-to-peer trade offers
    - Seasons, XP, and lightweight league scoring events
    - Royalty (ERC2981), two-step ownership, pausability, and reentrancy guard

    Notes:
    - Randomness on EVM is never perfect; commit/reveal is used to reduce
      trivial sniping. For higher assurance, integrate a VRF later.
*/

// =============================================================
//                           ERRORS
// =============================================================

error RNX_Unauthorized();
error RNX_Paused();
error RNX_Reentry();
error RNX_Zero();
error RNX_BadAddr();
error RNX_BadParam();
error RNX_Same();
error RNX_TooSoon();
error RNX_NotReady();
error RNX_Already();
error RNX_NotFound();
error RNX_Expired();
error RNX_SoldOut();
error RNX_Maxed();
error RNX_InvalidProof();
error RNX_TransferFail();
error RNX_Sig();
error RNX_NotOwnerNorApproved();
error RNX_UnsafeRecipient();
error RNX_BadNonce();
error RNX_BadPrice();
error RNX_BadState();

// =============================================================
//                           EVENTS
// =============================================================

event RNX_OwnerProposed(address indexed oldOwner, address indexed proposed);
event RNX_OwnerAccepted(address indexed oldOwner, address indexed newOwner);
event RNX_GuardianSet(address indexed oldGuardian, address indexed newGuardian);
event RNX_PauseSet(bool paused);
event RNX_BaseURILocked(bytes32 salt);

event RNX_LaunchConfigured(uint64 startAt, uint64 allowlistEndAt, uint64 publicEndAt);
event RNX_RootSet(bytes32 indexed oldRoot, bytes32 indexed newRoot);
event RNX_MintTicket(address indexed who, uint32 qty, uint256 paid);
event RNX_PackMint(address indexed who, uint16 packs, uint32 cards, uint256 paid);

event RNX_Commit(address indexed who, bytes32 indexed commitment, uint64 revealAfterBlock);
event RNX_Reveal(address indexed who, bytes32 indexed commitment, uint256 entropy, uint32 cardsRevealed);

event RNX_Listed(uint256 indexed tokenId, address indexed seller, uint256 price);
event RNX_Delisted(uint256 indexed tokenId, address indexed seller);
event RNX_Purchased(uint256 indexed tokenId, address indexed seller, address indexed buyer, uint256 price, uint256 fee);

event RNX_TradeOpened(bytes32 indexed tradeId, address indexed maker, address indexed taker);
event RNX_TradeCancelled(bytes32 indexed tradeId, address indexed maker);
event RNX_TradeExecuted(bytes32 indexed tradeId, address indexed maker, address indexed taker);

event RNX_SeasonOpened(uint32 indexed seasonId, uint64 startAt, uint64 endAt, bytes32 rulesetHash);
event RNX_SeasonClosed(uint32 indexed seasonId, bytes32 settlementHash);
event RNX_XPGranted(address indexed player, uint32 indexed seasonId, uint64 amount, bytes32 reason);
event RNX_BadgePinned(address indexed player, uint256 indexed tokenId, uint32 indexed seasonId);

event RNX_RoyaltySet(address indexed receiver, uint96 bps);
event RNX_FeeSet(uint16 marketFeeBps);
event RNX_TreasurySet(address indexed treasury);
event RNX_Swept(address indexed to, uint256 amount);

// =============================================================
//                       INTERFACES
// =============================================================

interface IERC165 {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

interface IERC721 is IERC165 {
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    function balanceOf(address owner) external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);

    function approve(address to, uint256 tokenId) external;
    function getApproved(uint256 tokenId) external view returns (address);

    function setApprovalForAll(address operator, bool approved) external;
    function isApprovedForAll(address owner, address operator) external view returns (bool);

    function transferFrom(address from, address to, uint256 tokenId) external;
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data) external;
}

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
}

interface IERC721Metadata is IERC721 {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function tokenURI(uint256 tokenId) external view returns (string memory);
}

interface IERC2981 is IERC165 {
    function royaltyInfo(uint256 tokenId, uint256 salePrice) external view returns (address receiver, uint256 royaltyAmount);
}

// Optional: EIP-4494 style permit for ERC721 approvals.
interface IERC4494 {
    function permit(address spender, uint256 tokenId, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external;
    function nonces(uint256 tokenId) external view returns (uint256);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

// =============================================================
//                          LIBRARIES
// =============================================================

library RNXMath {
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function clamp(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        if (x < lo) return lo;
        if (x > hi) return hi;
        return x;
    }
}

library RNXStrings {
    bytes16 private constant _HEX = 0x30313233343536373839616263646566;

    function toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    function toHexString(uint256 value, uint256 length) internal pure returns (string memory) {
        bytes memory buffer = new bytes(2 * length + 2);
        buffer[0] = "0";
        buffer[1] = "x";
        for (uint256 i = 2 * length + 1; i > 1; --i) {
            buffer[i] = _HEX[value & 0xf];
            value >>= 4;
        }
        if (value != 0) revert RNX_BadParam();
        return string(buffer);
    }
}

library RNXBase64 {
    bytes internal constant _TABLE = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    function encode(bytes memory data) internal pure returns (string memory) {
        if (data.length == 0) return "";
        uint256 encodedLen = 4 * ((data.length + 2) / 3);
        bytes memory result = new bytes(encodedLen + 32);
        bytes memory table = _TABLE;
        assembly {
            let tablePtr := add(table, 1)
            let resultPtr := add(result, 32)
            for { let i := 0 } lt(i, mload(data)) { } {
                i := add(i, 3)
                let input := and(mload(add(data, i)), 0xffffff)
                let out := mload(add(tablePtr, and(shr(18, input), 0x3F)))
                out := shl(8, out)
                out := add(out, and(mload(add(tablePtr, and(shr(12, input), 0x3F))), 0xFF))
                out := shl(8, out)
                out := add(out, and(mload(add(tablePtr, and(shr(6, input), 0x3F))), 0xFF))
                out := shl(8, out)
                out := add(out, and(mload(add(tablePtr, and(input, 0x3F))), 0xFF))
                out := shl(224, out)
                mstore(resultPtr, out)
                resultPtr := add(resultPtr, 4)
            }
            switch mod(mload(data), 3)
            case 1 {
                mstore(sub(resultPtr, 2), shl(240, 0x3d3d))
            }
            case 2 {
                mstore(sub(resultPtr, 1), shl(248, 0x3d))
            }
            mstore(result, encodedLen)
        }
        return string(result);
    }
}

library RNXMerkleProof {
    function verify(bytes32[] memory proof, bytes32 root, bytes32 leaf) internal pure returns (bool) {
        bytes32 computed = leaf;
        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 p = proof[i];
            if (computed <= p) computed = keccak256(abi.encodePacked(computed, p));
            else computed = keccak256(abi.encodePacked(p, computed));
        }
        return computed == root;
    }
}

library RNXECDSA {
    function toEthSignedMessageHash(bytes32 hash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
    }

    function recover(bytes32 digest, uint8 v, bytes32 r, bytes32 s) internal pure returns (address) {
        // Enforce lower-s malleability
        if (uint256(s) > 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0) revert RNX_Sig();
        if (v != 27 && v != 28) revert RNX_Sig();
        address signer = ecrecover(digest, v, r, s);
        if (signer == address(0)) revert RNX_Sig();
        return signer;
    }
}

// =============================================================
//                    RAPIDONERD0_X1 CONTRACT
// =============================================================

contract RapidoNerd0_x1 is IERC721Metadata, IERC2981, IERC4494 {
    using RNXStrings for uint256;

    // ---------------------------------------------------------
    // Constants (intentionally non-default)
    // ---------------------------------------------------------

    uint16 private constant _BPS_DENOM = 10_000;
    uint16 private constant _FEE_CAP_BPS = 1_333; // 13.33%
    uint96 private constant _ROYALTY_CAP_BPS = 1_250; // 12.5%

    uint32 private constant _MAX_SUPPLY = 8_888;
    uint16 private constant _MAX_PACKS_PER_TX = 13;
    uint16 private constant _CARDS_PER_PACK = 5;

    uint32 private constant _ALLOWLIST_WALLET_CAP = 7;
    uint32 private constant _PUBLIC_WALLET_CAP = 19;

    uint32 private constant _REVEAL_MIN_DELAY_BLOCKS = 7;
    uint32 private constant _REVEAL_MAX_DELAY_BLOCKS = 9_000;

    uint32 private constant _SEASON_MAX_ACTIVE = 64;
    bytes4 private constant _ERC721_RECEIVED = 0x150b7a02;

    bytes32 private constant _EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract,bytes32 salt)");
    bytes32 private constant _PERMIT_TYPEHASH =
        keccak256("Permit(address spender,uint256 tokenId,uint256 nonce,uint256 deadline)");

    // ---------------------------------------------------------
    // Immutable "embedded" addresses (randomized)
    // ---------------------------------------------------------

    address public immutable BOOT_TREASURY;
    address public immutable BOOT_GUARDIAN;
    address public immutable BOOT_SIGNER;

    // ---------------------------------------------------------
    // Ownership + roles
    // ---------------------------------------------------------

    address public owner;
    address public pendingOwner;
    address public guardian;

    // ---------------------------------------------------------
    // Pausable + reentrancy
    // ---------------------------------------------------------

    bool public paused;
    uint256 private _lock;

    // ---------------------------------------------------------
    // ERC721 storage
    // ---------------------------------------------------------

    string private _n;
    string private _s;

    mapping(uint256 => address) private _ownerOf;
    mapping(address => uint256) private _balanceOf;
    mapping(uint256 => address) private _getApproved;
    mapping(address => mapping(address => bool)) private _isApprovedForAll;

    // ---------------------------------------------------------
    // Metadata + traits
    // ---------------------------------------------------------

    struct CardDNA {
        uint16 palette;
        uint16 foil;
        uint16 emblem;
        uint16 vibe;
        uint16 frame;
        uint16 rarity;
        uint32 bornAt;
        uint32 seasonTag;
        uint64 xp;
    }

    mapping(uint256 => CardDNA) public dnaOf;
    mapping(address => uint256) public pinnedTokenOf;

    // ---------------------------------------------------------
    // Launch configuration
    // ---------------------------------------------------------

    bytes32 public allowlistRoot;

    uint64 public launchStartAt;
    uint64 public allowlistEndAt;
    uint64 public publicEndAt;

    uint256 public allowlistPriceWei;
    uint256 public publicPriceWei;
    uint256 public packPriceWei;

    mapping(address => uint32) public allowlistMinted;
    mapping(address => uint32) public publicMinted;

    uint32 public totalMinted;

    // ---------------------------------------------------------
    // Commit / reveal entropy
    // ---------------------------------------------------------

    struct CommitInfo {
        uint64 revealAfterBlock;
        uint64 madeAt;
        uint32 pendingCards;
        bool revealed;
    }

    mapping(address => mapping(bytes32 => CommitInfo)) public commits;

    // ---------------------------------------------------------
    // Built-in market
    // ---------------------------------------------------------

    struct Listing {
        address seller;
        uint96 price;
        uint64 listedAt;
    }

    mapping(uint256 => Listing) public listingOf;
    uint16 public marketFeeBps;
    address public treasury;

    // ---------------------------------------------------------
    // P2P trade offers
    // ---------------------------------------------------------

    struct Trade {
        address maker;
        address taker;
        uint64 expiresAt;
        uint96 makerEth;
        uint96 takerEth;
        uint256[] makerIds;
        uint256[] takerIds;
        bool executed;
        bool cancelled;
    }

    mapping(bytes32 => Trade) private _trades;

    // ---------------------------------------------------------
