# GeoSent Shield — Partner Demo v6

> AI-powered personal cybersecurity: breach monitoring · automated data broker removal · home network scanning · live Claude AI Coach

[![Demo](https://img.shields.io/badge/Live_Demo-GitHub_Pages-00d4aa?style=flat-square)](https://YOUR-USERNAME.github.io/geosent-shield/)
[![License](https://img.shields.io/badge/License-Proprietary-ff4757?style=flat-square)](/)
[![Claude](https://img.shields.io/badge/Powered_by-Claude_Sonnet_4-0099ff?style=flat-square)](https://anthropic.com)

---

## Quick Start — GitHub Pages Deployment

### 3-Step Deploy

```bash
# 1. Fork or clone this repo
git clone https://github.com/YOUR-USERNAME/geosent-shield.git
cd geosent-shield

# 2. Add the .nojekyll file (prevents GitHub Pages from mangling the HTML)
touch .nojekyll
git add .nojekyll
git commit -m "Add .nojekyll for GitHub Pages"
git push

# 3. Enable Pages
# GitHub → Settings → Pages → Source: Deploy from branch → main → / (root) → Save
```

Your demo is live at `https://YOUR-USERNAME.github.io/geosent-shield/`

### Required Repo Structure

```
geosent-shield/
├── index.html          ← The demo (rename from v6_GeoSent_Shield.html)
├── .nojekyll           ← Required: prevents Jekyll processing
└── README.md           ← This file
```

> **`.nojekyll` is mandatory.** Without it, GitHub's Jekyll processor will strip files starting with `_` and may mangle certain HTML syntax.

---

## Runtime API Key Setup (Demo Viewers)

The demo is fully functional without API keys (intelligent offline fallbacks). To enable live features:

1. Open the demo → tap **More** (Settings tab) → **Demo API Keys**
2. Enter your **Claude API key** to enable the live AI Coach
3. Enter your **HIBP API key** (optional) to run real breach lookups against your email

| Feature | Without keys | With Claude key | With Claude + HIBP |
|---|---|---|---|
| AI Coach | Offline fallbacks | ✅ Live Claude | ✅ Live + real breach context |
| Breach scan | Simulated (Alex persona) | Simulated | ✅ Real HIBP v3 lookup |
| Broker removal | Demo animation | Demo animation | Demo animation |
| Network scan | Simulated | Simulated | Simulated |

### Where to Get Keys

| Key | URL | Cost |
|---|---|---|
| Claude API | https://console.anthropic.com/keys | Free tier / pay-as-you-go |
| HIBP | https://haveibeenpwned.com/API/Key | ~$3.50/mo |

> **Security**: Keys are stored as JavaScript variables in the browser session only. They are never written to localStorage, never logged, and sent only to `api.anthropic.com` and `haveibeenpwned.com`. Cleared on page refresh.

---

## Technical Backend Stack

The demo frontend simulates a production backend. This section defines the full production stack.

### Overview Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  CLIENT LAYER                                                   │
│  iOS / Android (React Native)  ·  Web PWA (Next.js 14)          │
└────────────────────────┬────────────────────────────────────────┘
                         │ HTTPS / TLS 1.3
┌────────────────────────▼────────────────────────────────────────┐
│  EDGE LAYER                                                     │
│  CloudFront CDN  ·  AWS WAF (OWASP rules)  ·  AWS Shield Std    │
└────────────────────────┬────────────────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────────────────┐
│  API LAYER  (AWS API Gateway + Node.js 20 / Express)            │
│  /v1/auth   /v1/breaches   /v1/removal   /v1/ai   /v1/network   │
│  Auth: AWS Cognito + JWT RS256 + PKCE OAuth 2.0                 │
└──────────┬──────────────┬──────────────┬───────────────────────┘
           │              │              │
    ┌──────▼──┐    ┌──────▼──┐   ┌──────▼──────────────────┐
    │ Breach  │    │ Privacy │   │  AI Coach Service        │
    │ Engine  │    │ Engine  │   │  Claude claude-sonnet-4  │
    └──────┬──┘    └──────┬──┘   └──────────────────────────┘
           │              │
┌──────────▼──────────────▼──────────────────────────────────────┐
│  AUTOMATION LAYER                                               │
│  Bull Queue (Redis)  ·  Puppeteer Pool  ·  2Captcha  ·  Proxies │
│  AWS SES (email)  ·  Lob.com (certified mail)                   │
└──────────┬──────────────────────────────────────────────────────┘
           │
┌──────────▼──────────────────────────────────────────────────────┐
│  PERSISTENCE LAYER                                              │
│  PostgreSQL 16 (RDS)  ·  Redis 7 (Upstash)  ·  S3 + KMS        │
└─────────────────────────────────────────────────────────────────┘
```

### Service Breakdown

| Service | Technology | Purpose |
|---|---|---|
| API Framework | Node.js 20 + Express 4 | REST API, webhook receivers |
| Auth | AWS Cognito + JWT RS256 | User sessions, API key management |
| Task Queue | Bull 4 + Redis | Broker removal job scheduling |
| Scraping | Puppeteer 22 + Bright Data | Broker discovery and opt-out form-fill |
| CAPTCHA | 2Captcha API | reCAPTCHA v2/v3, hCaptcha on broker forms |
| Email | AWS SES | Opt-out email dispatch + reply tracking |
| Physical Mail | Lob.com | Certified USPS mail to Acxiom, LexisNexis |
| Push | Firebase FCM | Breach alerts, removal confirmations |
| Primary DB | PostgreSQL 16 on RDS | All user data, removal tracking, audit log |
| Cache / Queue | Redis 7 (Upstash) | Rate limiting, dedup, session cache |
| Object Storage | AWS S3 | Removal certificates (signed PDFs) |
| Encryption | AWS KMS | DEK management, envelope encryption |
| AI | Anthropic Claude claude-sonnet-4 | AI Coach + email reply parsing |

---

## Breach Monitoring API Stack

### Primary: HaveIBeenPwned (HIBP) v3

```
Base URL:  https://haveibeenpwned.com/api/v3/
Auth:      hibp-api-key: {YOUR_KEY}  (header)
Rate:      1 req/1.5s per key (Pwned 3 plan: unlimited)
CORS:      Supported — browser-side calls allowed
```

#### Endpoints Used

```
GET /breachedaccount/{email}?truncateResponse=false
  → Returns array of breach objects with DataClasses, BreachDate, etc.
  → 404 = no breaches (clean)
  → Used in onboarding scan + weekly re-checks

GET /breaches
  → Master list of all 700+ breach records (cached daily)
  → Used to pre-populate breach database

GET /pastes/{email}
  → Dark web paste sites (Pastebin, etc.)
  → Supplemental to breach data

POST /range/{hashPrefix}   ← k-anonymity password check
  → Only first 5 chars of SHA-1(password) sent
  → Server returns all suffix matches + counts
  → Password never leaves device in plaintext
```

#### HIBP Breach Object → Internal Mapping

```javascript
// HIBP returns:
{
  "Name": "LinkedIn",
  "Title": "LinkedIn",
  "BreachDate": "2012-05-05",
  "AddedDate": "2016-05-22T21:35:40Z",
  "ModifiedDate": "2016-05-22T21:35:40Z",
  "PwnCount": 164611595,
  "Description": "...",
  "LogoPath": "https://haveibeenpwned.com/Content/Images/PwnedLogos/LinkedIn.png",
  "DataClasses": ["Email addresses", "Passwords"],
  "IsVerified": true,
  "IsFabricated": false,
  "IsSensitive": false,
  "IsRetired": false,
  "IsSpamList": false
}

// Our internal user_breaches row:
{
  user_id: "uuid",
  source: "LinkedIn",            // b.Title
  breach_date: "2012-05-05",     // b.BreachDate
  data_classes: ["Email addresses", "Passwords"],   // b.DataClasses
  risk_level: "high",            // derived: password/CC/SSN → high
  hibp_name: "LinkedIn",         // b.Name (canonical HIBP ID)
  first_detected_at: NOW()
}
```

### Secondary: Pipl API (Identity Graph for Broker Discovery)

```
Base URL:  https://api.pipl.com/search/
Auth:      key={API_KEY}  (query param — server-side only, never in browser)
Use:       Deep identity resolution for broker fingerprinting
           Correlates name + email + ZIP → age, relatives, prior addresses
Rate:      Contact Pipl for enterprise terms (~$0.15/search)
```

> **Important**: Pipl API key must NEVER be exposed in frontend code. All Pipl calls go through your backend `/v1/identity` endpoint.

### Tertiary: OneRep API (White-Label Broker Monitoring)

```
Type:      Enterprise white-label — contact sales@onerep.com
Use:       Pre-built opt-out workflows for 195+ brokers
           Supplements our Puppeteer engine for complex brokers
Cost:      ~$0.25/user/month at volume
```

---

## Database Schema (PostgreSQL 16)

Full DDL — run in order on a fresh database.

```sql
-- Enable UUID generation
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ╔══════════════════════════════════════════════════════════╗
-- ║  USERS                                                  ║
-- ║  All PII encrypted via AES-256-GCM (AWS KMS DEK)        ║
-- ╚══════════════════════════════════════════════════════════╝
CREATE TABLE users (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  -- Email stored TWO ways:
  --   email_hash     → SHA-256 for lookup/dedup (never decrypted for queries)
  --   email_encrypted → AES-256-GCM ciphertext for display/use
  email_hash          CHAR(64)     UNIQUE NOT NULL, -- SHA-256(lower(email))
  email_encrypted     BYTEA        NOT NULL,         -- AES-256-GCM(email, DEK)
  -- PII fields — ALL encrypted, NONE in plaintext
  full_name_encrypted BYTEA,
  zip_encrypted       BYTEA,
  dob_encrypted       BYTEA,
  phone_encrypted     BYTEA,
  -- KMS DEK reference (envelope encryption — DEK itself never stored plaintext)
  kms_key_id          VARCHAR(200) NOT NULL,         -- AWS KMS key ARN
  -- App state
  cyber_score         SMALLINT     DEFAULT 50 CHECK (cyber_score BETWEEN 0 AND 100),
  plan                VARCHAR(10)  DEFAULT 'free' CHECK (plan IN ('free','pro','family','b2b')),
  plan_expires_at     TIMESTAMPTZ,
  stripe_customer_id  VARCHAR(30)  UNIQUE,           -- Stripe cus_xxx
  -- Soft delete (CCPA §1798.105 / GDPR Art. 17 — hard delete after 30 days)
  created_at          TIMESTAMPTZ  DEFAULT NOW()     NOT NULL,
  updated_at          TIMESTAMPTZ  DEFAULT NOW()     NOT NULL,
  deleted_at          TIMESTAMPTZ                    -- set on deletion request
);

-- Lookup index: email hash (used for dedup and login)
CREATE UNIQUE INDEX idx_users_email_hash ON users (email_hash);
CREATE INDEX idx_users_plan ON users (plan) WHERE deleted_at IS NULL;

-- ╔══════════════════════════════════════════════════════════╗
-- ║  USER_BREACHES                                          ║
-- ║  One row per breach per user. Re-scanned weekly.        ║
-- ╚══════════════════════════════════════════════════════════╝
CREATE TABLE user_breaches (
  id                  UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id             UUID         NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  -- Breach info (from HIBP — not PII, safe in plaintext)
  source              VARCHAR(120) NOT NULL,   -- "LinkedIn", "Ticketmaster"
  breach_date         DATE,
  data_classes        TEXT[]       NOT NULL DEFAULT '{}',
  risk_level          VARCHAR(10)  NOT NULL DEFAULT 'medium'
                                   CHECK (risk_level IN ('high','medium','low')),
  hibp_name           VARCHAR(120),            -- HIBP canonical Name field
  description         TEXT,
  -- Lifecycle
  first_detected_at   TIMESTAMPTZ  DEFAULT NOW() NOT NULL,
  last_seen_at        TIMESTAMPTZ  DEFAULT NOW() NOT NULL,
  acknowledged_at     TIMESTAMPTZ,             -- user tapped "I know"
  resolved_at         TIMESTAMPTZ              -- password changed, card replaced
);

CREATE INDEX idx_user_breaches_user    ON user_breaches (user_id);
CREATE INDEX idx_user_breaches_risk    ON user_breaches (user_id, risk_level);
CREATE UNIQUE INDEX idx_user_breaches_dedup ON user_breaches (user_id, hibp_name)
  WHERE hibp_name IS NOT NULL;

-- ╔══════════════════════════════════════════════════════════╗
-- ║  BROKERS                                                ║
-- ║  Master list of 340+ data brokers and their metadata.   ║
-- ╚══════════════════════════════════════════════════════════╝
CREATE TABLE brokers (
  id                  VARCHAR(40)  PRIMARY KEY,  -- "spokeo", "acxiom", etc.
  name                VARCHAR(120) NOT NULL,
  category            VARCHAR(60),               -- "People Search", "Background Check"
  removal_method      VARCHAR(20)  NOT NULL
                      CHECK (removal_method IN ('form','email','ccpa','mail','api')),
  dpo_email           VARCHAR(200),              -- DPO email for email method
  form_url            TEXT,                      -- opt-out form URL
  mailing_address     JSONB,                     -- for Lob.com certified mail
  legal_jurisdiction  VARCHAR(10)  DEFAULT 'us', -- 'us' / 'eu' / 'both'
  typical_days        SMALLINT,                  -- expected removal timeline
  recurrence_days     SMALLINT     DEFAULT 90,   -- how often they re-list (avg)
  is_active           BOOLEAN      DEFAULT TRUE,
  last_verified_at    TIMESTAMPTZ
);

-- ╔══════════════════════════════════════════════════════════╗
-- ║  REMOVAL_REQUESTS                                       ║
-- ║  One row per broker removal attempt per user.           ║
-- ║  The core operational table of the engine.              ║
-- ╚══════════════════════════════════════════════════════════╝
CREATE TABLE removal_requests (
  id                  UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  -- GS-{timestamp_ms}-{BROKER_CODE} — unique, court-admissible reference
  ref                 VARCHAR(35)  UNIQUE NOT NULL,
  user_id             UUID         NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  broker_id           VARCHAR(40)  NOT NULL REFERENCES brokers(id),
  -- What method was used and why
  method              VARCHAR(20)  NOT NULL
                      CHECK (method IN ('form','email','ccpa','mail','api')),
  legal_basis         VARCHAR(60),  -- "CCPA §1798.105" / "GDPR Art. 17" / "direct"
  record_url          TEXT,         -- URL of the broker listing (from discovery scan)
  -- Fingerprinting result
  match_confidence    SMALLINT,     -- 0-100, must be ≥82 to proceed
  -- Status lifecycle: queued → submitted → pending → removed | failed | escalated
  status              VARCHAR(20)  NOT NULL DEFAULT 'queued'
                      CHECK (status IN ('queued','submitted','pending','acknowledged',
                                        'removed','failed','escalated','resubmitted')),
  -- Timestamps
  queued_at           TIMESTAMPTZ  DEFAULT NOW() NOT NULL,
  submitted_at        TIMESTAMPTZ,
  acknowledged_at     TIMESTAMPTZ,
  verified_at         TIMESTAMPTZ,
  failed_at           TIMESTAMPTZ,
  -- Broker reply parsing (Claude API extracts structured data from email replies)
  broker_case_number  VARCHAR(100),
  broker_eta_date     DATE,
  broker_reply_raw    TEXT,        -- raw email reply text
  -- Outcome
  score_delta         SMALLINT     DEFAULT 0,     -- +2 to +5 cyber score points
  certificate_s3_key  TEXT,        -- S3 key for signed PDF certificate
  -- Retry tracking
  attempt_count       SMALLINT     DEFAULT 1,
  escalated_to        VARCHAR(20)  -- method used if escalated (e.g. form→ccpa)
);

CREATE INDEX idx_removal_user       ON removal_requests (user_id);
CREATE INDEX idx_removal_status     ON removal_requests (status);
CREATE INDEX idx_removal_broker     ON removal_requests (broker_id, status);
CREATE INDEX idx_removal_queued     ON removal_requests (queued_at) WHERE status = 'queued';

-- ╔══════════════════════════════════════════════════════════╗
-- ║  DISCOVERIES                                            ║
-- ║  Raw scan results — broker found user's listing.        ║
-- ╚══════════════════════════════════════════════════════════╝
CREATE TABLE discoveries (
  id          UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID         NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  broker_id   VARCHAR(40)  NOT NULL REFERENCES brokers(id),
  found       BOOLEAN      NOT NULL DEFAULT FALSE,
  record_url  TEXT,
  scanned_at  TIMESTAMPTZ  DEFAULT NOW() NOT NULL
);

CREATE INDEX idx_discoveries_user   ON discoveries (user_id, scanned_at DESC);
CREATE UNIQUE INDEX idx_discoveries_dedup ON discoveries (user_id, broker_id, scanned_at::DATE);

-- ╔══════════════════════════════════════════════════════════╗
-- ║  NETWORK_SCANS                                          ║
-- ║  IoT/home network scan results.                         ║
-- ╚══════════════════════════════════════════════════════════╝
CREATE TABLE network_scans (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  -- Subnet stored encrypted — it IS PII (reveals home location)
  subnet_encrypted BYTEA,
  device_count    SMALLINT,
  risk_count      SMALLINT    DEFAULT 0,
  scanned_at      TIMESTAMPTZ DEFAULT NOW() NOT NULL,
  -- Device list stored as encrypted JSONB (contains IP, MAC fragments — PII)
  devices_encrypted BYTEA
);

CREATE INDEX idx_network_user ON network_scans (user_id, scanned_at DESC);

-- ╔══════════════════════════════════════════════════════════╗
-- ║  AUDIT_LOG                                              ║
-- ║  Immutable event log. NO PII in any column.             ║
-- ║  Retained 7 years (CCPA compliance).                    ║
-- ╚══════════════════════════════════════════════════════════╝
CREATE TABLE audit_log (
  id          BIGSERIAL    PRIMARY KEY,
  user_id     UUID         REFERENCES users(id) ON DELETE SET NULL,  -- nullable: system events
  event       VARCHAR(80)  NOT NULL,  -- "removal.submitted" / "breach.detected" / "user.deleted"
  actor       VARCHAR(30)  NOT NULL DEFAULT 'system',  -- "system" / "user" / "broker" / "cron"
  -- metadata: MUST NOT contain PII — use IDs, counts, enum values only
  -- OK:    {"broker_id":"spokeo","method":"form","score_delta":3}
  -- NOT OK: {"email":"user@example.com","name":"John Smith"}
  metadata    JSONB        DEFAULT '{}',
  -- IP hashed for security monitoring without storing raw IPs
  ip_hash     CHAR(64),    -- SHA-256(ip_address) — never raw IP
  created_at  TIMESTAMPTZ  DEFAULT NOW() NOT NULL
);

-- Audit log is append-only — no UPDATE or DELETE in production
-- Enforce via Postgres RLS:
ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;
CREATE POLICY audit_log_insert_only ON audit_log FOR INSERT WITH CHECK (true);
-- (No SELECT / UPDATE / DELETE policy for application roles)
CREATE INDEX idx_audit_user   ON audit_log (user_id, created_at DESC);
CREATE INDEX idx_audit_event  ON audit_log (event, created_at DESC);

-- ╔══════════════════════════════════════════════════════════╗
-- ║  ROW-LEVEL SECURITY (RLS)                               ║
-- ║  Users can only read/write their own rows.              ║
-- ╚══════════════════════════════════════════════════════════╝
-- (Run as superuser; app connects as 'app_user' role)

ALTER TABLE users           ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_breaches   ENABLE ROW LEVEL SECURITY;
ALTER TABLE removal_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE discoveries     ENABLE ROW LEVEL SECURITY;
ALTER TABLE network_scans   ENABLE ROW LEVEL SECURITY;

-- App sets current_user_id at start of each request via SET LOCAL
CREATE POLICY users_own_row     ON users
  USING (id = current_setting('app.current_user_id')::UUID);

CREATE POLICY breaches_own_rows ON user_breaches
  USING (user_id = current_setting('app.current_user_id')::UUID);

CREATE POLICY removals_own_rows ON removal_requests
  USING (user_id = current_setting('app.current_user_id')::UUID);

CREATE POLICY discoveries_own   ON discoveries
  USING (user_id = current_setting('app.current_user_id')::UUID);

CREATE POLICY network_own       ON network_scans
  USING (user_id = current_setting('app.current_user_id')::UUID);
```

---

## PII Security Architecture

### Encryption Model

GeoSent uses **envelope encryption** via AWS KMS:

```
┌──────────────────────────────────────────────────────┐
│  Plaintext PII (e.g., "john@example.com")            │
│           │                                          │
│           ▼                                          │
│  AES-256-GCM encrypt with Data Encryption Key (DEK)  │
│           │                                          │
│           ▼                                          │
│  Ciphertext stored in: email_encrypted BYTEA         │
│                                                      │
│  DEK itself is envelope-encrypted by AWS KMS CMK     │
│  (DEK ciphertext stored in: kms_encrypted_dek)       │
│                                                      │
│  To decrypt: call KMS.Decrypt(dek_ciphertext) →      │
│  get plaintext DEK → AES-GCM decrypt column          │
└──────────────────────────────────────────────────────┘
```

**Key rotation**: CMK rotated annually (AWS KMS automatic rotation). User DEKs re-encrypted on plan change or manual request. Deleted users have DEKs destroyed within 30 days — rendering all encrypted columns permanently unreadable.

### What Is and Isn't PII in Our Schema

| Field | PII? | Storage | Notes |
|---|---|---|---|
| email_hash | No (hashed) | Plaintext | SHA-256, used for lookups |
| email_encrypted | Yes | AES-256-GCM | Decrypted only when needed |
| full_name_encrypted | Yes | AES-256-GCM | Never in logs |
| zip_encrypted | Yes | AES-256-GCM | Needed for broker matching |
| dob_encrypted | Yes | AES-256-GCM | Needed for broker fingerprint |
| cyber_score | No | Plaintext | Numeric score 0–100 |
| broker_id | No | Plaintext | Enum ("spokeo", etc.) |
| audit_log.metadata | MUST NOT be PII | Plaintext JSONB | IDs + counts only |
| audit_log.ip_hash | No | SHA-256 hash | Security monitoring |
| broker_reply_raw | Possibly | Text | Contains broker's reply email |

### How PII Flows Through the Removal Pipeline

```
User signs up → email, name, ZIP, DOB encrypted at write time → stored encrypted
         ↓
Discovery stage → DEK retrieved from KMS → PII decrypted in-memory for scraping
         ↓
Scraper uses PII to search broker sites → PII NEVER logged, never in URLs
         ↓
Request generation → PII decrypted for template population → sent over TLS
         ↓
Submission complete → in-memory PII vars garbage collected
         ↓
Audit log written → NO PII in metadata → only {broker_id, method, ref}
         ↓
User deletes account → soft-delete → 30 days → hard-delete + KMS DEK destroy
```

### GDPR / CCPA Deletion Flow

```sql
-- Step 1: Soft delete (immediate, user-visible)
UPDATE users SET deleted_at = NOW() WHERE id = $1;

-- Step 2: Anonymize or cascade-delete related records
-- (Cascade DELETE defined in FK constraints above)

-- Step 3: Hard delete after 30 days (scheduled cron)
DELETE FROM users WHERE deleted_at < NOW() - INTERVAL '30 days';

-- Step 4: Call AWS KMS to schedule DEK deletion
-- aws kms schedule-key-deletion --key-id {user_kms_key_id} --pending-window-in-days 7
-- After deletion: all encrypted columns become permanently indecipherable
```

---

## Claude API Integration

### Authentication (Browser-Side, for Demo)

```javascript
// Headers required for direct browser → Anthropic API calls:
{
  'Content-Type': 'application/json',
  'x-api-key': CLAUDE_API_KEY,                // User-supplied at runtime
  'anthropic-version': '2023-06-01',           // Lock to stable API version
  'anthropic-dangerous-allow-browser': 'true'  // Required for browser CORS
}
```

> **Production note**: In production, Claude API calls should go through your backend to avoid exposing API keys. The `anthropic-dangerous-allow-browser: true` header is a safety marker indicating you understand the key exposure risk. Only use it for demos where users supply their own keys.

### Backend Pattern (Node.js Production)

```javascript
// server/routes/ai.js — Production pattern
import Anthropic from '@anthropic-ai/sdk';

const client = new Anthropic({
  apiKey: process.env.ANTHROPIC_API_KEY  // From AWS Secrets Manager, NEVER hardcoded
});

export async function aiCoach(req, res) {
  // Auth check: verify JWT, extract user_id
  const userId = req.user.id;

  // Rate limit: 20 AI requests / user / day (stored in Redis)
  const rateKey = `ai_rate:${userId}:${new Date().toDateString()}`;
  const count = await redis.incr(rateKey);
  if (count === 1) await redis.expire(rateKey, 86400);
  if (count > 20) return res.status(429).json({ error: 'Daily AI limit reached' });

  // Fetch user's real threat profile from DB (no PII — just threat data)
  const profile = await getThreatProfile(userId);

  const response = await client.messages.create({
    model: 'claude-sonnet-4-20250514',
    max_tokens: 600,
    system: buildSystemPrompt(profile),  // Inject real breach/broker data
    messages: req.body.messages          // Client-sent conversation history
  });

  res.json({ content: response.content[0].text });
}
```

### Email Reply Parsing (Backend Use of Claude)

Stage 5 of the removal pipeline uses Claude to extract structured data from raw broker reply emails:

```javascript
async function parseBrokerReply(rawEmail, removalRef) {
  const response = await client.messages.create({
    model: 'claude-sonnet-4-20250514',
    max_tokens: 200,
    system: `You parse data broker opt-out acknowledgment emails. 
             Respond ONLY with valid JSON. No markdown, no explanation.`,
    messages: [{
      role: 'user',
      content: `Extract from this broker reply email:
        {"caseNumber": "string or null",
         "status": "acknowledged|processing|completed|denied|unclear",
         "etaDate": "YYYY-MM-DD or null",
         "denialReason": "string or null"}
        
        Email: ${rawEmail.substring(0, 2000)}`
    }]
  });

  try {
    return JSON.parse(response.content[0].text);
  } catch {
    return { status: 'unclear', caseNumber: null, etaDate: null };
  }
}
```

---

## Environment Variables (Production Backend)

```bash
# ── Auth ──────────────────────────────────────────
COGNITO_USER_POOL_ID=us-east-1_xxxxx
COGNITO_CLIENT_ID=xxxxxxxxxxxxxxxxxxxxxxxxxx
JWT_PUBLIC_KEY=-----BEGIN PUBLIC KEY-----...

# ── Database ──────────────────────────────────────
DATABASE_URL=postgresql://app_user:${DB_PASSWORD}@rds-host:5432/geosent
DB_PASSWORD=  # From AWS Secrets Manager, not hardcoded

# ── AWS ───────────────────────────────────────────
AWS_REGION=us-east-1
AWS_KMS_CMK_ARN=arn:aws:kms:us-east-1:123456789:key/xxxxxxxx
S3_BUCKET_CERTS=geosent-removal-certs-prod
SES_FROM_DOMAIN=geosent.app

# ── External APIs ─────────────────────────────────
ANTHROPIC_API_KEY=sk-ant-api03-...   # AWS Secrets Manager
HIBP_API_KEY=xxxxxxxx-xxxx-...       # AWS Secrets Manager
PIPL_API_KEY=xxxxxxxxxxxx            # AWS Secrets Manager — server-side only
ONEREP_API_KEY=xxxxxxxxxxxx          # AWS Secrets Manager
TWO_CAPTCHA_KEY=xxxxxxxxxxxx
LOB_API_KEY=test_xxxxxxxxxxxx        # Use live_ in production
BRIGHT_DATA_USERNAME=
BRIGHT_DATA_PASSWORD=
STRIPE_SECRET_KEY=sk_live_...        # AWS Secrets Manager
STRIPE_WEBHOOK_SECRET=whsec_...

# ── Redis ─────────────────────────────────────────
UPSTASH_REDIS_URL=https://xxx.upstash.io
UPSTASH_REDIS_TOKEN=xxxxxxxxxxxx

# ── App ───────────────────────────────────────────
NODE_ENV=production
PORT=3000
LOG_LEVEL=info
CORS_ORIGIN=https://app.geosent.app
```

> **Never commit these to git.** Use `.env.example` with placeholder values and AWS Secrets Manager in production.

---

## Security Checklist (Pre-Launch)

- [ ] `.nojekyll` present in repo root (GitHub Pages only)
- [ ] No API keys committed to git (`git log --all --grep='sk-ant' --oneline`)
- [ ] HIBP key server-side only in production (not in frontend)
- [ ] Pipl key server-side only (never in browser)
- [ ] PostgreSQL RLS policies active and tested
- [ ] All DB queries use parameterized statements (no string interpolation)
- [ ] AWS KMS CMK created; DEK rotation enabled
- [ ] S3 bucket: public access blocked, server-side encryption enabled
- [ ] SES: DKIM + SPF + DMARC configured on `geosent.app`
- [ ] CloudFront + WAF OWASP ruleset enabled
- [ ] Audit log append-only policy enforced
- [ ] GDPR deletion flow tested end-to-end
- [ ] Rate limiting on all AI endpoints (20 req/user/day)
- [ ] Rate limiting on HIBP lookups (avoid burning quota)
- [ ] Content-Security-Policy headers set at CDN layer (see HTML comment)

---

## Contact

**GeoSent Technologies, Inc.**
Strategic investment · Channel partnerships · White-label licensing

📧 founders@geosent.app

---

*Proprietary and confidential. Not for distribution without written consent.*  
*© 2026 GeoSent Technologies, Inc. All rights reserved.*
