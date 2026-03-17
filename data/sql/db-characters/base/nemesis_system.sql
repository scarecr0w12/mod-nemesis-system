CREATE TABLE IF NOT EXISTS `character_nemesis` (
    `guid` bigint unsigned NOT NULL COMMENT 'Creature spawn id',
    `creature_entry` int unsigned NOT NULL COMMENT 'Original creature entry',
    `map_id` int unsigned NOT NULL,
    `pos_x` float NOT NULL,
    `pos_y` float NOT NULL,
    `pos_z` float NOT NULL,
    `rank` tinyint unsigned NOT NULL DEFAULT 1 COMMENT 'Current nemesis rank',
    `affix_mask` int unsigned NOT NULL DEFAULT 0 COMMENT 'Reserved for future affixes',
    `nemesis_target_guid` int unsigned NOT NULL COMMENT 'Player guid that created the nemesis',
    `creation_date` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`guid`),
    KEY `idx_character_nemesis_target` (`nemesis_target_guid`),
    KEY `idx_character_nemesis_created` (`creation_date`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;