# Nemesis System Module

## Overview

`mod-nemesis-system` turns selected open-world PvE deaths into persistent revenge targets.
When an eligible creature kills a player, the creature is promoted into a Nemesis,
gains rank-based scaling, and is persisted in the characters database so the state
survives creature unloads and server restarts.

This scaffold implements the first vertical slice:

- player-death trigger using `OnPlayerKilledByCreature`
- persistent `character_nemesis` storage in the characters database
- rank-based size, health, and melee/ranged damage scaling
- affix rolling with runtime behavior hooks
- re-application on `OnCreatureAddWorld`
- cleanup when a tracked nemesis dies
- decay for stale nemesis records
- direct revenge and bounty rewards on kill

Anti-exploit cooldowns and announcements are still follow-up work.

## Files

- `src/NemesisSystem.cpp`: initial gameplay and persistence logic
- `src/nemesis_system_loader.cpp`: module loader entrypoint
- `conf/mod_nemesis_system.conf.dist`: module configuration
- `data/sql/db-characters/base/nemesis_system.sql`: characters database schema

## Installation

1. Build AzerothCore with the module enabled.
2. Import `data/sql/db-characters/base/nemesis_system.sql` into the characters database.
3. Copy `conf/mod_nemesis_system.conf.dist` to your server config directory if needed.
4. Restart `worldserver`.

## Current Behavior

- Nemeses only spawn from non-instance, non-battleground, non-raid kills.
- Only DB-backed creature spawns are eligible.
- Critters, pets, dungeon bosses, world bosses, and sanctuary deaths are excluded.
- Initial ranks affect size, health, and weapon damage.
- Rank 1 rolls one affix. Rank 3+ rolls a second affix.
- Implemented affixes: `Vampiric`, `Swift`, `Juggernaut`.
- The original victim is stored as the current nemesis target.
- Base creature stats are persisted so scaling stays stable across restarts and reloads.

## Rewards

- Revenge reward: granted when the original nemesis target or a member of their party kills the nemesis.
- Bounty reward: granted to other players who kill the nemesis.
- Rewards are configurable as direct item and gold grants.

## Next Steps

1. Add additional affixes and spell-driven visuals.
2. Add anti-feed cooldowns and decay cleanup polish.
3. Integrate with announcements and optional autobalance hooks.