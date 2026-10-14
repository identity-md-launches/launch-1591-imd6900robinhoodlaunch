// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @dev Compile-only: the tests (and the review proofs run beside them) deploy Uniswap v4's PoolManager from its build
///      artifact, `vm.deployCode("PoolManager.sol:PoolManager", ...)`, rather than embedding its creation code in a test
///      contract. This import keeps the artifact in every build that includes test/, even one that leaves the
///      project's own *.t.sol files out (as the verifier's proof runs do). Not a test, not deployed.
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
