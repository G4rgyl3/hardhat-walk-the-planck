// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockEntropy} from "@pythnetwork/entropy-sdk-solidity/MockEntropy.sol";

contract TestMockEntropy is MockEntropy {
    constructor(address defaultProvider) MockEntropy(defaultProvider) {}
}
