# Nemesis System Module

## Overview

`mod-nemesis-system` turns selected open-world PvE deaths into persistent revenge targets.
When an eligible creature kills a player, the creature is promoted into a Nemesis,
gains rank-based scaling, and is persisted in the characters database so the state
survives creature unloads and server restarts.

This scaffold implements the first vertical slice:

- player-death trigger using `OnPlayerKilledByCreature`
- persistent `character_nemesis` storage in the characters database
- rank-based size and health scaling
- re-application on `OnCreatureAddWorld`
- cleanup when a tracked nemesis dies

Affixes, loot, anti-exploit cooldowns, and announcements are intentionally left
for follow-up work.

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
- Initial ranks affect size and health only.
- The original victim is stored as the current nemesis target.

## Next Steps

1. Add affix selection and affix execution.
2. Add reward distribution and revenge credit.
3. Add decay timers and anti-feed cooldowns.
4. Integrate with announcements and optional autobalance hooks.