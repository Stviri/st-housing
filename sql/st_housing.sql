-- st-housing database schema
-- Run this in HeidiSQL before starting the resource

CREATE TABLE IF NOT EXISTS `st_plots` (
    `id`              INT AUTO_INCREMENT PRIMARY KEY,
    `plotid`          VARCHAR(20) NOT NULL UNIQUE,
    `citizenid`       VARCHAR(50) DEFAULT NULL,
    `house_type`      VARCHAR(50) NOT NULL,
    `propmodel`       VARCHAR(100) NOT NULL,
    `x`               DOUBLE NOT NULL DEFAULT 0,
    `y`               DOUBLE NOT NULL DEFAULT 0,
    `z`               DOUBLE NOT NULL DEFAULT 0,
    `heading`         FLOAT NOT NULL DEFAULT 0.0,
    `stage_materials` LONGTEXT DEFAULT '{}',
    `is_complete`     TINYINT DEFAULT 0,
    `is_abandoned`    TINYINT DEFAULT 0,
    `is_locked`       TINYINT NOT NULL DEFAULT 0,
    `allowed_players` LONGTEXT DEFAULT '[]',
    `furniture`       LONGTEXT DEFAULT '[]',
    `last_tax_paid`   TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    `created_at`      TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Indexes for frequently queried columns.
-- plotid has an implicit index via UNIQUE; citizenid and is_complete do not.
CREATE INDEX IF NOT EXISTS idx_st_plots_citizenid   ON st_plots(citizenid);
CREATE INDEX IF NOT EXISTS idx_st_plots_is_complete ON st_plots(is_complete);
