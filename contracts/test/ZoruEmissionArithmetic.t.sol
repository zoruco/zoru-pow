// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ZoruLedger} from "../src/ZoruLedger.sol";

/// @dev Independent arithmetic checks for the public emission and claim rules.
/// No deployed contract state or privileged wallet is involved.
contract ZoruEmissionArithmeticTest {
    uint256 constant UNITS = 100_000_000;
    uint256 constant EXPECTED_CAP = 21_000_000 * UNITS;
    uint256 constant START_BUDGET = 5 * UNITS;
    uint256 constant ERA_LENGTH = 2_100_000;
    uint256 constant FULL_ERAS = 29;

    ZoruLedger ledger = new ZoruLedger();

    function testAllHalvingBoundariesAndFinalDustSumExactlyToCap() public view {
        uint256 previous = type(uint256).max;
        uint256 total;
        for (uint256 era; era < FULL_ERAS; ++era) {
            uint256 first = era * ERA_LENGTH;
            uint256 budget = START_BUDGET / (uint256(1) << era);
            require(budget <= previous, "increasing reward");
            require(ledger.budgetForIndex(first) == budget, "era first");
            require(ledger.budgetForIndex(first + ERA_LENGTH - 1) == budget, "era last");
            if (era > 0) require(ledger.budgetForIndex(first - 1) == previous, "pre-halving boundary");
            total += budget * ERA_LENGTH;
            previous = budget;
        }
        uint256 terminal = ledger.budgetForIndex(FULL_ERAS * ERA_LENGTH);
        require(terminal == 27_300_000, "terminal remainder in 8-decimal units");
        require(total == 2_099_999_972_700_000, "independent sum of 29 eras");
        require(total + terminal == EXPECTED_CAP, "exact 21 million cap");
        require(ledger.budgetForIndex(FULL_ERAS * ERA_LENGTH + 1) == 0, "never reward above cap");
        require(ledger.budgetForIndex(type(uint256).max) == 0, "extreme epoch index");
    }

    function testFuzzEveryProofShareAddsExactlyToEpochBudget(uint16 proofSeed, uint8 eraSeed) public pure {
        uint256 count = uint256(proofSeed) % 512 + 1;
        uint256 era = uint256(eraSeed) % 31;
        uint256 budget = era < FULL_ERAS ? START_BUDGET / (uint256(1) << era)
            : era == FULL_ERAS ? 27_300_000 : 0;

        uint256 sum;
        uint256 lastCumulative;
        for (uint256 i; i < count; ++i) {
            uint256 cumulative = Math.mulDiv(budget, i + 1, count);
            uint256 independentCumulative = budget * (i + 1) / count;
            require(cumulative == independentCumulative, "cumulative rounding");
            require(cumulative >= lastCumulative, "negative share");
            uint256 reward = cumulative - lastCumulative;
            require(reward <= budget, "individual overclaim");
            sum += reward;
            lastCumulative = cumulative;
        }
        require(sum == budget, "exact partition even when some proofs receive zero");
    }

    function testMinRewardAndEmptyEpochSemantics() public view {
        require(ledger.budgetForIndex(0) == START_BUDGET, "first nonempty epoch");
        require(ledger.budgetForIndex(ERA_LENGTH) == START_BUDGET / 2, "first halving");
        require(ledger.budgetForIndex((FULL_ERAS - 1) * ERA_LENGTH) == 1, "one base unit last era");
        require(ledger.budgetForIndex(FULL_ERAS * ERA_LENGTH) == 27_300_000, "terminal emission");
    }
}
