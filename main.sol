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
    // Seasons + XP
    // ---------------------------------------------------------

    struct Season {
        uint64 startAt;
        uint64 endAt;
        bytes32 rulesetHash;
        bool closed;
    }

    uint32 public activeSeasonId;
    mapping(uint32 => Season) public seasonOf;
    mapping(uint32 => mapping(address => uint64)) public xpOf;

    // ---------------------------------------------------------
    // Royalty (ERC2981)
    // ---------------------------------------------------------

    address public royaltyReceiver;
    uint96 public royaltyBps;

    // ---------------------------------------------------------
    // EIP-4494 permit
    // ---------------------------------------------------------

    bytes32 private _domainSeparator;
    bytes32 private _domainSalt;
    mapping(uint256 => uint256) private _permitNonces;

    // ---------------------------------------------------------
    // BaseURI lock (to prevent accidental changes)
    // ---------------------------------------------------------

    bytes32 public baseURISalt;
    bool public baseURILocked;
    string private _baseURI;

    // =============================================================
    //                           MODIFIERS
    // =============================================================

    modifier onlyOwner() {
        if (msg.sender != owner) revert RNX_Unauthorized();
        _;
    }

    modifier onlyGuardianOrOwner() {
        if (msg.sender != owner && msg.sender != guardian) revert RNX_Unauthorized();
        _;
    }

    modifier whenActive() {
        if (paused) revert RNX_Paused();
        _;
    }

    modifier nonReentrant() {
        if (_lock == 1) revert RNX_Reentry();
        _lock = 1;
        _;
        _lock = 0;
    }

    // =============================================================
    //                          CONSTRUCTOR
    // =============================================================

    constructor() {
        // Randomized embedded addresses (non-authoritative defaults)
        BOOT_TREASURY = 0x7A2bC3D8c1a2b01fF0aB8E6bC9d2a0F9e8B7c6D5;
        BOOT_GUARDIAN = 0x2d4f9b0A7C12E8aB5cD03f4B9a8e1D2c3B4a5F6E;
        BOOT_SIGNER = 0x9c1A3e7bB2d0F5a6c8E4b1D9F0a2C7e3B5d6A8c9;

        _n = "Rapido Nerd Social Cards";
        _s = "RNX1";

        owner = msg.sender;
        guardian = BOOT_GUARDIAN;
        treasury = BOOT_TREASURY;

        paused = false;
        marketFeeBps = 321; // 3.21%

        royaltyReceiver = BOOT_TREASURY;
        royaltyBps = 777; // 7.77%

        // Launch schedule defaults (can be updated by owner before start)
        launchStartAt = uint64(block.timestamp + 9_333);
        allowlistEndAt = uint64(launchStartAt + 2 days + 3 hours);
        publicEndAt = uint64(allowlistEndAt + 5 days + 11 hours);

        allowlistPriceWei = 0.0033 ether;
        publicPriceWei = 0.0047 ether;
        packPriceWei = 0.0199 ether; // 5 cards * 0.00398-ish with a tiny bundle edge

        allowlistRoot = bytes32(0);

        // Domain separator uses a randomized salt to avoid collisions across forks/tests.
        _domainSalt = keccak256(
            abi.encodePacked(
                uint64(block.timestamp),
                block.prevrandao,
                blockhash(block.number - 1),
                address(this),
                msg.sender
            )
        );
        _domainSeparator = keccak256(
            abi.encode(
                _EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes(_n)),
                keccak256(bytes("1")),
                block.chainid,
                address(this),
                _domainSalt
            )
        );

        // BaseURI starts empty; tokenURI is on-chain.
        _baseURI = "";
        baseURISalt = keccak256(abi.encodePacked(block.chainid, address(this), _domainSalt));
        baseURILocked = false;

        // Season 1 is created but inactive until explicitly opened.
        activeSeasonId = 0;
    }

    receive() external payable {}

    // =============================================================
    //                       ERC165 SUPPORT
    // =============================================================

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IERC721).interfaceId
            || interfaceId == type(IERC721Metadata).interfaceId || interfaceId == type(IERC2981).interfaceId
            || interfaceId == type(IERC4494).interfaceId;
    }

    // =============================================================
    //                       OWNERSHIP (2-step)
    // =============================================================

    function proposeOwner(address next) external onlyOwner {
        if (next == address(0)) revert RNX_BadAddr();
        pendingOwner = next;
        emit RNX_OwnerProposed(owner, next);
    }

    function acceptOwner() external {
        address p = pendingOwner;
        if (p == address(0) || msg.sender != p) revert RNX_Unauthorized();
        address old = owner;
        owner = p;
        pendingOwner = address(0);
        emit RNX_OwnerAccepted(old, p);
    }

    function setGuardian(address next) external onlyOwner {
        if (next == address(0)) revert RNX_BadAddr();
        address old = guardian;
        guardian = next;
        emit RNX_GuardianSet(old, next);
    }

    // =============================================================
    //                         CONTROLS
    // =============================================================

    function setPaused(bool on) external onlyGuardianOrOwner {
        if (paused == on) revert RNX_Same();
        paused = on;
        emit RNX_PauseSet(on);
    }

    function setTreasury(address next) external onlyOwner {
        if (next == address(0)) revert RNX_BadAddr();
        treasury = next;
        emit RNX_TreasurySet(next);
    }

    function setMarketFeeBps(uint16 newFeeBps) external onlyOwner {
        if (newFeeBps > _FEE_CAP_BPS) revert RNX_BadParam();
        if (newFeeBps == marketFeeBps) revert RNX_Same();
        marketFeeBps = newFeeBps;
        emit RNX_FeeSet(newFeeBps);
    }

    function setRoyalty(address receiver, uint96 bps) external onlyOwner {
        if (receiver == address(0)) revert RNX_BadAddr();
        if (bps > _ROYALTY_CAP_BPS) revert RNX_BadParam();
        royaltyReceiver = receiver;
        royaltyBps = bps;
        emit RNX_RoyaltySet(receiver, bps);
    }

    // =============================================================
    //                         LAUNCH CONFIG
    // =============================================================

    function configureLaunch(uint64 startAt, uint64 allowEndAt, uint64 pubEndAt) external onlyOwner {
        if (startAt == 0 || allowEndAt == 0 || pubEndAt == 0) revert RNX_Zero();
        if (!(startAt < allowEndAt && allowEndAt < pubEndAt)) revert RNX_BadParam();
        launchStartAt = startAt;
        allowlistEndAt = allowEndAt;
        publicEndAt = pubEndAt;
        emit RNX_LaunchConfigured(startAt, allowEndAt, pubEndAt);
    }

    function setPrices(uint256 allowlistWei, uint256 publicWei, uint256 packWei) external onlyOwner {
        if (allowlistWei == 0 || publicWei == 0 || packWei == 0) revert RNX_Zero();
        allowlistPriceWei = allowlistWei;
        publicPriceWei = publicWei;
        packPriceWei = packWei;
    }

    function setAllowlistRoot(bytes32 newRoot) external onlyOwner {
        bytes32 old = allowlistRoot;
        allowlistRoot = newRoot;
        emit RNX_RootSet(old, newRoot);
    }

    function lockBaseURI(bytes32 salt) external onlyOwner {
        if (baseURILocked) revert RNX_Already();
        baseURILocked = true;
        baseURISalt = salt;
        emit RNX_BaseURILocked(salt);
    }

    function setBaseURI(string calldata next) external onlyOwner {
        if (baseURILocked) revert RNX_BadState();
        _baseURI = next;
    }

    // =============================================================
    //                           ERC721
    // =============================================================

    function name() external view returns (string memory) {
        return _n;
    }

    function symbol() external view returns (string memory) {
        return _s;
    }

    function balanceOf(address who) external view returns (uint256) {
        if (who == address(0)) revert RNX_BadAddr();
        return _balanceOf[who];
    }

    function ownerOf(uint256 tokenId) public view returns (address) {
        address o = _ownerOf[tokenId];
        if (o == address(0)) revert RNX_NotFound();
        return o;
    }

    function getApproved(uint256 tokenId) external view returns (address) {
        if (_ownerOf[tokenId] == address(0)) revert RNX_NotFound();
        return _getApproved[tokenId];
    }

    function isApprovedForAll(address o, address operator) external view returns (bool) {
        return _isApprovedForAll[o][operator];
    }

    function approve(address to, uint256 tokenId) external {
        address o = ownerOf(tokenId);
        if (msg.sender != o && !_isApprovedForAll[o][msg.sender]) revert RNX_NotOwnerNorApproved();
        _getApproved[tokenId] = to;
        emit Approval(o, to, tokenId);
    }

    function setApprovalForAll(address operator, bool approved) external {
        _isApprovedForAll[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function transferFrom(address from, address to, uint256 tokenId) public {
        if (to == address(0)) revert RNX_BadAddr();
        address o = ownerOf(tokenId);
        if (o != from) revert RNX_BadParam();
        if (msg.sender != o && msg.sender != _getApproved[tokenId] && !_isApprovedForAll[o][msg.sender]) {
            revert RNX_NotOwnerNorApproved();
        }
        _beforeTokenTransfer(from, to, tokenId);
        unchecked {
            _balanceOf[from] -= 1;
            _balanceOf[to] += 1;
        }
        _ownerOf[tokenId] = to;
        delete _getApproved[tokenId];
        emit Transfer(from, to, tokenId);
        _afterTokenTransfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        safeTransferFrom(from, to, tokenId, "");
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public {
        transferFrom(from, to, tokenId);
        if (to.code.length != 0) {
            bytes4 r = IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, data);
            if (r != _ERC721_RECEIVED) revert RNX_UnsafeRecipient();
        }
    }

    // =============================================================
    //                      EIP-4494 PERMIT
    // =============================================================

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparator;
    }

    function nonces(uint256 tokenId) external view returns (uint256) {
        if (_ownerOf[tokenId] == address(0)) revert RNX_NotFound();
        return _permitNonces[tokenId];
    }

    function permit(address spender, uint256 tokenId, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external {
        if (block.timestamp > deadline) revert RNX_Expired();
        address o = ownerOf(tokenId);
        uint256 nonce = _permitNonces[tokenId];
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                _domainSeparator,
                keccak256(abi.encode(_PERMIT_TYPEHASH, spender, tokenId, nonce, deadline))
            )
        );
        address signer = RNXECDSA.recover(digest, v, r, s);
        if (signer != o && !_isApprovedForAll[o][signer]) revert RNX_Sig();
        unchecked {
            _permitNonces[tokenId] = nonce + 1;
        }
        _getApproved[tokenId] = spender;
        emit Approval(o, spender, tokenId);
    }

    // =============================================================
    //                           MINTING
    // =============================================================

    function _now() private view returns (uint64) {
        return uint64(block.timestamp);
    }

    function _inAllowlist() private view returns (bool) {
        uint64 t = _now();
        return t >= launchStartAt && t < allowlistEndAt;
    }

    function _inPublic() private view returns (bool) {
        uint64 t = _now();
        return t >= allowlistEndAt && t < publicEndAt;
    }

    function _mintCard(address to) private returns (uint256 tokenId) {
        if (to == address(0)) revert RNX_BadAddr();
        if (totalMinted >= _MAX_SUPPLY) revert RNX_SoldOut();
        unchecked {
            totalMinted += 1;
        }
        tokenId = totalMinted;
        _beforeTokenTransfer(address(0), to, tokenId);
        _ownerOf[tokenId] = to;
        unchecked {
            _balanceOf[to] += 1;
        }
        // Initialize with placeholder DNA; reveal later fills traits.
        dnaOf[tokenId] = CardDNA({
            palette: 0,
            foil: 0,
            emblem: 0,
            vibe: 0,
            frame: 0,
            rarity: 0,
            bornAt: uint32(block.timestamp),
            seasonTag: activeSeasonId,
            xp: 0
        });
        emit Transfer(address(0), to, tokenId);
        _afterTokenTransfer(address(0), to, tokenId);
    }

    function mintAllowlist(uint32 qty, uint32 maxQty, bytes32[] calldata proof) external payable whenActive nonReentrant {
        if (!_inAllowlist()) revert RNX_NotReady();
        if (qty == 0) revert RNX_Zero();
        if (qty > 12) revert RNX_Maxed();
        if (allowlistRoot == bytes32(0)) revert RNX_NotReady();

        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, maxQty));
        if (!RNXMerkleProof.verify(_copyProof(proof), allowlistRoot, leaf)) revert RNX_InvalidProof();

        uint32 minted = allowlistMinted[msg.sender];
        if (minted + qty > RNXMath.min(maxQty, _ALLOWLIST_WALLET_CAP)) revert RNX_Maxed();

        uint256 cost = uint256(qty) * allowlistPriceWei;
        if (msg.value != cost) revert RNX_BadPrice();

        allowlistMinted[msg.sender] = minted + qty;
        for (uint32 i = 0; i < qty; i++) {
            _mintCard(msg.sender);
        }
        emit RNX_MintTicket(msg.sender, qty, cost);
    }

    function mintPublic(uint32 qty) external payable whenActive nonReentrant {
        if (!_inPublic()) revert RNX_NotReady();
        if (qty == 0) revert RNX_Zero();
        if (qty > 17) revert RNX_Maxed();

        uint32 minted = publicMinted[msg.sender];
        if (minted + qty > _PUBLIC_WALLET_CAP) revert RNX_Maxed();

        uint256 cost = uint256(qty) * publicPriceWei;
        if (msg.value != cost) revert RNX_BadPrice();

        publicMinted[msg.sender] = minted + qty;
        for (uint32 i = 0; i < qty; i++) {
            _mintCard(msg.sender);
        }
        emit RNX_MintTicket(msg.sender, qty, cost);
    }

    function mintPacks(uint16 packs) external payable whenActive nonReentrant {
        if (!_inPublic()) revert RNX_NotReady();
        if (packs == 0) revert RNX_Zero();
        if (packs > _MAX_PACKS_PER_TX) revert RNX_Maxed();
        uint32 cards = uint32(packs) * uint32(_CARDS_PER_PACK);
        if (totalMinted + cards > _MAX_SUPPLY) revert RNX_SoldOut();

        uint256 cost = uint256(packs) * packPriceWei;
        if (msg.value != cost) revert RNX_BadPrice();

        // Packs do not count toward public wallet cap (intentional: packs are the game product).
        for (uint32 i = 0; i < cards; i++) {
            _mintCard(msg.sender);
        }
        emit RNX_PackMint(msg.sender, packs, cards, cost);
    }

    // =============================================================
    //                      COMMIT / REVEAL
    // =============================================================

    function commitInk(bytes32 commitment, uint32 pendingCards, uint32 delayBlocks) external whenActive {
        if (commitment == bytes32(0)) revert RNX_Zero();
        if (pendingCards == 0) revert RNX_Zero();
        if (delayBlocks < _REVEAL_MIN_DELAY_BLOCKS || delayBlocks > _REVEAL_MAX_DELAY_BLOCKS) revert RNX_BadParam();

        CommitInfo storage c = commits[msg.sender][commitment];
        if (c.madeAt != 0) revert RNX_Already();

        uint64 revealAfter = uint64(block.number + delayBlocks);
        commits[msg.sender][commitment] =
            CommitInfo({revealAfterBlock: revealAfter, madeAt: uint64(block.timestamp), pendingCards: pendingCards, revealed: false});

        emit RNX_Commit(msg.sender, commitment, revealAfter);
    }

    function revealInk(bytes32 commitment, bytes32 secret, uint256[] calldata tokenIds) external whenActive nonReentrant {
        CommitInfo storage c = commits[msg.sender][commitment];
        if (c.madeAt == 0) revert RNX_NotFound();
        if (c.revealed) revert RNX_Already();
        if (block.number < c.revealAfterBlock) revert RNX_TooSoon();
        if (tokenIds.length == 0) revert RNX_Zero();

        bytes32 expected = keccak256(abi.encodePacked(msg.sender, secret));
        if (expected != commitment) revert RNX_BadParam();

        uint32 want = c.pendingCards;
        uint32 take = uint32(RNXMath.min(tokenIds.length, want));
        uint256 entropy = uint256(
            keccak256(
                abi.encodePacked(
                    secret,
                    blockhash(c.revealAfterBlock - 1),
                    block.prevrandao,
                    block.chainid,
                    address(this),
                    msg.sender
                )
            )
        );

        for (uint32 i = 0; i < take; i++) {
            uint256 id = tokenIds[i];
            if (ownerOf(id) != msg.sender) revert RNX_Unauthorized();
            _applyEntropyToCard(id, uint256(keccak256(abi.encodePacked(entropy, id, i))));
        }

        c.revealed = true;
        emit RNX_Reveal(msg.sender, commitment, entropy, take);
    }

    function _applyEntropyToCard(uint256 tokenId, uint256 e) private {
        // Do not overwrite if already revealed (rarity != 0 acts as a sentinel).
        CardDNA storage d = dnaOf[tokenId];
        if (d.rarity != 0) return;

        uint16 roll = uint16(e % 10_000);
        uint16 rarity;
        // Nonlinear rarity table (intentionally not round numbers).
        if (roll < 31) rarity = 6; // Mythic
        else if (roll < 227) rarity = 5; // Legendary
        else if (roll < 991) rarity = 4; // Epic
        else if (roll < 2_701) rarity = 3; // Rare
        else if (roll < 5_713) rarity = 2; // Uncommon
        else rarity = 1; // Common

        uint16 palette = uint16((e >> 16) % 97);
        uint16 foil = uint16((e >> 32) % 11);
        uint16 emblem = uint16((e >> 48) % 61);
        uint16 vibe = uint16((e >> 64) % 73);
        uint16 frame = uint16((e >> 80) % 29);

        d.palette = palette;
        d.foil = foil;
        d.emblem = emblem;
        d.vibe = vibe;
        d.frame = frame;
        d.rarity = rarity;
    }

    // =============================================================
    //                         SOCIAL GAME
    // =============================================================

    function pinBadge(uint256 tokenId, uint32 seasonId) external whenActive {
        if (seasonId == 0) revert RNX_BadParam();
        if (ownerOf(tokenId) != msg.sender) revert RNX_Unauthorized();
        Season memory s0 = seasonOf[seasonId];
        if (s0.startAt == 0) revert RNX_NotFound();
        pinnedTokenOf[msg.sender] = tokenId;
        dnaOf[tokenId].seasonTag = seasonId;
        emit RNX_BadgePinned(msg.sender, tokenId, seasonId);
    }

    function grantXP(address player, uint64 amount, bytes32 reason) external whenActive onlyGuardianOrOwner {
        if (player == address(0)) revert RNX_BadAddr();
        if (amount == 0) revert RNX_Zero();
        uint32 sid = activeSeasonId;
        if (sid == 0) revert RNX_NotReady();
        Season memory s0 = seasonOf[sid];
        if (s0.closed) revert RNX_BadState();
        if (_now() < s0.startAt || _now() > s0.endAt) revert RNX_BadState();

        xpOf[sid][player] += amount;
        uint256 pinned = pinnedTokenOf[player];
        if (pinned != 0 && _ownerOf[pinned] == player) {
            dnaOf[pinned].xp += amount;
        }
        emit RNX_XPGranted(player, sid, amount, reason);
    }

    function openSeason(uint64 startAt, uint64 endAt, bytes32 rulesetHash) external onlyOwner {
        if (startAt == 0 || endAt == 0) revert RNX_Zero();
        if (!(startAt < endAt)) revert RNX_BadParam();
        if (rulesetHash == bytes32(0)) revert RNX_Zero();

        uint32 next = activeSeasonId + 1;
        if (next > _SEASON_MAX_ACTIVE) revert RNX_Maxed();

        seasonOf[next] = Season({startAt: startAt, endAt: endAt, rulesetHash: rulesetHash, closed: false});
        activeSeasonId = next;
        emit RNX_SeasonOpened(next, startAt, endAt, rulesetHash);
    }

    function closeSeason(uint32 seasonId, bytes32 settlementHash) external onlyOwner {
        Season storage s0 = seasonOf[seasonId];
        if (s0.startAt == 0) revert RNX_NotFound();
        if (s0.closed) revert RNX_Already();
        s0.closed = true;
        emit RNX_SeasonClosed(seasonId, settlementHash);
    }

    // =============================================================
    //                           MARKET
    // =============================================================

    function list(uint256 tokenId, uint256 priceWei) external whenActive {
        if (priceWei == 0) revert RNX_Zero();
        if (priceWei > type(uint96).max) revert RNX_BadParam();
        address o = ownerOf(tokenId);
        if (o != msg.sender) revert RNX_Unauthorized();
        if (listingOf[tokenId].seller != address(0)) revert RNX_Already();

        // Require approval so purchase can transfer.
        if (_getApproved[tokenId] != address(this) && !_isApprovedForAll[o][address(this)]) revert RNX_NotReady();

        listingOf[tokenId] = Listing({seller: msg.sender, price: uint96(priceWei), listedAt: uint64(block.timestamp)});
        emit RNX_Listed(tokenId, msg.sender, priceWei);
    }

    function delist(uint256 tokenId) external {
        Listing memory l = listingOf[tokenId];
        if (l.seller == address(0)) revert RNX_NotFound();
        if (msg.sender != l.seller && msg.sender != owner && msg.sender != guardian) revert RNX_Unauthorized();
        delete listingOf[tokenId];
        emit RNX_Delisted(tokenId, l.seller);
    }

    function buy(uint256 tokenId) external payable whenActive nonReentrant {
        Listing memory l = listingOf[tokenId];
        if (l.seller == address(0)) revert RNX_NotFound();
        if (msg.sender == l.seller) revert RNX_BadParam();
        uint256 price = uint256(l.price);
        if (msg.value != price) revert RNX_BadPrice();

        // Ensure still owned by seller.
        if (_ownerOf[tokenId] != l.seller) revert RNX_BadState();

        delete listingOf[tokenId];

        (address rr, uint256 royaltyAmt) = _royaltyInfo(tokenId, price);
        uint256 fee = (price * marketFeeBps) / _BPS_DENOM;

        uint256 sellerProceeds = price;
        if (royaltyAmt != 0) sellerProceeds -= royaltyAmt;
        if (fee != 0) sellerProceeds -= fee;

        // Transfer token first to reduce griefing via reverts in recipient fallback.
        transferFrom(l.seller, msg.sender, tokenId);

        if (royaltyAmt != 0) _send(payable(rr), royaltyAmt);
        if (fee != 0) _send(payable(treasury), fee);
        _send(payable(l.seller), sellerProceeds);

        emit RNX_Purchased(tokenId, l.seller, msg.sender, price, fee);
    }

    // =============================================================
    //                       P2P TRADES
    // =============================================================

    function tradeGet(bytes32 tradeId)
        external
        view
        returns (
            address maker,
            address taker,
            uint64 expiresAt,
            uint96 makerEth,
            uint96 takerEth,
            uint256 makerCount,
            uint256 takerCount,
            bool executed,
            bool cancelled
        )
    {
        Trade storage t = _trades[tradeId];
        if (t.maker == address(0)) revert RNX_NotFound();
        return (t.maker, t.taker, t.expiresAt, t.makerEth, t.takerEth, t.makerIds.length, t.takerIds.length, t.executed, t.cancelled);
    }

    function tradeIds(bytes32 tradeId) external view returns (uint256[] memory makerIds, uint256[] memory takerIds) {
        Trade storage t = _trades[tradeId];
        if (t.maker == address(0)) revert RNX_NotFound();
        return (t.makerIds, t.takerIds);
    }

    function openTrade(
        address taker,
        uint64 expiresAt,
        uint256[] calldata makerIds,
        uint256[] calldata takerIds,
        uint96 makerEth,
        uint96 takerEth,
        bytes32 salt
    ) external payable whenActive nonReentrant returns (bytes32 tradeId) {
        if (expiresAt <= _now()) revert RNX_Expired();
        if (makerIds.length == 0 && makerEth == 0) revert RNX_Zero();
        if (takerIds.length == 0 && takerEth == 0) revert RNX_Zero();
        if (makerEth != msg.value) revert RNX_BadPrice();

        tradeId = keccak256(abi.encodePacked(address(this), msg.sender, taker, expiresAt, makerIds, takerIds, makerEth, takerEth, salt));
        Trade storage t = _trades[tradeId];
        if (t.maker != address(0)) revert RNX_Already();

        // Validate maker ownership and approvals.
        for (uint256 i = 0; i < makerIds.length; i++) {
            uint256 id = makerIds[i];
            if (ownerOf(id) != msg.sender) revert RNX_Unauthorized();
            if (_getApproved[id] != address(this) && !_isApprovedForAll[msg.sender][address(this)]) revert RNX_NotReady();
        }

        // Trade can be open to a specific taker or to anyone (taker == 0).
        _trades[tradeId] = Trade({
            maker: msg.sender,
            taker: taker,
            expiresAt: expiresAt,
            makerEth: makerEth,
            takerEth: takerEth,
            makerIds: _copyIds(makerIds),
            takerIds: _copyIds(takerIds),
            executed: false,
            cancelled: false
        });

        emit RNX_TradeOpened(tradeId, msg.sender, taker);
    }

    function cancelTrade(bytes32 tradeId) external nonReentrant {
        Trade storage t = _trades[tradeId];
        if (t.maker == address(0)) revert RNX_NotFound();
        if (msg.sender != t.maker && msg.sender != owner && msg.sender != guardian) revert RNX_Unauthorized();
        if (t.executed) revert RNX_BadState();
        if (t.cancelled) revert RNX_Already();
        t.cancelled = true;

        // Refund maker ETH if any.
        if (t.makerEth != 0) _send(payable(t.maker), uint256(t.makerEth));

        emit RNX_TradeCancelled(tradeId, t.maker);
    }

    function executeTrade(bytes32 tradeId) external payable whenActive nonReentrant {
        Trade storage t = _trades[tradeId];
        if (t.maker == address(0)) revert RNX_NotFound();
        if (t.executed) revert RNX_BadState();
        if (t.cancelled) revert RNX_BadState();
        if (_now() > t.expiresAt) revert RNX_Expired();
        if (t.taker != address(0) && msg.sender != t.taker) revert RNX_Unauthorized();
        if (uint256(t.takerEth) != msg.value) revert RNX_BadPrice();

        // Validate taker ownership and approvals.
        for (uint256 i = 0; i < t.takerIds.length; i++) {
            uint256 id = t.takerIds[i];
            if (ownerOf(id) != msg.sender) revert RNX_Unauthorized();
            if (_getApproved[id] != address(this) && !_isApprovedForAll[msg.sender][address(this)]) revert RNX_NotReady();
        }

        // Re-validate maker still owns their tokens.
        for (uint256 i = 0; i < t.makerIds.length; i++) {
            uint256 id = t.makerIds[i];
            if (ownerOf(id) != t.maker) revert RNX_BadState();
        }

        t.executed = true;

        // Swap NFTs.
        for (uint256 i = 0; i < t.makerIds.length; i++) {
            transferFrom(t.maker, msg.sender, t.makerIds[i]);
        }
        for (uint256 i = 0; i < t.takerIds.length; i++) {
            transferFrom(msg.sender, t.maker, t.takerIds[i]);
        }

        // Swap ETH (makerEth held in contract; takerEth just arrived as msg.value).
        if (t.takerEth != 0) _send(payable(t.maker), uint256(t.takerEth));
        if (t.makerEth != 0) _send(payable(msg.sender), uint256(t.makerEth));

        emit RNX_TradeExecuted(tradeId, t.maker, msg.sender);
    }

    // =============================================================
    //                          TOKEN URI
    // =============================================================

    function tokenURI(uint256 tokenId) external view returns (string memory) {
        if (_ownerOf[tokenId] == address(0)) revert RNX_NotFound();

        CardDNA memory d = dnaOf[tokenId];
        string memory title = string(abi.encodePacked("RNX Card #", tokenId.toString()));
        string memory desc =
            "A social-trading card from Paper Arcades. Pin it, earn XP in seasons, list it, trade it, flex it.";

        string memory svg = _svgFor(tokenId, d);
        string memory image = string(abi.encodePacked("data:image/svg+xml;base64,", RNXBase64.encode(bytes(svg))));

        string memory json = string(
            abi.encodePacked(
                '{"name":"',
                title,
                '","description":"',
                desc,
                '","image":"',
                image,
                '","attributes":[',
                _attr("Rarity", _rarityName(d.rarity), true),
                ",",
                _attr("Palette", d.palette.toString(), true),
                ",",
                _attr("Foil", d.foil.toString(), true),
                ",",
                _attr("Emblem", d.emblem.toString(), true),
                ",",
                _attr("Vibe", d.vibe.toString(), true),
                ",",
                _attr("Frame", d.frame.toString(), true),
                ",",
                _attr("SeasonTag", uint256(d.seasonTag).toString(), true),
                ",",
                _attr("XP", uint256(d.xp).toString(), false),
                ']}'
            )
        );

        // Optional external baseURI hint for indexers (doesn't change image/metadata correctness).
        if (bytes(_baseURI).length != 0) {
            string memory hint = string(abi.encodePacked(_baseURI, tokenId.toString(), "?salt=", uint256(baseURISalt).toString()));
