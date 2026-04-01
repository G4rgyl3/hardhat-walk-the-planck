# Walk the Planck

Walk the Planck is a small onchain party game built in Hardhat.

Players join a public queue with the same entry fee, the table fills up, and one unlucky player gets picked to "walk the planck." Everyone else survives and splits the pot.

The fun part is the fairness story: match resolution uses Pyth Entropy so the loser selection is driven by an external randomness source instead of a wallet, UI, or server deciding the outcome.

## What the game does

- Supports matches with `2` to `5` players
- Uses fixed ETH entry tiers
- Groups players into public queue buckets by `playerCount + entryFee`
- Starts resolution automatically when a bucket fills
- Uses Pyth Entropy to randomize turn order and choose the losing turn
- Pays survivors immediately when possible
- Falls back to claimable winnings if a transfer fails
- Lets anyone cancel expired open matches so players can claim refunds
- Takes a `5%` protocol fee from resolved matches

## Why Pyth Entropy matters here

This project was meant to be a simple, playful example of fair matchmaking and fair game resolution onchain.

Instead of trusting a backend to pick a loser, the contract requests entropy from Pyth once a match fills. That randomness is then used to:

1. Shuffle the player turn order
2. Pick the losing turn
3. Resolve the match onchain with transparent payout rules

That means the contract logic can stay lightweight and the fairness story stays easy to explain:

`same buy-in -> same queue -> verifiable random resolution -> survivors split the pot`

## Contract overview

Main contract: [`contracts/walk-the-planck.sol`](/c:/Users/Gargyle/Documents/Development/hardhat/walk%20the%20planck/contracts/walk-the-planck.sol)

Key behaviors:

- `joinQueue(uint8 maxPlayers, uint256 entryFee)` joins or creates the active bucket for that ruleset
- Once the bucket is full, the contract requests entropy and moves the match into `Resolving`
- `entropyCallback(...)` receives the randomness and runs the game
- One loser is selected, survivors are paid, and protocol fees are accrued
- `cancelExpiredMatch(uint256 matchId)` cancels stale open matches
- `claim(uint256 matchId)` and `claimRefund(uint256 matchId)` handle deferred payouts and refunds

Default allowed entry fees in the current contract:

- `0.0005 ETH`
- `0.001 ETH`
- `0.0025 ETH`
- `0.005 ETH`
- `0.01 ETH`

## Project structure

- [`contracts/walk-the-planck.sol`](/c:/Users/Gargyle/Documents/Development/hardhat/walk%20the%20planck/contracts/walk-the-planck.sol) - main game contract
- [`contracts/mocks/TestMockEntropy.sol`](/c:/Users/Gargyle/Documents/Development/hardhat/walk%20the%20planck/contracts/mocks/TestMockEntropy.sol) - mock entropy contract for local testing
- [`test/walk-the-planck.js`](/c:/Users/Gargyle/Documents/Development/hardhat/walk%20the%20planck/test/walk-the-planck.js) - current test coverage around queue buckets and active match views
- [`deploy/deploy-game.js`](/c:/Users/Gargyle/Documents/Development/hardhat/walk%20the%20planck/deploy/deploy-game.js) - deployment script

## Getting started

Install dependencies:

```bash
npm install
```

Compile:

```bash
npx hardhat compile
```

Run tests:

```bash
npx hardhat test
```

Run the focused game tests:

```bash
npx hardhat test test/walk-the-planck.js
```

## Deployment

Example:

```bash
npx hardhat run --network base ./deploy/deploy-game.js
```

The deploy script currently targets a configured entropy router and treasury/collector address, so double-check those values before using it on a live network.

## Current implementation notes

- Match resolution is single-round: one loser, everyone else wins
- The entropy fee is taken from the match pot before survivor payouts
- Dust from integer division is kept as protocol fees
- Open matches expire after `10 minutes` by default
- Historical entry tiers remain enumerable even after being disabled

## License

Apache 2.0
