# Database Updates Required (v1.1.0 → v1.1.1)

⚠️ **Action Required for Existing Installations**

If you're upgrading from v1.1.0, you need to apply database schema updates.

## Quick Update (Recommended)

Run this single command to apply all schema updates:

**Via Docker:**
```bash
docker exec -i yokeflow_postgres psql -U agent -d yokeflow < schema/postgresql/add_metadata_to_prompt_proposals.sql
docker exec -i yokeflow_postgres psql -U agent -d yokeflow < schema/postgresql/cleanup_session_quality_checks.sql
```

**Direct PostgreSQL:**
```bash
psql -U agent -d yokeflow < schema/postgresql/add_metadata_to_prompt_proposals.sql
psql -U agent -d yokeflow < schema/postgresql/cleanup_session_quality_checks.sql
```

## What's Changed?

### 1. Session Quality Checks Cleanup
**File:** `schema/postgresql/cleanup_session_quality_checks.sql`

**Changes:**
- Removed redundant `check_type` column (always 'quick')
- Removed `review_text`, `review_summary`, `prompt_improvements` columns (moved to `session_deep_reviews` table)
- Updated 3 database views to remove `check_type` filter

**Impact if not applied:**
- ❌ Session quality checks won't be saved to database
- ❌ Quality dashboard won't show data

### 2. Prompt Proposals Metadata Column
**File:** `schema/postgresql/add_metadata_to_prompt_proposals.sql`

**Changes:**
- Added `metadata JSONB` column to `prompt_proposals` table

**Impact if not applied:**
- ❌ Prompt improvement analysis will fail
- ✅ All other features work normally

## Verification

After applying updates, verify with:

```bash
# Check that session_quality_checks no longer has check_type
docker exec yokeflow_postgres psql -U agent -d yokeflow -c "\d session_quality_checks"

# Check that prompt_proposals has metadata column
docker exec yokeflow_postgres psql -U agent -d yokeflow -c "\d prompt_proposals" | grep metadata
```

You should see:
- ✅ `session_quality_checks` has 13 columns (no `check_type`, `review_text`, etc.)
- ✅ `prompt_proposals` has `metadata` column

## Fresh Installation?

If you're doing a **fresh installation** (not upgrading), you don't need these migrations.
The main schema file (`schema/postgresql/schema.sql`) already includes all updates.

## Questions?

If you encounter issues, check the migration scripts themselves - they use `IF EXISTS`/`IF NOT EXISTS`
so they're safe to run multiple times and won't fail if changes are already applied.

---

**Note:** These migrations are safe and idempotent. Running them multiple times won't cause errors.
