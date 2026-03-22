ALTER TABLE `character_nemesis`
    ADD COLUMN `zone_id` int unsigned NOT NULL DEFAULT 0 AFTER `map_id`,
    ADD COLUMN `last_seen_at` int unsigned NOT NULL DEFAULT 0 AFTER `last_victim_guid`;

ALTER TABLE `character_nemesis`
    ADD KEY `idx_character_nemesis_last_seen` (`last_seen_at`);
