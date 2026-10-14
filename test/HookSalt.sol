// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IMD6900RobinhoodLaunch} from "../src/IMD6900RobinhoodLaunch.sol";

/// @dev What script/launch.sh's `hook` step mines with cast, for the tests: the first salt whose CREATE2 address from
///      the launch carries exactly its FLAGS and doesn't start with 0x91
library HookSalt {
    function mine(IMD6900RobinhoodLaunch l) internal view returns (bytes32) {
        return mine(l, 0);
    }

    function mine(IMD6900RobinhoodLaunch l, uint256 from) internal view returns (bytes32 s) {
        bytes32 initHash = l.hookInitCodeHash();
        uint160 flags = l.FLAGS();
        for (uint256 i = from;; ++i) {
            uint160 a = Create2Address.at(address(l), i, initHash);
            if (a & Hooks.ALL_HOOK_MASK == flags && a >> 152 != 0x91) return bytes32(i);
        }
    }
}

/// @dev What script/mine.sh mines with cast, for the tests: the first salt whose CREATE2 address for the coin starts
///      with the launch's VANITY (0x6900)
library CoinSalt {
    function mine(IMD6900RobinhoodLaunch l) internal view returns (bytes32 s) {
        bytes32 initHash = l.tokenInitCodeHash();
        uint160 vanity = l.VANITY();
        for (uint256 i;; ++i) {
            if (Create2Address.at(address(l), i, initHash) >> 144 == vanity) return bytes32(i);
        }
    }
}

/// @dev The CREATE2 address, hashed in the scratch space: a mining loop that allocated 85 bytes a try grew memory
///      without bound, and the quadratic memory cost ran a long search out of gas (MemoryOOG) at whatever salt count
///      a given deployer address happened to need
library Create2Address {
    function at(address deployer, uint256 salt, bytes32 initHash) internal pure returns (uint160 a) {
        assembly ("memory-safe") {
            let p := mload(0x40) // the free memory pointer is left where it was: nothing is allocated
            mstore(p, or(shl(248, 0xff), shl(88, deployer)))
            mstore(add(p, 0x15), salt)
            mstore(add(p, 0x35), initHash)
            a := and(keccak256(p, 0x55), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }
}
