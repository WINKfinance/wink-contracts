// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IWhitelistRegistration } from "./IWhitelistRegistration.sol";

interface IObserver {
    function notify(address[] memory interestedAddresses) external;
}

contract WhitelistRegistration is IWhitelistRegistration, Ownable {
    
    mapping(address => bool) public whitelist;
    mapping(address => address) public representatives;
    
    address[] public observers;

    error AddressNotWhitelisted(address _address);
    error AddressAlreadyWhitelisted(address _address);
    error CannotRegisterSelf();

    constructor(address _owner) Ownable(_owner) {}

    modifier onlyWhitelisted(address _address) {
        if (!whitelist[_address]) {
            revert AddressNotWhitelisted(_address);
        }
        _;
    }

    modifier notSelf(address _represented, address _representative) {
        if (_represented == _representative) {
            revert CannotRegisterSelf();
        }
        _;
    }

    event AddedToWhitelist(address indexed addedAddress);
    event RepresentativeRegistered(address indexed wallet, address indexed representative);

    function addObserver(address observer) external onlyOwner {
        observers.push(observer);
    }

    function _notify(address[] memory interestedAddresses) internal {
        for(uint i = 0; i < observers.length; i++) {
            try IObserver(observers[i]).notify(interestedAddresses) {
            } catch {
            }
        }
    }

    // Function to add an address to the whitelist
    function addToWhitelist(address _address) external onlyOwner {
        if (whitelist[_address]) {
            revert AddressAlreadyWhitelisted(_address);
        }

        address[] memory addresses = new address[](1);
        addresses[0] = msg.sender;
        _notify(addresses);

        whitelist[_address] = true;
        emit AddedToWhitelist(_address);
    }

    function _registerRepresentative(address _represented, address _representative) internal {
        address[] memory addresses = new address[](1);
        addresses[0] = _represented;
        _notify(addresses);

        representatives[_represented] = _representative;
        emit RepresentativeRegistered(_represented, _representative);
    }

    // Owner function to register a representative for a specific wallet
    function registerRepresentative(address _represented, address _representative) external onlyOwner onlyWhitelisted(_representative) notSelf(_represented, _representative) {
        _registerRepresentative(_represented, _representative);
    }

    // Function to register a representative if the representative is whitelisted
    function registerRepresentative(address _representative) external onlyWhitelisted(_representative) notSelf(msg.sender, _representative) {
        _registerRepresentative(msg.sender, _representative);
    }

    // Function to check if an address is whitelisted
    function isWhitelisted(address _address) external view returns (bool) {
        return whitelist[_address];
    }

    // Function to get the representative of a specific wallet
    function getRepresentative(address _wallet) external view returns (address) {
        return representatives[_wallet];
    }
}
