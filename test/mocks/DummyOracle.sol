// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract DummyOracle {
    int256 private _value;

    constructor(int256 value_) {
        _value = value_;
    }

    function latestAnswer() external view returns (int256) {
        return _value;
    }

    function set(int256 value_) external {
        _value = value_;
    }
}
