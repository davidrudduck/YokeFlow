-- Migration: Remove unused fields from session_quality_checks
--
-- Background: Migration 003 created session_deep_reviews table to separate
-- deep reviews from quick checks, but the old deep review fields were never
-- removed from session_quality_checks.
--
-- This table now ONLY stores quick checks (Phase 1 Review System), so we remove:
-- - check_type (redundant - always 'quick')
-- - review_text (belongs in session_deep_reviews)
-- - review_summary (belongs in session_deep_reviews)
-- - prompt_improvements (belongs in session_deep_reviews)

-- Step 1: Drop dependent views
DROP VIEW IF EXISTS v_project_quality CASCADE;
DROP VIEW IF EXISTS v_recent_quality_issues CASCADE;
DROP VIEW IF EXISTS v_browser_verification_compliance CASCADE;

-- Step 2: Drop the unused columns
ALTER TABLE session_quality_checks
  DROP COLUMN IF EXISTS check_type,
  DROP COLUMN IF EXISTS review_text,
  DROP COLUMN IF EXISTS review_summary,
  DROP COLUMN IF EXISTS prompt_improvements;

-- Step 3: Recreate views without check_type filter
CREATE OR REPLACE VIEW v_project_quality AS
SELECT
    s.project_id,
    p.name as project_name,
    COUNT(DISTINCT s.id) as total_sessions,
    COUNT(DISTINCT q.id) as checked_sessions,
    ROUND(AVG(q.overall_rating), 1) as avg_quality_rating,
    SUM(CASE WHEN q.playwright_count = 0 THEN 1 ELSE 0 END) as sessions_without_browser_verification,
    ROUND(AVG(q.error_rate) * 100, 1) as avg_error_rate_percent,
    ROUND(AVG(q.playwright_count), 1) as avg_playwright_calls_per_session
FROM sessions s
LEFT JOIN session_quality_checks q ON s.id = q.session_id
LEFT JOIN projects p ON s.project_id = p.id
WHERE s.type = 'coding'
GROUP BY s.project_id, p.name;

CREATE OR REPLACE VIEW v_recent_quality_issues AS
SELECT
    q.id as check_id,
    s.id as session_id,
    s.session_number,
    s.type as session_type,
    s.project_id,
    p.name as project_name,
    q.overall_rating,
    q.playwright_count,
    q.error_rate,
    q.critical_issues,
    q.warnings,
    q.created_at
FROM session_quality_checks q
JOIN sessions s ON q.session_id = s.id
JOIN projects p ON s.project_id = p.id
WHERE
    s.type != 'initializer'
    AND (
        jsonb_array_length(q.critical_issues) > 0
        OR q.overall_rating < 6
    )
ORDER BY q.created_at DESC;

CREATE OR REPLACE VIEW v_browser_verification_compliance AS
SELECT
    s.project_id,
    p.name as project_name,
    COUNT(*) as total_sessions,
    SUM(CASE WHEN q.playwright_count > 0 THEN 1 ELSE 0 END) as sessions_with_verification,
    SUM(CASE WHEN q.playwright_count >= 50 THEN 1 ELSE 0 END) as sessions_excellent_verification,
    SUM(CASE WHEN q.playwright_count BETWEEN 10 AND 49 THEN 1 ELSE 0 END) as sessions_good_verification,
    SUM(CASE WHEN q.playwright_count BETWEEN 1 AND 9 THEN 1 ELSE 0 END) as sessions_minimal_verification,
    SUM(CASE WHEN q.playwright_count = 0 THEN 1 ELSE 0 END) as sessions_no_verification,
    ROUND(100.0 * SUM(CASE WHEN q.playwright_count > 0 THEN 1 ELSE 0 END) / COUNT(*), 1) as verification_rate_percent
FROM sessions s
JOIN projects p ON s.project_id = p.id
LEFT JOIN session_quality_checks q ON s.id = q.session_id
WHERE s.type = 'coding'
GROUP BY s.project_id, p.name;

-- Step 4: Update table comment
COMMENT ON TABLE session_quality_checks IS 'Quick quality check results for coding sessions (Phase 1 Review System). Zero-cost metrics analysis from session logs. Runs after every coding session. For deep reviews (Phase 2), see session_deep_reviews table.';
