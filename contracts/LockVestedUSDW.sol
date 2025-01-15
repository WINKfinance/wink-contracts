// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.0.0
pragma solidity ^0.8.22;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC721Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import { ERC721BurnableUpgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721BurnableUpgradeable.sol";
import { ERC721EnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { USDW } from "./USDW.sol";
import { VestedUSDW } from "./VestedUSDW.sol";

contract LockVestedUSDW is Initializable, ERC721Upgradeable, ERC721EnumerableUpgradeable, ERC721BurnableUpgradeable, OwnableUpgradeable, UUPSUpgradeable {
    uint256 private _nextTokenId;

    struct Lock {
        uint256 id;              // [unique id]
        uint256 amount;          // [usdw]
        uint256 lockEnd;         // [unit epoch time]
        uint256 lockType;        // [0, 1, 2, 3] => [3 months, 6 months, 12 months, 24 months]
        uint256 baseAPY;         // [ray]
        uint256 rho;             // [unit epoch time]
        uint256 chi;             // [ray]
    }

    struct InitialBonus {
        bool enabled;            // [bool]
        uint32 bonus;            // [0, 100000] => [0%, 100%]
    }

    uint256 private constant RAY = 10 ** 27;

    enum LockPeriod { THREE_MONTHS, SIX_MONTHS, TWELVE_MONTHS, TWENTYFOUR_MONTHS }
    mapping(LockPeriod => uint256) public lockAPY;              // [ray]
    mapping(LockPeriod => InitialBonus) public initialBonuses;  // [InitialBonus]
    
    // maps token id to lock data
    mapping(uint256 => Lock) public data;

    USDW public usdw;
    VestedUSDW public vusdw;

    error AmountMustBeGreaterThanZero();
    error TransferFailed(address from, address to, uint256 amount);
    error InvalidLockPeriod(LockPeriod lockPeriod);

    error CannotUnstakeBeforeLockEnds(uint256 lockId, uint256 lockEnd, uint256 currentTime);

    event Deposit(uint256 tokenId, uint256 amount, LockPeriod lockPeriod);
    event Withdraw(uint256 tokenId);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner, address _usdw, address _vusdw) initializer public {
        __ERC721_init("LockVestedUSDW", "LockVestedUSDW");
        __ERC721Enumerable_init();
        __ERC721Burnable_init();
        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();

        usdw = USDW(_usdw);
        vusdw = VestedUSDW(_vusdw);

        lockAPY[LockPeriod.THREE_MONTHS] =      1000000003022265980097387650; // 10% APY
        lockAPY[LockPeriod.SIX_MONTHS] =        1000000003875495717943815212; // 13% APY
        lockAPY[LockPeriod.TWELVE_MONTHS] =     1000000004706367499604668375; // 16% APY
        lockAPY[LockPeriod.TWENTYFOUR_MONTHS] = 1000000005781378656804591713; // 20% APY

        initialBonuses[LockPeriod.THREE_MONTHS] =      InitialBonus(true, 3000); // bonus disabled
        initialBonuses[LockPeriod.SIX_MONTHS] =        InitialBonus(true, 6000); // bonus disabled
        initialBonuses[LockPeriod.TWELVE_MONTHS] =     InitialBonus(true, 10000); // 10% bonus
        initialBonuses[LockPeriod.TWENTYFOUR_MONTHS] = InitialBonus(true, 10000); // 10% bonus
    }

    function updateLockAPY(LockPeriod _lockPeriod, uint256 _lockAPY) public onlyOwner {
        lockAPY[_lockPeriod] = _lockAPY;
    }

    function updateInitialBonus(LockPeriod _lockPeriod, bool _enabled, uint32 _bonus) public onlyOwner {
        initialBonuses[_lockPeriod] = InitialBonus(_enabled, _bonus);
    }

    function _rpow(uint256 x, uint256 n) internal pure returns (uint256 z) {
        assembly {
            switch x case 0 {switch n case 0 {z := RAY} default {z := 0}}
            default {
                switch mod(n, 2) case 0 { z := RAY } default { z := x }
                let half := div(RAY, 2)  // for rounding.
                for { n := div(n, 2) } n { n := div(n,2) } {
                    let xx := mul(x, x)
                    if iszero(eq(div(xx, x), x)) { revert(0,0) }
                    let xxRound := add(xx, half)
                    if lt(xxRound, xx) { revert(0,0) }
                    x := div(xxRound, RAY)
                    if mod(n,2) {
                        let zx := mul(z, x)
                        if and(iszero(iszero(x)), iszero(eq(div(zx, x), z))) { revert(0,0) }
                        let zxRound := add(zx, half)
                        if lt(zxRound, zx) { revert(0,0) }
                        z := div(zxRound, RAY)
                    }
                }
            }
        }
    }

    function createLock(uint256 _tokenId, uint256 _amount, LockPeriod _lockPeriod) internal {
        // prepares the lock duration based on the lock period
        uint256 lockDuration = 0 days;
        if (_lockPeriod == LockPeriod.THREE_MONTHS) lockDuration = 90 days;
        else if (_lockPeriod == LockPeriod.SIX_MONTHS) lockDuration = 180 days;
        else if (_lockPeriod == LockPeriod.TWELVE_MONTHS) lockDuration = 365 days;
        else if (_lockPeriod == LockPeriod.TWENTYFOUR_MONTHS) lockDuration = 730 days;
        else revert InvalidLockPeriod(_lockPeriod);
        
        data[_tokenId] = Lock({
            id:                 _tokenId,
            amount:             _amount,
            lockEnd:            block.timestamp + lockDuration,
            lockType:           uint256(_lockPeriod),
            baseAPY:            lockAPY[_lockPeriod],
            rho:                block.timestamp,
            // if the early unlock is disabled, the chi is 1.1 (10% more from the start)
            //  _bonusEnabled is to avoid to add another bonus during an upgrade from a lock that already has the bonus
            chi:                RAY * (100000 + initialBonuses[_lockPeriod].bonus) / 100000
        });
    }

    function updateLock(uint256 _tokenId) public {
        Lock storage lock = data[_tokenId];

        (uint256 chi_, uint256 rho_) = (lock.chi, lock.rho);

        // timestamp is the current block timestamp or the lock end timestamp if it's already passed
        uint256 timestamp = block.timestamp > lock.lockEnd ? lock.lockEnd : block.timestamp;
     
        // if the lock is already updated or it has already been updated in this block, return
        if (timestamp > rho_) {

            // calculate the new chi value
            uint256 nChi = _rpow(lock.baseAPY, timestamp - rho_) * chi_ / RAY;
            
            // update the lock
            lock.chi = nChi;
            lock.rho = timestamp;
        }
    }

    function safeMint(uint256 _amount, LockPeriod _lockPeriod) public {
        
        // the deposit must be > 0
        if (_amount <= 0)
            revert AmountMustBeGreaterThanZero();
        // check if the user has enough vUSDW tokens
        if (!vusdw.transferFrom(msg.sender, address(this), _amount))
            revert TransferFailed(msg.sender, address(this), _amount);

        // burn the vUSDW tokens
        vusdw.burn(_amount);
        
        uint256 tokenId = _nextTokenId++;

        // creates the lock in the storage
        createLock(tokenId, _amount, _lockPeriod);

        // mints the token
        _safeMint(msg.sender, tokenId);

        emit Deposit(tokenId, _amount, _lockPeriod);
    }

    function burn(uint256 tokenId) public override(ERC721BurnableUpgradeable) {

        // updates the lock before burning the token
        updateLock(tokenId);

        Lock storage lock = data[tokenId];

        // check if the user can unlock
        if(lock.lockEnd > block.timestamp)
            revert CannotUnstakeBeforeLockEnds(tokenId, lock.lockEnd, block.timestamp);

        // the amount maturated is: deposit * chi / RAY
        uint256 amount = lock.amount * lock.chi / RAY;

        // transfer the USDW tokens to the user
        usdw.mint(ownerOf(tokenId), amount);

        // burn the token
        _update(address(0), tokenId, _msgSender());

        delete data[tokenId];

        emit Withdraw(tokenId);
    }

    // Function to retrieve all tokens owned by an address
    function tokensOwnedBy(address owner) public view returns (uint256[] memory) {
        uint256 balance = balanceOf(owner);
        uint256[] memory tokens = new uint256[](balance);
        for (uint256 i = 0; i < balance; i++) {
            tokens[i] = tokenOfOwnerByIndex(owner, i);
        }
        return tokens;
    }

    function dataOfTokensOwnedBy(address owner) public view returns (Lock[] memory) {
        uint256 balance = balanceOf(owner);
        Lock[] memory locks = new Lock[](balance);
        for (uint256 i = 0; i < balance; i++) {
            locks[i] = data[tokenOfOwnerByIndex(owner, i)];
        }
        return locks;
    }

    function allLockAPY() public view returns (uint256[4] memory) {
        return [lockAPY[LockPeriod.THREE_MONTHS], lockAPY[LockPeriod.SIX_MONTHS], lockAPY[LockPeriod.TWELVE_MONTHS], lockAPY[LockPeriod.TWENTYFOUR_MONTHS]];
    }

    function allInitialBonuses() public view returns (InitialBonus[4] memory) {
        return [initialBonuses[LockPeriod.THREE_MONTHS], initialBonuses[LockPeriod.SIX_MONTHS], initialBonuses[LockPeriod.TWELVE_MONTHS], initialBonuses[LockPeriod.TWENTYFOUR_MONTHS]];
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        onlyOwner
        override
    {}

    // The following functions are overrides required by Solidity.

    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721Upgradeable, ERC721EnumerableUpgradeable)
        returns (address)
    {
        // if not minting or burning
        if(_ownerOf(tokenId) != address(0) && to != address(0))
            updateLock(tokenId);

        return super._update(to, tokenId, auth);
    }

    function _increaseBalance(address account, uint128 value)
        internal
        override(ERC721Upgradeable, ERC721EnumerableUpgradeable)
    {
        super._increaseBalance(account, value);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Upgradeable, ERC721EnumerableUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
