-- Nexus Arena: Phase 5 Persistence Schema
-- Event-sourced item ledger + accounts

-- Accounts: minimal player identity
CREATE TABLE accounts (
    account_id BIGSERIAL PRIMARY KEY,
    display_name VARCHAR(64) NOT NULL UNIQUE,
    created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

-- Item definitions (data-driven, could be JSON config later)
CREATE TABLE item_defs (
    item_def_id SERIAL PRIMARY KEY,
    item_name VARCHAR(64) NOT NULL UNIQUE,
    item_type VARCHAR(32) NOT NULL,  -- 'consumable', 'equipment', 'resource'
    stack_max INT NOT NULL DEFAULT 1,
    created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

-- Item instances: actual items owned by accounts
CREATE TABLE item_instances (
    item_instance_id BIGSERIAL PRIMARY KEY,
    account_id BIGINT NOT NULL REFERENCES accounts(account_id),
    item_def_id INT NOT NULL REFERENCES item_defs(item_def_id),
    stack_count INT NOT NULL DEFAULT 1,
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    CHECK (stack_count > 0)
);

-- Ledger: append-only transaction log (event sourcing)
CREATE TABLE ledger_entries (
    ledger_id BIGSERIAL PRIMARY KEY,
    account_id BIGINT NOT NULL REFERENCES accounts(account_id),
    entry_type VARCHAR(16) NOT NULL,  -- 'grant', 'consume', 'transfer'
    item_def_id INT NOT NULL REFERENCES item_defs(item_def_id),
    quantity INT NOT NULL,
    related_account_id BIGINT REFERENCES accounts(account_id),  -- For transfers
    reason VARCHAR(128),
    created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

-- Indexes for common queries
CREATE INDEX idx_item_instances_account ON item_instances(account_id);
CREATE INDEX idx_ledger_entries_account ON ledger_entries(account_id);
CREATE INDEX idx_ledger_entries_created ON ledger_entries(created_at);

-- Seed some basic item definitions
INSERT INTO item_defs (item_name, item_type, stack_max) VALUES
    ('Health Potion', 'consumable', 99),
    ('Mana Potion', 'consumable', 99),
    ('Arcane Staff', 'equipment', 1),
    ('Mystic Ore', 'resource', 999);
