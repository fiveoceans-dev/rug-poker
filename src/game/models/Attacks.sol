// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { ATTACK_ROUNDS, COMMUNITY_CARDS, FLOPPED_CARDS } from "../GameConstants.sol";
import { AttackResult, AttackStatus, Attack_, GameStorage } from "../GameStorage.sol";
import { Card, Cards } from "./Cards.sol";
import { GameConfig, GameConfigs } from "./GameConfigs.sol";
import { Player, Players } from "./Players.sol";
import { Random } from "./Random.sol";
import { Rewards } from "./Rewards.sol";
import { IEvaluator } from "src/interfaces/IEvaluator.sol";

library Attacks {
    using GameConfigs for GameConfig;
    using Players for Player;
    using Cards for Card;

    uint32 constant MAX_RANK = 7462;

    event EvaluateHands(
        uint256 indexed attackId,
        uint8 indexed round,
        IEvaluator.HandRank handAttack,
        uint256 rankAttack,
        IEvaluator.HandRank handDefense,
        uint256 rankDefense
    );
    event DetermineAttackResult(uint256 indexed attackId, AttackResult indexed result);

    error InvalidAddress();
    error Forbidden();
    error AttackTimeover();
    error DefenseTimeover();
    error InvalidNumberOfJokers();
    error InvalidJokerCard();
    error InvalidAttackStatus();
    error WaitingForAttack();
    error WaitingForDefense();

    function gameStorage() internal pure returns (GameStorage storage s) {
        assembly {
            s.slot := 0
        }
    }

    function get(uint256 id) internal view returns (Attack_ storage self) {
        return gameStorage().attacks[id];
    }

    function init(address attacker, address defender) internal returns (Attack_ storage self) {
        GameStorage storage s = gameStorage();

        if (defender == address(0) || attacker == defender) revert InvalidAddress();

        uint256 id = s.lastAttackId + 1;
        s.attacks[id] =
            Attack_(id, AttackStatus.Flopping, AttackResult.None, attacker, defender, uint64(block.timestamp));
        s.lastAttackId = id;

        return s.attacks[id];
    }

    function assertWaiting(Attack_ storage self) internal view {
        if (self.status != AttackStatus.WaitingForAttack && self.status != AttackStatus.WaitingForDefense) {
            revert InvalidAttackStatus();
        }
    }

    function onFlop(Attack_ storage self) internal {
        if (self.status != AttackStatus.Flopping) revert InvalidAttackStatus();

        self.status = AttackStatus.WaitingForAttack;

        GameStorage storage s = gameStorage();
        for (uint256 i; i < ATTACK_ROUNDS; ++i) {
            for (uint256 j; j < FLOPPED_CARDS; ++j) {
                s.communityCards[self.id][i].push(Cards.drawCard());
            }
        }
    }

    function submit(Attack_ storage self, uint256[] memory tokenIds, uint8[] memory jokerCards)
        internal
        returns (bool defending)
    {
        GameConfig memory c = GameConfigs.latest();
        if (self.status == AttackStatus.WaitingForAttack) {
            if (msg.sender != self.attacker) revert Forbidden();
            if (self.startedAt + c.attackPeriod < block.timestamp) revert AttackTimeover();
            self.status = AttackStatus.WaitingForDefense;
        } else if (self.status == AttackStatus.WaitingForDefense) {
            if (msg.sender != self.defender) revert Forbidden();
            if (self.startedAt + c.defensePeriod < block.timestamp) revert DefenseTimeover();
            self.status = AttackStatus.ShowingDown;
            defending = true;
        } else {
            revert InvalidAttackStatus();
        }

        Cards.assertValidNumberOfCards(tokenIds.length);
        Cards.assertNotDuplicate(tokenIds);

        uint8[] memory cards = _populateCards(tokenIds, jokerCards);
        Cards.assertDistinct(cards);

        GameStorage storage s = gameStorage();
        uint256 id = self.id;
        if (defending) {
            s.defendingTokenIds[id] = tokenIds;
            s.defendingJokerCards[id] = jokerCards;
        } else {
            s.attackingTokenIds[id] = tokenIds;
            s.attackingJokerCards[id] = jokerCards;
        }
    }

    function _populateCards(uint256[] memory tokenIds, uint8[] memory jokerCards)
        private
        returns (uint8[] memory cards)
    {
        if (jokerCards.length > GameConfigs.latest().maxJokers) revert InvalidNumberOfJokers();

        uint256 jokerIndex;
        cards = new uint8[](tokenIds.length);
        for (uint256 i; i < cards.length; ++i) {
            uint256 tokenId = tokenIds[i];
            Card storage card = Cards.get(tokenId);
            card.assertAvailable(msg.sender, true, false);
            card.markUnderuse();
            if (card.isJoker()) {
                uint8 value = jokerCards[jokerIndex++];
                if (!Cards.isValidValue(value)) revert InvalidJokerCard();
                cards[i] = value;
            } else {
                cards[i] = card.toValue();
            }
            cards[i] = jokerCards[i];
        }
    }

    function onShowDown(Attack_ storage self) internal {
        if (self.status != AttackStatus.ShowingDown) revert InvalidAttackStatus();

        Player storage attacker = Players.get(self.attacker);

        attacker.checkpoint();
        attacker.increaseBogoRandomly();
        Players.get(self.defender).checkpoint();

        GameStorage storage s = gameStorage();
        for (uint256 i; i < ATTACK_ROUNDS; ++i) {
            for (uint256 j; j < COMMUNITY_CARDS - FLOPPED_CARDS; ++j) {
                s.communityCards[self.id][i].push(Cards.drawCard());
            }
        }

        AttackResult result = determineAttackResult(self);
        finalize(self, result);
    }

    function determineAttackResult(Attack_ storage self) internal returns (AttackResult result) {
        GameStorage storage s = gameStorage();

        uint256 id = self.id;
        (
            IEvaluator.HandRank[ATTACK_ROUNDS] memory handsAttack,
            uint256[ATTACK_ROUNDS] memory ranksAttack,
            IEvaluator.HandRank[ATTACK_ROUNDS] memory handsDefense,
            uint256[ATTACK_ROUNDS] memory ranksDefense
        ) = Cards.evaluateHands(
            s.attackingTokenIds[id],
            s.defendingTokenIds[id],
            s.attackingJokerCards[id],
            s.defendingJokerCards[id],
            s.communityCards[id]
        );
        (address attacker, address defender, uint256[] memory attackingTokenIds, uint256[] memory defendingTokenIds) =
            (self.attacker, self.defender, s.attackingTokenIds[id], s.defendingTokenIds[id]);
        (uint8 attackerWon, uint8 attackerLost, uint256 rankSumAttack, uint256 rankSumDefense) = (0, 0, 0, 0);
        for (uint8 i; i < ATTACK_ROUNDS; ++i) {
            if (ranksAttack[i] < ranksDefense[i]) {
                attackerWon++;
                _increaseXPs(attacker, defender, ranksAttack[i], ranksDefense[i], attackingTokenIds, defendingTokenIds);
            } else if (ranksAttack[i] > ranksDefense[i]) {
                attackerLost++;
                _increaseXPs(defender, attacker, ranksDefense[i], ranksAttack[i], defendingTokenIds, attackingTokenIds);
            }
            rankSumAttack += ranksAttack[i];
            rankSumDefense += ranksDefense[i];
            emit EvaluateHands(self.id, i, handsAttack[i], ranksAttack[i], handsDefense[i], ranksDefense[i]);
        }

        result = AttackResult.Draw;
        if (attackerWon > attackerLost) {
            _processSuccess(attacker, defender, attackingTokenIds, defendingTokenIds);
            result = AttackResult.Success;
        } else if (attackerWon < attackerLost) {
            _processFail(defender, attackingTokenIds, defendingTokenIds);
            result = AttackResult.Fail;
        }
        if (rankSumDefense > rankSumAttack) {
            Players.get(attacker).incrementPoints(rankSumDefense - rankSumAttack);
        } else if (rankSumAttack > rankSumDefense) {
            Players.get(defender).incrementPoints(rankSumAttack - rankSumDefense);
        }
        self.result = result;
        emit DetermineAttackResult(self.id, result);
    }

    function _processSuccess(
        address attacker,
        address defender,
        uint256[] memory attackingTokenIds,
        uint256[] memory defendingTokenIds
    ) private {
        uint8 percentage = _bootyPercentage(_bootyPoints(attackingTokenIds), _bootyPoints(defendingTokenIds));
        Rewards.moveAccReward(defender, attacker, percentage);
    }

    function _bootyPercentage(uint256 attackBootyPoints, uint256 defenseBootyPoints) private view returns (uint8) {
        GameConfig memory c = GameConfigs.latest();
        if (defenseBootyPoints >= attackBootyPoints) return c.minBootyPercentage;
        return uint8(
            c.minBootyPercentage
                + (attackBootyPoints - defenseBootyPoints) * (c.maxBootyPercentage - c.minBootyPercentage)
                    / attackBootyPoints
        );
    }

    function _processFail(address defender, uint256[] memory attackingTokenIds, uint256[] memory defendingTokenIds)
        private
    {
        uint256 cards = attackingTokenIds.length;
        uint256 attackBootyPoints = _bootyPoints(attackingTokenIds);
        uint256 defenseBootyPoints = _bootyPoints(defendingTokenIds);
        if (defenseBootyPoints > attackBootyPoints) {
            uint256 bootyCards = (defenseBootyPoints - attackBootyPoints) * cards / defenseBootyPoints;
            for (uint256 i; i < bootyCards; ++i) {
                uint256 index = uint256(Random.draw(0, uint8(cards)));
                uint256 tokenId = attackingTokenIds[index];
                Cards.get(tokenId).move(defender);
            }
        }
    }

    function _bootyPoints(uint256[] memory tokenIds) private view returns (uint256 points) {
        for (uint256 i; i < tokenIds.length; ++i) {
            points += Cards.get(tokenIds[i]).power;
        }
    }

    function _increaseXPs(
        address winner,
        address loser,
        uint256 rankWinner,
        uint256 rankLoser,
        uint256[] memory winnerTokenIds,
        uint256[] memory loserTokenIds
    ) private {
        uint32 xpWinner = MAX_RANK - uint32(rankWinner);
        uint32 xpLoser = (MAX_RANK - uint32(rankLoser)) / 4;
        Players.get(winner).gainXP(xpWinner);
        Players.get(loser).gainXP(xpLoser);
        Cards.gainXPBatch(winnerTokenIds, xpWinner);
        Cards.gainXPBatch(loserTokenIds, xpLoser);
    }

    function finalize(Attack_ storage self, AttackResult result) internal {
        GameConfig memory c = GameConfigs.latest();
        if (self.status == AttackStatus.WaitingForAttack) {
            if (block.timestamp <= self.startedAt + c.attackPeriod) revert WaitingForAttack();
        } else if (self.status == AttackStatus.WaitingForDefense) {
            if (block.timestamp <= self.startedAt + c.defensePeriod) revert WaitingForDefense();
        } else if (self.status != AttackStatus.ShowingDown) {
            revert InvalidAttackStatus();
        }

        self.status = AttackStatus.Finalized;

        GameStorage storage s = gameStorage();

        (uint256 id, address attacker, address defender) = (self.id, self.attacker, self.defender);
        Players.get(attacker).removeOutgoingAttack(id);
        Player storage d = Players.get(defender);
        d.updateLastDefendedAt();
        d.removeIncomingAttack(self.id);

        if (result == AttackResult.Success) {
            for (uint256 i; i < s.defendingTokenIds[id].length; ++i) {
                Cards.get(s.defendingTokenIds[id][i]).spend();
            }
        } else if (result == AttackResult.Fail) {
            for (uint256 i; i < s.attackingTokenIds[id].length; ++i) {
                Cards.get(s.attackingTokenIds[id][i]).spend();
            }
        }
    }
}
