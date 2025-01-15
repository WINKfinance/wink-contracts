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
import { IWhitelistRegistration } from "./IWhitelistRegistration.sol";
import { IObserver } from "./IObserver.sol";

contract LockUSDW is Initializable, ERC721Upgradeable, ERC721EnumerableUpgradeable, ERC721BurnableUpgradeable, OwnableUpgradeable, UUPSUpgradeable, IObserver {
    uint256 private _nextTokenId;

    struct Lock {
        uint256 id;              // [unique id]
        uint256 amount;          // [usdw]
        uint256 lockEnd;         // [unit epoch time]
        uint256 lockType;        // [0, 1, 2, 3] => [3 months, 6 months, 12 months, 24 months]
        uint256 baseAPY;         // [ray]
        uint256 invitedAPY;      // [ray]
        uint256 referralAPY;     // [ray]
        uint256 rho;             // [unit epoch time]
        uint256 chi;             // [ray]
        uint256 refChi;          // [ray]
        bool disableEarlyUnlock; // [bool]
    }

    struct InitialBonus {
        bool enabled;            // [bool]
        uint32 bonus;            // [0, 100000] => [0%, 100%]
    }

    uint256 private constant RAY = 10 ** 27;

    enum LockPeriod { THREE_MONTHS, SIX_MONTHS, TWELVE_MONTHS, TWENTYFOUR_MONTHS }
    mapping(LockPeriod => uint256) public lockAPY;              // [ray]
    mapping(LockPeriod => uint256) public referralAPY;          // [ray]
    mapping(LockPeriod => uint256) public invitedLockAPY;       // [ray]
    mapping(LockPeriod => InitialBonus) public initialBonuses;  // [InitialBonus]

    uint256 public penaltyPerc; // [ray]

    // maps token id to lock data
    mapping(uint256 => Lock) public data;

    USDW public usdw;
    IWhitelistRegistration public whitelist;

    error AmountMustBeGreaterThanZero();
    error TransferFailed(address from, address to, uint256 amount);
    error InvalidLockPeriod(LockPeriod lockPeriod);

    error CannotUnstakeBeforeLockEnds(uint256 lockId, uint256 lockEnd, uint256 currentTime);
    error CannotUpgradeToShorterPeriod(uint256 lockId, uint256 currentType, uint256 newType);
    error CannotUpgradeToEnabledEarlyUnlock(uint256 lockId);

    event Deposit(uint256 tokenId, uint256 amount, LockPeriod lockPeriod, bool disableEarlyUnlock);
    event Renewed(uint256 tokenId, uint256 amount, LockPeriod lockPeriod, bool disableEarlyUnlock);
    event Withdraw(uint256 tokenId);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner, address _usdw, address _whitelist) initializer public {
        __ERC721_init("LockUSDW", "LockUSDW");
        __ERC721Enumerable_init();
        __ERC721Burnable_init();
        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();

        usdw = USDW(_usdw);
        whitelist = IWhitelistRegistration(_whitelist);
        penaltyPerc = 3_805_175_038_051_750_381; // 12% per year - already divided by 100 

        lockAPY[LockPeriod.THREE_MONTHS] =      1000000003022265980097387650; // 10% APY
        lockAPY[LockPeriod.SIX_MONTHS] =        1000000003875495717943815212; // 13% APY
        lockAPY[LockPeriod.TWELVE_MONTHS] =     1000000004706367499604668375; // 16% APY
        lockAPY[LockPeriod.TWENTYFOUR_MONTHS] = 1000000005781378656804591713; // 20% APY
                                               
        referralAPY[LockPeriod.THREE_MONTHS] =      1000000000627937192491029810; // 2% APY
        referralAPY[LockPeriod.SIX_MONTHS] =        1000000000937303470807876290; // 3% APY
        referralAPY[LockPeriod.TWELVE_MONTHS] =     1000000001243680656318820313; // 4% APY
        referralAPY[LockPeriod.TWENTYFOUR_MONTHS] = 1000000001547125957863212449; // 5% APY

        invitedLockAPY[LockPeriod.THREE_MONTHS] =      1000000003593629043335673582; // 12% APY
        invitedLockAPY[LockPeriod.SIX_MONTHS] =        1000000004431822129783699001; // 15% APY
        invitedLockAPY[LockPeriod.TWELVE_MONTHS] =     1000000005248428428206454011; // 18% APY
        invitedLockAPY[LockPeriod.TWENTYFOUR_MONTHS] = 1000000006305519386481930552; // 22% APY

        initialBonuses[LockPeriod.THREE_MONTHS] =      InitialBonus(false, 0); // bonus disabled
        initialBonuses[LockPeriod.SIX_MONTHS] =        InitialBonus(false, 0); // bonus disabled
        initialBonuses[LockPeriod.TWELVE_MONTHS] =     InitialBonus(true, 10000); // 10% bonus
        initialBonuses[LockPeriod.TWENTYFOUR_MONTHS] = InitialBonus(true, 10000); // 10% bonus
    }

    function setWhitelist(address _whitelist) public onlyOwner {
        whitelist = IWhitelistRegistration(_whitelist);
    }

    function setPenaltyPerc(uint256 _penaltyPerc) public onlyOwner {
        penaltyPerc = _penaltyPerc;
    }

    function updateLockAPY(LockPeriod _lockPeriod, uint256 _lockAPY) public onlyOwner {
        lockAPY[_lockPeriod] = _lockAPY;
    }

    function updateReferralAPY(LockPeriod _lockPeriod, uint256 _referralAPY) public onlyOwner {
        referralAPY[_lockPeriod] = _referralAPY;
    }

    function updateInvitedAPY(LockPeriod _lockPeriod, uint256 _invitedLockAPY) public onlyOwner {
        invitedLockAPY[_lockPeriod] = _invitedLockAPY;
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

    // triggered by whitelist changes
    function notify(address[] memory interestedAddresses) external {
        for(uint i = 0; i < interestedAddresses.length; i++) {
            uint256[] memory tokens = tokensOwnedBy(interestedAddresses[i]);

            for(uint j = 0; j < tokens.length; j++) {
                updateLock(tokens[j]);
            }
        }
    }

    function createLock(uint256 _tokenId, uint256 _amount, LockPeriod _lockPeriod, bool _disableEarlyUnlock, bool _bonusEnabled) internal {
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
            invitedAPY:         invitedLockAPY[_lockPeriod],
            referralAPY:        referralAPY[_lockPeriod],
            rho:                block.timestamp,
            // if the early unlock is disabled, the chi is 1.1 (10% more from the start)
            //  _bonusEnabled is to avoid to add another bonus during an upgrade from a lock that already has the bonus
            chi:                RAY * (_disableEarlyUnlock && _bonusEnabled ? (100000 + initialBonuses[_lockPeriod].bonus) : 100000) / 100000,
            refChi:             RAY,
            disableEarlyUnlock: _disableEarlyUnlock
        });
    }

    function upgradeLock(uint256 _tokenId, LockPeriod _lockPeriod, bool _disableEarlyUnlock) public {
        // checks if the sender is authorized (owner or allowed)
        _checkAuthorized(_ownerOf(_tokenId), _msgSender(), _tokenId);

        // if the lock has a longer period than the new one, revert
        if(data[_tokenId].lockType >= uint256(_lockPeriod))
            revert CannotUpgradeToShorterPeriod(_tokenId, data[_tokenId].lockType, uint256(_lockPeriod));

        // the early unlock cannot be enabled if disabled in the current plan
        // the user can disable the early unlock if enabled in the current plan
        // or keep the same status

        if (data[_tokenId].disableEarlyUnlock && !_disableEarlyUnlock)
            // if the user wants to upgrade to an early unlock, but the current lock doesn't allow it, revert
            revert CannotUpgradeToEnabledEarlyUnlock(_tokenId);
        else if (!data[_tokenId].disableEarlyUnlock && _disableEarlyUnlock)
            /// if the user wants to upgrade to a lock without early unlock, but the current lock allows it, check if the initial bonus is enabled
            _disableEarlyUnlock = _disableEarlyUnlock && initialBonuses[_lockPeriod].enabled;

        // in the other case (both locks have the same early unlock status), the new status is the same as the old one

        // updates the lock
        updateLock(_tokenId);

        // get the amount maturated of the lock plus the deposit
        uint256 amount = data[_tokenId].amount * data[_tokenId].chi / RAY;

        // mints the amount difference to the current contract
        usdw.mint(address(this), amount - data[_tokenId].amount);

        // creates a new lock with the same amount and the new lock period
        //  the _bonusEnabled variable (which allows to avoid to add another bonus during an upgrade from a lock that already has the bonus)
        //  is enabled only if the user want to change the condition of the early unlock, which means that the user wants to disable it
        //  because the other scenario (enabling the early unlock starting from a disabled one) is not allowed
        createLock(_tokenId, amount, _lockPeriod, _disableEarlyUnlock, data[_tokenId].disableEarlyUnlock != _disableEarlyUnlock);

        emit Renewed(_tokenId, amount, _lockPeriod, _disableEarlyUnlock);
    }

    function renewLock(uint256 _tokenId, LockPeriod _lockPeriod, bool _disableEarlyUnlock) public {
        
        // checks if the sender is authorized (owner or allowed)
        _checkAuthorized(_ownerOf(_tokenId), _msgSender(), _tokenId);

        // if the lock is not ended revert
        if (data[_tokenId].lockEnd > block.timestamp)
            revert CannotUnstakeBeforeLockEnds(_tokenId, data[_tokenId].lockEnd, block.timestamp);

        // updates the lock
        updateLock(_tokenId);

        // get the amount maturated of the lock plus the deposit
        uint256 amount = data[_tokenId].amount * data[_tokenId].chi / RAY;

        // mints the amount difference to the current contract
        usdw.mint(address(this), amount - data[_tokenId].amount);
        
        // the early unlock (additional bonus) is disabled if:
        //                    the user doesn't want to
        //                                           the initial bonus is disabled 
        _disableEarlyUnlock = _disableEarlyUnlock && initialBonuses[_lockPeriod].enabled;

        // creates a new lock with the same amount and the new lock period
        //  the bonus is considered because is like doing another deposit
        createLock(_tokenId, amount, _lockPeriod, _disableEarlyUnlock, true);

        emit Renewed(_tokenId, amount, _lockPeriod, _disableEarlyUnlock);
    }

    function updateLock(uint256 _tokenId) public {
        Lock storage lock = data[_tokenId];

        address owner = ownerOf(_tokenId);

        (uint256 chi_, uint256 refChi_, uint256 rho_, uint256 amount_) = (lock.chi, lock.refChi, lock.rho, lock.amount);
        uint256 base;

        // timestamp is the current block timestamp or the lock end timestamp if it's already passed
        uint256 timestamp = block.timestamp > lock.lockEnd ? lock.lockEnd : block.timestamp;
     
        // if the lock is already updated or it has already been updated in this block, return
        if (timestamp > rho_) {
            // get the representative of the user
            address representative = whitelist.getRepresentative(owner);

            if(representative != address(0)) {
                // if the user has a representative, the APY is the invited one
                base = lock.invitedAPY;

                // calculate the new referral chi value
                uint256 nRefChi = _rpow(lock.referralAPY, timestamp - rho_) * refChi_ / RAY;

                // calculate the difference between the new and the old referral amount
                uint256 diff = nRefChi * amount_ / RAY - refChi_ * amount_ / RAY;

                // mint the USDW tokens to the representative
                usdw.mint(representative, diff);

                // update the refChi value
                lock.refChi = nRefChi;
            } else {
                // otherwise, the APY is the base one
                base = lock.baseAPY;
            }
            
            // calculate the new chi value
            uint256 nChi = _rpow(base, timestamp - rho_) * chi_ / RAY;
            
            // update the lock
            lock.chi = nChi;
            lock.rho = timestamp;
        }
        
        // update the APY based on referral and WINK possession
    }

    function safeMint(uint256 _amount, LockPeriod _lockPeriod, bool _disableEarlyUnlock, address _receiver) public {
        
        // the deposit must be > 0
        if (_amount <= 0)
            revert AmountMustBeGreaterThanZero();
        // check if the user has enough USDW tokens
        if (!usdw.transferFrom(msg.sender, address(this), _amount))
            revert TransferFailed(msg.sender, address(this), _amount);
        
        uint256 tokenId = _nextTokenId++;

        // the early unlock (additional bonus) is disabled if:
        //                    the user doesn't want to
        //                                           the initial bonus is disabled 
        _disableEarlyUnlock = _disableEarlyUnlock && initialBonuses[_lockPeriod].enabled;

        createLock(tokenId, _amount, _lockPeriod, _disableEarlyUnlock, true);

        _safeMint(_receiver, tokenId);

        emit Deposit(tokenId, _amount, _lockPeriod, _disableEarlyUnlock);
    }

    function burn(uint256 tokenId) public override(ERC721BurnableUpgradeable) {

        // updates the lock before burning the token
        updateLock(tokenId);

        Lock storage lock = data[tokenId];

        // check if the user can unlock
        if(lock.lockEnd > block.timestamp && lock.disableEarlyUnlock)
            revert CannotUnstakeBeforeLockEnds(tokenId, lock.lockEnd, block.timestamp);

        // the amount maturated is: deposit * chi / RAY
        uint256 amount = lock.amount * lock.chi / RAY;

        // calculate the penalty if the lock is still active
        if(lock.lockEnd > block.timestamp) {
            // calculate the penalty linearly
            //                >10^18   >10^20        <=10^7                             =10^27
            uint256 penalty = amount * penaltyPerc * (lock.lockEnd - block.timestamp) / RAY;
            amount -= penalty;
        }

        // burn USDW if the given amount is bigger than the deposited
        if(lock.amount > amount) {
            usdw.burn(lock.amount - amount);
        } else if (lock.amount < amount) {
            usdw.mint(address(this), amount - lock.amount);
        }

        // transfer the USDW tokens to the user
        if (!usdw.transfer(ownerOf(tokenId), amount))
            revert TransferFailed(address(this), ownerOf(tokenId), amount);

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

    function allReferralAPY() public view returns (uint256[4] memory) {
        return [referralAPY[LockPeriod.THREE_MONTHS], referralAPY[LockPeriod.SIX_MONTHS], referralAPY[LockPeriod.TWELVE_MONTHS], referralAPY[LockPeriod.TWENTYFOUR_MONTHS]];
    }

    function allInvitedAPY() public view returns (uint256[4] memory) {
        return [invitedLockAPY[LockPeriod.THREE_MONTHS], invitedLockAPY[LockPeriod.SIX_MONTHS], invitedLockAPY[LockPeriod.TWELVE_MONTHS], invitedLockAPY[LockPeriod.TWENTYFOUR_MONTHS]];
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
