// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

interface IIndexFactory {
    error ZeroAddress();
    error ZeroAmount();

    event IndexCreated(address indexed index, string name, string symbol);
}
