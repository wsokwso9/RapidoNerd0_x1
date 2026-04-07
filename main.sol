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
