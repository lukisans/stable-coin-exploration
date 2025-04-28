# Stablecoin Exploration on the EVM Ecosystem using Foundry

## Overview

This repository contains my exploration and experiments with building a stablecoin using Solidity on the Ethereum Virtual Machine (EVM) ecosystem, utilizing **Foundry** for testing and deployment. The goal is to understand the mechanics of stablecoins and implement a simple version, experimenting with various design patterns and concepts like collateralization, minting, and redemption.

## Requirements

To run the smart contracts locally and deploy them to an EVM network, ensure you have the following installed:

- [Foundry](https://github.com/foundry-rs/foundry) (for development and testing)
- [Solidity](https://soliditylang.org/)
- [MetaMask](https://metamask.io/) (for interacting with deployed contracts)

## Architecture

1. Relative stability: anchored or plegged -> $1.00
    1. CHainlink price feed.
    2. Set ad function to exchange ETH & BTC -> $$$
2. Stability mechanism (Minting): algorithmic (decentralized)
    1. People can only mint stablecoin with enough collateral (coded)
3. Collateral: exogenous (crypto)
    1. wETH (wrapped ETH)
    2. wBTC (wrapped BTC)
