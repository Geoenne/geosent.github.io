-- ═══════════════════════════════════════════════════════════════
--  GeoSent Shield — PostgreSQL 16 Production Schema
--  © 2026 GeoSent Technologies, Inc. — CONFIDENTIAL
--
--  USAGE:
--    psql -h <host> -U <superuser> -d geosent -f backend-schema.sql
--
--  SECURITY MODEL:
--    • All PII encrypted via AES-256-GCM (AWS KMS envelope encryption)
--    • email stored as SHA-256 hash for queries + encrypted for display
--    • Row-Level Security (RLS) enforces per-user data isolation
--    • Audit log is append-only (no UPDATE / DELETE allowed)
--    • IP addresses stored as SHA-256 hash only — never raw
--    • Network scan data (subnets, IPs) encrypted — reveals home location
-- ═══════════════════════════════════════════════════════════════

-- Prerequisites
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "btree_gist"; -- for range overlap indexes

-- Application role (least-privilege — no superuser, no CREATE TABLE)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_user') THEN
    CREATE ROLE app_user LOGIN;
  END IF;
END $$;


-- ══════════════════════════════════════════════════════════════════
--  BROKERS (master list — no PII, safe for plaintext)
-- ══════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS brokers (
  id                  VARCHAR(40)   PRIMARY KEY,
  name                VARCHAR(120)  NOT NULL,
  category            VARCHAR(60),
  removal_method      VARCHAR(20)   NOT NULL
                      CHECK (removal_method IN ('form','email','ccpa','mail','api')),
  dpo_email           VARCHAR(200),
  form_url            TEXT,
  mailing_address     JSONB,        -- {street, city, state, zip, country}
  legal_jurisdiction  VARCHAR(10)   DEFAULT 'us' CHECK (legal_jurisdiction IN ('us','eu','both')),
  typical_days        SMALLINT      CHECK (typical_days > 0),
  recurrence_days     SMALLINT      DEFAULT 90,
  is_active           BOOLEAN       DEFAULT TRUE,
  last_verified_at    TIMESTAMPTZ
);

COMMENT ON TABLE  brokers IS 'Master list of 340+ data brokers. No PII stored here.';
COMMENT ON COLUMN brokers.recurrence_days IS 'How often (days) broker typically re-lists removed data.';

GRANT SELECT ON brokers TO app_user;  -- read-only for app; written by admin scripts


-- ══════════════════════════════════════════════════════════════════
--  USERS — all PII columns encrypted at application layer
-- ══════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS users (
  id                    UUID          PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Email: stored two ways for different use cases
  --   email_hash      → SHA-256(lower(trim(email))) — for lookup/dedup, never decrypt
  --   email_encrypted → AES-256-GCM ciphertext — for display/sending, decrypt on demand
  email_hash            CHAR(64)      UNIQUE NOT NULL,
  email_encrypted       BYTEA         NOT NULL,

  -- Other PII — all encrypted, all nullable (collected progressively)
  full_name_encrypted   BYTEA,
  zip_encrypted         BYTEA,
  dob_encrypted         BYTEA,
  phone_encrypted       BYTEA,

  -- AWS KMS Data Encryption Key reference (the DEK ciphertext is stored here, not the key itself)
  -- To decrypt a PII column: call KMS.Decrypt(kms_encrypted_dek) → DEK → AES-GCM decrypt column
  kms_encrypted_dek     BYTEA         NOT NULL,    -- encrypted DEK blob from KMS
  kms_key_arn           VARCHAR(200)  NOT NULL,    -- ARN of the KMS CMK used to encrypt DEK

  -- App state (non-PII, safe in plaintext)
  cyber_score           SMALLINT      DEFAULT 50 NOT NULL CHECK (cyber_score BETWEEN 0 AND 100),
  plan                  VARCHAR(10)   DEFAULT 'free' NOT NULL
                        CHECK (plan IN ('free','pro','family','b2b')),
  plan_expires_at       TIMESTAMPTZ,
  stripe_customer_id    VARCHAR(30)   UNIQUE,

  -- GDPR/CCPA lifecycle
  created_at            TIMESTAMPTZ   DEFAULT NOW() NOT NULL,
  updated_at            TIMESTAMPTZ   DEFAULT NOW() NOT NULL,
  deleted_at            TIMESTAMPTZ,                -- soft-delete; hard-delete cron after 30d
  deletion_requested_at TIMESTAMPTZ,               -- when user submitted deletion request
  deletion_reason       VARCHAR(60)   CHECK (deletion_reason IN (
                          'user_request','ccpa','gdpr','account_merge','fraud',NULL))
);

COMMENT ON TABLE  users IS 'Core user table. ALL PII columns encrypted via AWS KMS envelope encryption.';
COMMENT ON COLUMN users.email_hash IS 'SHA-256(lower(trim(email))). Used for all lookups. Never decrypted.';
COMMENT ON COLUMN users.kms_encrypted_dek IS 'AES DEK encrypted by AWS KMS CMK. Never store plaintext DEK.';
COMMENT ON COLUMN users.deleted_at IS 'Soft delete. Hard delete + KMS key destruction scheduled 30 days after.';

CREATE UNIQUE INDEX IF NOT EXISTS idx_users_email_hash       ON users (email_hash);
CREATE INDEX        IF NOT EXISTS idx_users_plan             ON users (plan) WHERE deleted_at IS NULL;
CREATE INDEX        IF NOT EXISTS idx_users_stripe           ON users (stripe_customer_id) WHERE stripe_customer_id IS NOT NULL;
CREATE INDEX        IF NOT EXISTS idx_users_deletion_pending ON users (deletion_requested_at) WHERE deleted_at IS NULL;

GRANT SELECT, INSERT, UPDATE ON users TO app_user;


-- ══════════════════════════════════════════════════════════════════
--  USER_BREACHES
-- ══════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS user_breaches (
  id                  UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id             UUID          NOT NULL REFERENCES users(id) ON DELETE CASCADE,

  -- Breach metadata (from HIBP — NOT PII, safe as plaintext)
  source              VARCHAR(120)  NOT NULL,   -- e.g. "LinkedIn", "Ticketmaster"
  breach_date         DATE,
  data_classes        TEXT[]        NOT NULL DEFAULT '{}',
  risk_level          VARCHAR(10)   NOT NULL DEFAULT 'medium'
                      CHECK (risk_level IN ('high','medium','low')),
  hibp_name           VARCHAR(120),             -- HIBP canonical Name field (unique per breach)
  pwn_count           BIGINT,                   -- total accounts in breach (from HIBP)

  -- Lifecycle
  first_detected_at   TIMESTAMPTZ   DEFAULT NOW() NOT NULL,
  last_seen_at        TIMESTAMPTZ   DEFAULT NOW() NOT NULL,
  acknowledged_at     TIMESTAMPTZ,              -- user tapped "I know"
  resolved_at         TIMESTAMPTZ               -- password changed / card replaced
);

COMMENT ON TABLE user_breaches IS 'HIBP breach records per user. No PII stored — breach metadata only.';
COMMENT ON COLUMN user_breaches.hibp_name IS 'Canonical HIBP Name field — used as dedup key per user.';

CREATE INDEX        IF NOT EXISTS idx_user_breaches_user    ON user_breaches (user_id);
CREATE INDEX        IF NOT EXISTS idx_user_breaches_risk    ON user_breaches (user_id, risk_level);
CREATE INDEX        IF NOT EXISTS idx_user_breaches_unack   ON user_breaches (user_id) WHERE acknowledged_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_user_breaches_dedup   ON user_breaches (user_id, hibp_name)
  WHERE hibp_name IS NOT NULL;

GRANT SELECT, INSERT, UPDATE ON user_breaches TO app_user;


-- ══════════════════════════════════════════════════════════════════
--  REMOVAL_REQUESTS — core operational table
-- ══════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS removal_requests (
  id                  UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  ref                 VARCHAR(35)   UNIQUE NOT NULL,  -- GS-{timestamp_ms}-{BROKER_CODE}
  user_id             UUID          NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  broker_id           VARCHAR(40)   NOT NULL REFERENCES brokers(id),

  -- Request details
  method              VARCHAR(20)   NOT NULL CHECK (method IN ('form','email','ccpa','mail','api')),
  legal_basis         VARCHAR(60),   -- "CCPA §1798.105" / "GDPR Art. 17" / "direct"
  record_url          TEXT,          -- broker listing URL (from discovery scan)
  match_confidence    SMALLINT       CHECK (match_confidence BETWEEN 0 AND 100),  -- ≥82 to proceed

  -- Status lifecycle
  status              VARCHAR(20)   NOT NULL DEFAULT 'queued'
                      CHECK (status IN (
                        'queued','submitted','pending','acknowledged',
                        'removed','failed','escalated','resubmitted'
                      )),

  -- Timestamps
  queued_at           TIMESTAMPTZ   DEFAULT NOW() NOT NULL,
  submitted_at        TIMESTAMPTZ,
  acknowledged_at     TIMESTAMPTZ,
  verified_at         TIMESTAMPTZ,
  failed_at           TIMESTAMPTZ,

  -- Broker reply data (parsed by Claude API)
  broker_case_number  VARCHAR(100),
  broker_eta_date     DATE,
  broker_reply_raw    TEXT,          -- raw reply email text (may contain partial PII from broker)

  -- Outcome
  score_delta         SMALLINT      DEFAULT 0,
  certificate_s3_key  TEXT,          -- S3 key: {user_id}/{ref}.pdf

  -- Retry / escalation tracking
  attempt_count       SMALLINT      DEFAULT 1 NOT NULL,
  escalated_to        VARCHAR(20)   CHECK (escalated_to IN ('form','email','ccpa','mail','api',NULL))
);

COMMENT ON TABLE  removal_requests IS '7-stage pipeline state for each broker removal attempt.';
COMMENT ON COLUMN removal_requests.ref IS 'Court-admissible unique reference: GS-{timestamp}-{BROKER}.';
COMMENT ON COLUMN removal_requests.match_confidence IS 'ML identity fingerprint score. Min 82 to submit.';
COMMENT ON COLUMN removal_requests.broker_reply_raw IS 'Raw broker reply email. May contain PII — handle carefully.';

CREATE INDEX IF NOT EXISTS idx_removal_user       ON removal_requests (user_id);
CREATE INDEX IF NOT EXISTS idx_removal_status     ON removal_requests (status);
CREATE INDEX IF NOT EXISTS idx_removal_broker     ON removal_requests (broker_id, status);
CREATE INDEX IF NOT EXISTS idx_removal_queued     ON removal_requests (queued_at) WHERE status = 'queued';
CREATE INDEX IF NOT EXISTS idx_removal_verify     ON removal_requests (verified_at) WHERE status = 'pending';

GRANT SELECT, INSERT, UPDATE ON removal_requests TO app_user;


-- ══════════════════════════════════════════════════════════════════
--  DISCOVERIES — raw scraper results
-- ══════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS discoveries (
  id          UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID          NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  broker_id   VARCHAR(40)   NOT NULL REFERENCES brokers(id),
  found       BOOLEAN       NOT NULL DEFAULT FALSE,
  record_url  TEXT,         -- URL of the user's listing on the broker site
  scanned_at  TIMESTAMPTZ   DEFAULT NOW() NOT NULL
);

COMMENT ON TABLE discoveries IS 'One row per broker scan per user per day. Populated by Puppeteer scraper.';

CREATE INDEX IF NOT EXISTS idx_discoveries_user    ON discoveries (user_id, scanned_at DESC);
CREATE INDEX IF NOT EXISTS idx_discoveries_found   ON discoveries (user_id, broker_id) WHERE found = TRUE;
CREATE UNIQUE INDEX IF NOT EXISTS idx_discoveries_dedup ON discoveries
  (user_id, broker_id, (scanned_at::DATE));

GRANT SELECT, INSERT ON discoveries TO app_user;


-- ══════════════════════════════════════════════════════════════════
--  NETWORK_SCANS — home IoT scan results (SENSITIVE — subnet is PII)
-- ══════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS network_scans (
  id                  UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id             UUID          NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  -- subnet_encrypted: AES-256-GCM(subnet_cidr, DEK) — subnet reveals home location
  subnet_encrypted    BYTEA,
  device_count        SMALLINT,
  risk_count          SMALLINT      DEFAULT 0,
  scanned_at          TIMESTAMPTZ   DEFAULT NOW() NOT NULL,
  -- devices_encrypted: AES-256-GCM(JSON array of {name, ip_fragment, mac_prefix, risk, ports})
  -- IP fragments stored only (last octet omitted), MAC prefix only (first 3 octets)
  devices_encrypted   BYTEA
);

COMMENT ON TABLE  network_scans IS 'IoT home network scan results. subnet and device details encrypted.';
COMMENT ON COLUMN network_scans.devices_encrypted IS 'JSON array encrypted. Store IP fragments and MAC prefixes only — not full addresses.';

CREATE INDEX IF NOT EXISTS idx_network_user ON network_scans (user_id, scanned_at DESC);

GRANT SELECT, INSERT ON network_scans TO app_user;


-- ══════════════════════════════════════════════════════════════════
--  AUDIT_LOG — immutable event trail. ZERO PII in any column.
-- ══════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS audit_log (
  id          BIGSERIAL     PRIMARY KEY,
  user_id     UUID          REFERENCES users(id) ON DELETE SET NULL,
  event       VARCHAR(80)   NOT NULL,
  actor       VARCHAR(30)   NOT NULL DEFAULT 'system'
              CHECK (actor IN ('system','user','broker','cron','webhook')),
  -- metadata: NEVER put PII here. Examples of CORRECT usage:
  --   {"broker_id":"spokeo","method":"form","score_delta":3,"ref":"GS-17..."}
  --   {"breach_source":"LinkedIn","risk_level":"high"}
  --   {"plan_change":"free→pro","stripe_event":"evt_xxx"}
  -- WRONG (do not do this):
  --   {"email":"user@example.com"} ← PII violation
  --   {"name":"John Smith"}        ← PII violation
  metadata    JSONB         NOT NULL DEFAULT '{}',
  -- IP hashed for security monitoring — never raw IP
  ip_hash     CHAR(64),    -- SHA-256(ip_address + daily_salt)
  created_at  TIMESTAMPTZ  DEFAULT NOW() NOT NULL
);

COMMENT ON TABLE  audit_log IS '7-year retention. Court-admissible. Append-only. ZERO PII in any column.';
COMMENT ON COLUMN audit_log.metadata IS 'MUST NOT contain PII. IDs, counts, enum values only.';
COMMENT ON COLUMN audit_log.ip_hash  IS 'SHA-256(ip + daily_salt). Never raw IP address.';

-- Row-Level Security: append-only (no UPDATE, no DELETE by any app role)
ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;
CREATE POLICY audit_log_insert_only ON audit_log FOR INSERT WITH CHECK (true);
-- app_user gets INSERT only (no SELECT/UPDATE/DELETE policies → access denied)
GRANT INSERT ON audit_log TO app_user;
-- Read access: separate read-only audit role, accessed by compliance tooling only
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'audit_reader') THEN
    CREATE ROLE audit_reader;
  END IF;
END $$;
GRANT SELECT ON audit_log TO audit_reader;

CREATE INDEX IF NOT EXISTS idx_audit_user   ON audit_log (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_event  ON audit_log (event, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_recent ON audit_log (created_at DESC);

-- ══════════════════════════════════════════════════════════════════
--  ROW-LEVEL SECURITY  — enforce per-request user isolation
-- ══════════════════════════════════════════════════════════════════
-- Before each DB transaction, app sets: SET LOCAL app.current_user_id = '{uuid}';
-- RLS policies below use this to restrict each query to the authenticated user's rows.

ALTER TABLE users             ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_breaches     ENABLE ROW LEVEL SECURITY;
ALTER TABLE removal_requests  ENABLE ROW LEVEL SECURITY;
ALTER TABLE discoveries       ENABLE ROW LEVEL SECURITY;
ALTER TABLE network_scans     ENABLE ROW LEVEL SECURITY;

-- Users can only see and modify their own row
CREATE POLICY rls_users_own ON users
  USING (id = current_setting('app.current_user_id', TRUE)::UUID);

CREATE POLICY rls_breaches_own ON user_breaches
  USING (user_id = current_setting('app.current_user_id', TRUE)::UUID);

CREATE POLICY rls_removals_own ON removal_requests
  USING (user_id = current_setting('app.current_user_id', TRUE)::UUID);

CREATE POLICY rls_discoveries_own ON discoveries
  USING (user_id = current_setting('app.current_user_id', TRUE)::UUID);

CREATE POLICY rls_network_own ON network_scans
  USING (user_id = current_setting('app.current_user_id', TRUE)::UUID);

-- Service worker bypass: automation pipeline runs as 'pipeline_worker' role
-- with its own broader policies (not shown — scoped to active job IDs)


-- ══════════════════════════════════════════════════════════════════
--  SEED: core broker list (30 entries — extend to 340 from full list)
-- ══════════════════════════════════════════════════════════════════
INSERT INTO brokers (id, name, category, removal_method, form_url, typical_days)
VALUES
  ('spokeo',       'Spokeo',             'People Search',    'form',  'https://www.spokeo.com/optout',                  7),
  ('whitepages',   'Whitepages',         'People Search',    'form',  'https://www.whitepages.com/suppression-requests', 5),
  ('truthfinder',  'TruthFinder',        'Background Check', 'form',  'https://www.truthfinder.com/opt-out/',           21),
  ('intelius',     'Intelius',           'Background Check', 'form',  'https://www.intelius.com/opt-out',               10),
  ('radaris',      'Radaris',            'People Search',    'email', NULL,                                             14),
  ('acxiom',       'Acxiom',             'Data Aggregator',  'mail',  NULL,                                             45),
  ('lexisnexis',   'LexisNexis',         'Legal Aggregator', 'ccpa',  NULL,                                             60),
  ('epsilon',      'Epsilon',            'Marketing Data',   'ccpa',  NULL,                                             45),
  ('mylife',       'MyLife',             'Reputation',       'email', NULL,                                             10),
  ('beenverified', 'BeenVerified',       'Background Check', 'form',  'https://www.beenverified.com/app/optout/search',  14),
  ('peoplefinder', 'PeopleFinder',       'People Search',    'form',  'https://www.peoplefinder.com/optout.php',         7),
  ('instantckm',   'Instant Checkmate',  'Background Check', 'form',  'https://www.instantcheckmate.com/opt-out/',      21),
  ('ussearch',     'US Search',          'People Search',    'form',  'https://www.ussearch.com/opt-out/',               7),
  ('pipl',         'Pipl',               'Deep Web',         'api',   NULL,                                             60),
  ('oracle_dc',    'Oracle Data Cloud',  'Marketing Data',   'ccpa',  NULL,                                             45),
  ('experian_mkt', 'Experian Marketing', 'Marketing Data',   'ccpa',  NULL,                                             45),
  ('transunion',   'TransUnion (TLO)',   'Data Aggregator',  'ccpa',  NULL,                                             45),
  ('checkpeople',  'CheckPeople',        'Background Check', 'form',  'https://www.checkpeople.com/opt-out',             14),
  ('familytree',   'FamilyTreeNow',      'People Search',    'form',  'https://www.familytreenow.com/optout',             3),
  ('fastpeople',   'FastPeopleSearch',   'People Search',    'form',  'https://www.fastpeoplesearch.com/removal',         1)
ON CONFLICT (id) DO NOTHING;

-- ══════════════════════════════════════════════════════════════════
--  GRANTS summary
-- ══════════════════════════════════════════════════════════════════
-- app_user:    SELECT,INSERT,UPDATE on users,user_breaches,removal_requests
--              SELECT,INSERT on discoveries,network_scans
--              INSERT on audit_log (append-only)
--              SELECT on brokers
-- audit_reader: SELECT on audit_log only (compliance tooling)
-- pipeline_worker: separate role with broader removal_requests access (define separately)
-- superuser:   schema management, RLS bypass via SET row_security = off (emergency only)

-- End of schema.sql
