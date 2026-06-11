-- BashClaw SQLite Schema v1
-- Compatible with SQLite 3.38.0+ (SiYuan uses 3.38.0)
-- WAL mode for concurrent read/write

PRAGMA journal_mode=WAL;
PRAGMA page_size=32768;
PRAGMA busy_timeout=5000;
PRAGMA foreign_keys=ON;

-- Knowledge cards (distilled from conversations)
-- Maps loosely to SiYuan's blocks table structure
CREATE TABLE IF NOT EXISTS cards (
  id          TEXT PRIMARY KEY,
  title       TEXT NOT NULL,
  scope       TEXT NOT NULL DEFAULT '',
  decision    TEXT NOT NULL DEFAULT '',
  why         TEXT NOT NULL DEFAULT '',
  pitfalls    TEXT NOT NULL DEFAULT '[]',   -- JSON array
  evidence    TEXT NOT NULL DEFAULT '',
  risk_tags   TEXT NOT NULL DEFAULT '[]',   -- JSON array
  issue_type  TEXT NOT NULL DEFAULT '',
  change_type TEXT NOT NULL DEFAULT '',
  superseded_by TEXT DEFAULT NULL,
  merge_count INTEGER NOT NULL DEFAULT 0,
  created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
  updated_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- FTS5 index for card search (standard unicode61 tokenizer, not SiYuan's custom one)
CREATE VIRTUAL TABLE IF NOT EXISTS cards_fts USING fts5(
  title, scope, decision, why, pitfalls, evidence, risk_tags,
  content=cards,
  content_rowid=rowid,
  tokenize='unicode61'
);

-- Triggers to keep FTS in sync
CREATE TRIGGER IF NOT EXISTS cards_ai AFTER INSERT ON cards BEGIN
  INSERT INTO cards_fts(rowid, title, scope, decision, why, pitfalls, evidence, risk_tags)
  VALUES (new.rowid, new.title, new.scope, new.decision, new.why, new.pitfalls, new.evidence, new.risk_tags);
END;

CREATE TRIGGER IF NOT EXISTS cards_ad AFTER DELETE ON cards BEGIN
  INSERT INTO cards_fts(cards_fts, rowid, title, scope, decision, why, pitfalls, evidence, risk_tags)
  VALUES ('delete', old.rowid, old.title, old.scope, old.decision, old.why, old.pitfalls, old.evidence, old.risk_tags);
END;

CREATE TRIGGER IF NOT EXISTS cards_au AFTER UPDATE ON cards BEGIN
  INSERT INTO cards_fts(cards_fts, rowid, title, scope, decision, why, pitfalls, evidence, risk_tags)
  VALUES ('delete', old.rowid, old.title, old.scope, old.decision, old.why, old.pitfalls, old.evidence, old.risk_tags);
  INSERT INTO cards_fts(rowid, title, scope, decision, why, pitfalls, evidence, risk_tags)
  VALUES (new.rowid, new.title, new.scope, new.decision, new.why, new.pitfalls, new.evidence, new.risk_tags);
END;

-- Conversations (raw chat sessions from any source)
CREATE TABLE IF NOT EXISTS conversations (
  id          TEXT PRIMARY KEY,
  source      TEXT NOT NULL DEFAULT 'unknown',  -- claude_code, chatgpt, claude_web, cursor
  title       TEXT NOT NULL DEFAULT '',
  external_id TEXT DEFAULT '',                   -- original session ID from source platform
  message_count INTEGER NOT NULL DEFAULT 0,
  created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
  imported_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- Messages within conversations
CREATE TABLE IF NOT EXISTS messages (
  id              TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL REFERENCES conversations(id),
  role            TEXT NOT NULL DEFAULT 'user',  -- user, assistant, system, tool
  content         TEXT NOT NULL DEFAULT '',
  seq             INTEGER NOT NULL DEFAULT 0,    -- message order within conversation
  created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_messages_conv ON messages(conversation_id, seq);

-- Provenance: card <-> conversation links
CREATE TABLE IF NOT EXISTS card_sources (
  card_id         TEXT NOT NULL REFERENCES cards(id),
  conversation_id TEXT NOT NULL REFERENCES conversations(id),
  message_range   TEXT DEFAULT '',  -- e.g. "12-18" = messages 12-18 in conversation
  created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
  PRIMARY KEY (card_id, conversation_id)
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_cards_issue_type ON cards(issue_type);
CREATE INDEX IF NOT EXISTS idx_cards_superseded ON cards(superseded_by);
CREATE INDEX IF NOT EXISTS idx_conversations_source ON conversations(source);
