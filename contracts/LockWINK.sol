// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.0.0
pragma solidity ^0.8.22;

import { ERC20Burnable } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import { ERC721Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import { ERC721BurnableUpgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721BurnableUpgradeable.sol";
import { ERC721EnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { WINK } from "./WINK.sol";
import { VestedWINK } from "./VestedWINK.sol";
import { VestedMetableWINK } from "./VestedMetableWINK.sol";
import { VestedTeamWINK } from "./VestedTeamWINK.sol";
contract LockWINK is Initializable, ERC721Upgradeable, ERC721EnumerableUpgradeable, ERC721BurnableUpgradeable, OwnableUpgradeable, UUPSUpgradeable {
    uint256 private _nextTokenId;

    struct Lock {
        uint256 id;              // [unique id]
        uint256 quotes;          // [~wink, 10**18]
        uint256 wink;            // [wink]
        uint256 lockEnd;         // [unit epoch time]
        uint256 lockType;        // [0, 1, 2, 3] => [3 months, 6 months, 12 months, 24 months]
        uint32 bonus;            // [0, 100000] => [0%, 100%]
        address depositedToken;  // [wink, vwink, vmwink, vtwink]
    }

    struct InitialBonus {
        bool enabled;            // [bool]
        uint32 bonus;            // [0, 100000] => [0%, 100%]
    }

    uint256 private constant RAY = 10 ** 27;

    uint256 public chi; // [ray] 
    uint256 public totalWINK;
    uint256 public totalQuotes;

    enum LockPeriod { THREE_MONTHS, SIX_MONTHS, TWELVE_MONTHS, TWENTYFOUR_MONTHS }

    mapping(LockPeriod => InitialBonus) public initialBonuses;  // [InitialBonus]
    uint32 public vestedBonus; // [0, 100000] => [0%, 100%]

    uint256 public penaltyPerc; // [ray]

    // maps token id to lock data
    mapping(uint256 => Lock) public data;

    WINK public wink;
    VestedWINK public vwink;
    VestedMetableWINK public vmwink;
    VestedTeamWINK public vtwink;
    //vWINK public vwink;
    address public rebaser;
    address public bonusReserve;
    address public unlockReserve;

    error AmountMustBeGreaterThanZero();
    error TransferFailed(address from, address to, uint256 amount);
    error InvalidLockPeriod(LockPeriod lockPeriod);
    error InvalidDepositToken(address token);

    error CannotUnstakeBeforeLockEnds(uint256 lockId, uint256 lockEnd, uint256 currentTime);
    error CannotUpgradeToShorterPeriod(uint256 lockId, uint256 currentType, uint256 newType);
    error RebaseUnauthorizedAccount(address account);

    event Deposit(uint256 tokenId, uint256 amount, LockPeriod lockPeriod);
    event Renewed(uint256 tokenId, uint256 amount, LockPeriod lockPeriod);
    event Withdraw(uint256 tokenId);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address initialOwner,
        address _wink,
        address _vwink,
        address _vmwink,
        address _vtwink,
        address _rebaser,
        address _bonusReserve,
        address _unlockReserve
    ) initializer public {
        __ERC721_init("LockWINK", "LockWINK");
        __ERC721Enumerable_init();
        __ERC721Burnable_init();
        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();

        wink = WINK(_wink);
        vwink = VestedWINK(_vwink);
        vmwink = VestedMetableWINK(_vmwink);
        vtwink = VestedTeamWINK(_vtwink);
        rebaser = _rebaser;
        bonusReserve = _bonusReserve;
        unlockReserve = _unlockReserve;

        penaltyPerc = 3_805_175_038_051_750_381; // 12% per year - already divided by 100 

        chi = RAY;

        initialBonuses[LockPeriod.THREE_MONTHS] =      InitialBonus(false, 0); // bonus disabled
        initialBonuses[LockPeriod.SIX_MONTHS] =        InitialBonus(true, 3000); // 3% bonus
        initialBonuses[LockPeriod.TWELVE_MONTHS] =     InitialBonus(true, 5000); // 5% bonus
        initialBonuses[LockPeriod.TWENTYFOUR_MONTHS] = InitialBonus(true, 8000); // 8% bonus

        vestedBonus = 5000; // 5% bonus
    }

    function setPenaltyPerc(uint256 _penaltyPerc) public onlyOwner {
        penaltyPerc = _penaltyPerc;
    }

    function updateVestedBonus(uint32 _vestedBonus) public onlyOwner {
        vestedBonus = _vestedBonus;
    }

    function updateInitialBonus(LockPeriod _lockPeriod, bool _enabled, uint32 _bonus) public onlyOwner {
        initialBonuses[_lockPeriod] = InitialBonus(_enabled, _bonus);
    }

    function createLock(uint256 _tokenId, uint256 _quotes, uint256 _wink, LockPeriod _lockPeriod, address _depositedToken, uint32 _bonus) internal {
        // prepares the lock duration based on the lock period
        uint256 lockDuration = 0 days;
        if (_lockPeriod == LockPeriod.THREE_MONTHS) lockDuration = 90 days;
        else if (_lockPeriod == LockPeriod.SIX_MONTHS) lockDuration = 180 days;
        else if (_lockPeriod == LockPeriod.TWELVE_MONTHS) lockDuration = 365 days;
        else if (_lockPeriod == LockPeriod.TWENTYFOUR_MONTHS) lockDuration = 730 days;
        else revert InvalidLockPeriod(_lockPeriod);

        data[_tokenId] = Lock({
            id:                 _tokenId,
            quotes:             _quotes,
            wink:               _wink,
            lockEnd:            block.timestamp + lockDuration,
            lockType:           uint256(_lockPeriod),
            depositedToken:     _depositedToken,
            bonus:              _bonus
        });
    }

    function setRebaser(address _rebaser) public onlyOwner {
        rebaser = _rebaser;
    }

    function setBonusReserve(address _bonusReserve) public onlyOwner {
        bonusReserve = _bonusReserve;
    }

    function setUnlockReserve(address _unlockReserve) public onlyOwner {
        unlockReserve = _unlockReserve;
    }

    modifier onlyRebaser() {
        _checkRebaser();
        _;
    }

    function _checkRebaser() internal view virtual {
        if (rebaser != _msgSender()) {
            revert RebaseUnauthorizedAccount(_msgSender());
        }
    }

    function rebase(uint256 _amount) public onlyRebaser {
        // the deposit must be > 0
        if (_amount <= 0)
            revert AmountMustBeGreaterThanZero();

        // cannot rebase if there are no deposits
        if (totalWINK <= 0)
            revert AmountMustBeGreaterThanZero();

        // takes the amount of wink to rebase
        wink.transferFrom(msg.sender, address(this), _amount);
        
        // adds the amount to the total wink
        totalWINK += _amount;
        
        // calculate the new chi value based on the new total wink
        chi = totalWINK * RAY / totalQuotes;
    }

    function renewLock(uint256 _tokenId, LockPeriod _lockPeriod) public {
        // checks if the sender is authorized (owner or allowed)
        _checkAuthorized(_ownerOf(_tokenId), _msgSender(), _tokenId);

        Lock storage lock = data[_tokenId];

        // if the deposited token is not wink, revert
        if(lock.depositedToken != address(wink))
            revert InvalidDepositToken(data[_tokenId].depositedToken);

        // if the lock has a longer period than the new one, revert
        if(lock.lockType >= uint256(_lockPeriod))
            revert CannotUpgradeToShorterPeriod(_tokenId, lock.lockType, uint256(_lockPeriod));

        // if the lock is not ended, revert
        if(lock.lockEnd > block.timestamp)
            revert CannotUnstakeBeforeLockEnds(_tokenId, lock.lockEnd, block.timestamp);

        // calculates the difference between the bonus for the new lock period and the bonus gained in the previous lock period
        uint256 winkToWithdraw = lock.quotes * chi / RAY;

        // the bonus from the new lock period
        uint32 bonus = initialBonuses[_lockPeriod].enabled ? initialBonuses[_lockPeriod].bonus : 0;
        uint256 quotes = winkToWithdraw * (100000 + bonus) * RAY / chi / 100000;
        uint256 amount = quotes * chi / RAY;

        if(!wink.transferFrom(bonusReserve, address(this), amount - winkToWithdraw))
            revert TransferFailed(bonusReserve, address(this), amount - winkToWithdraw);

        totalWINK += amount - winkToWithdraw;
        totalQuotes += quotes - lock.quotes;

        // creates a new lock with the same amount and the new lock period
        createLock(_tokenId, quotes, amount, _lockPeriod, lock.depositedToken, bonus);

        emit Renewed(_tokenId, amount, _lockPeriod);
    }

    function safeMint(uint256 _amount, address _depositedToken, LockPeriod lockPeriod, address _receiver) public {
        
        // the deposit must be > 0
        if (_amount <= 0)
            revert AmountMustBeGreaterThanZero();

        uint256 quotes;
        uint32 bonus;

        if(_depositedToken == address(wink)) {
            // if the user is depositing WINK tokens we need to calculate the amount of quotes
            bonus = initialBonuses[lockPeriod].enabled ? initialBonuses[lockPeriod].bonus : 0;
            quotes = _amount * (100000 + bonus) * RAY / chi / 100000;
            uint256 _winkAmount = _amount;
            _amount = quotes * chi / RAY;

            // check if the user has enough WINK tokens
            if (!wink.transferFrom(msg.sender, address(this), _winkAmount))
                revert TransferFailed(msg.sender, address(this), _winkAmount);
            if (!wink.transferFrom(bonusReserve, address(this), _amount - _winkAmount))
                revert TransferFailed(bonusReserve, address(this), _amount - _winkAmount);
            
        } else if(_depositedToken == address(vwink) || _depositedToken == address(vmwink) || _depositedToken == address(vtwink)) {
            // if the user is depositing vWINK tokens we need to calculate the amount of quotes plus a vesting bonus
            bonus = vestedBonus;
            quotes = _amount * (100000 + bonus) * RAY / chi / 100000;
            uint256 _vwinkAmount = _amount;
            _amount = quotes * chi / RAY;

            if(_depositedToken == address(vwink))
                lockPeriod = LockPeriod.THREE_MONTHS;
            else if(_depositedToken == address(vmwink))
                lockPeriod = LockPeriod.SIX_MONTHS;
            else if(_depositedToken == address(vtwink))
                lockPeriod = LockPeriod.TWENTYFOUR_MONTHS;

            // check if the user has enough vUSDW tokens
            if (!ERC20Burnable(_depositedToken).transferFrom(msg.sender, address(this), _vwinkAmount))
                revert TransferFailed(msg.sender, address(this), _vwinkAmount);

            ERC20Burnable(_depositedToken).burn(_vwinkAmount);

            if (!wink.transferFrom(unlockReserve, address(this), _amount))
                revert TransferFailed(unlockReserve, address(this), _amount);
        } else {
            revert InvalidDepositToken(_depositedToken);
        }
        
        uint256 tokenId = _nextTokenId++;

        totalQuotes += quotes;
        totalWINK += _amount;

        createLock(tokenId, quotes, _amount, lockPeriod, _depositedToken, bonus);

        _safeMint(_receiver, tokenId);

        emit Deposit(tokenId, _amount, lockPeriod);
    }

    function burn(uint256 tokenId) public override(ERC721BurnableUpgradeable) {
        
        Lock storage lock = data[tokenId];

        // check if the user can unlock
        if(lock.lockEnd > block.timestamp)
            revert CannotUnstakeBeforeLockEnds(tokenId, lock.lockEnd, block.timestamp);

        // the amount maturated is: quotes * chi / RAY
        uint256 winkToWithdraw = lock.quotes * chi / RAY;

        // transfer the USDW tokens to the user
        if (!wink.transfer(ownerOf(tokenId), winkToWithdraw))
            revert TransferFailed(address(this), ownerOf(tokenId), winkToWithdraw);

        totalWINK -= winkToWithdraw;
        totalQuotes -= lock.quotes;

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
