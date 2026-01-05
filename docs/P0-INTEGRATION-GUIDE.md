# P0 Critical Improvements - Integration Guide

**Version**: 1.3.0
**Branch**: `feature/production-hardening`
**Status**: ✅ Ready for Merge
**Date**: January 5, 2026

This guide provides step-by-step instructions for integrating the P0 Critical improvements into YokeFlow.

---

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Database Migration](#database-migration)
4. [Integration Steps](#integration-steps)
5. [Testing](#testing)
6. [Deployment Checklist](#deployment-checklist)
7. [Rollback Plan](#rollback-plan)

---

## Overview

Three production-critical improvements have been implemented:

### 1. Database Retry Logic
- **Files**: `core/database_retry.py`, `core/database.py`
- **Impact**: Automatic retry on transient database failures
- **Zero downtime**: Drop-in enhancement, no breaking changes

### 2. Intervention System
- **Files**: `core/session_manager.py`, `core/database.py`, `schema/011_paused_sessions.sql`
- **Impact**: Full pause/resume capability for stuck sessions
- **Requires**: Database schema update (3 new tables)

### 3. Session Checkpointing
- **Files**: `core/checkpoint.py`, `core/database.py`, `schema/012_session_checkpoints.sql`
- **Impact**: Resume sessions from last checkpoint after crashes
- **Requires**: Database schema update (2 new tables)

---

## Prerequisites

### Required
- ✅ PostgreSQL 12+ running
- ✅ Database backup completed
- ✅ Python 3.10+ with asyncpg installed
- ✅ All existing tests passing on main branch

### Recommended
- ✅ Staging environment for testing
- ✅ Database migration tested offline
- ✅ Rollback plan documented

---

## Database Migration

### Step 1: Backup Database

```bash
# Create backup
pg_dump -U agent -d yokeflow > yokeflow_backup_$(date +%Y%m%d_%H%M%S).sql

# Verify backup
psql -U agent -d yokeflow_test < yokeflow_backup_*.sql
```

### Step 2: Apply Schema Updates

The schemas are designed to be safely applied to existing databases.

#### Option A: Using psql (Recommended)

```bash
# Apply intervention system schema
psql -U agent -d yokeflow -f schema/postgresql/011_paused_sessions.sql

# Apply checkpointing schema
psql -U agent -d yokeflow -f schema/postgresql/012_session_checkpoints.sql
```

#### Option B: Using Python Script

```bash
# Run migration script
python scripts/migrate_database.py
```

### Step 3: Verify Schema

```bash
# Check tables were created
psql -U agent -d yokeflow -c "\dt paused_sessions"
psql -U agent -d yokeflow -c "\dt session_checkpoints"

# Check views were created
psql -U agent -d yokeflow -c "\dv v_active_interventions"
psql -U agent -d yokeflow -c "\dv v_resumable_checkpoints"

# Check functions were created
psql -U agent -d yokeflow -c "\df pause_session"
psql -U agent -d yokeflow -c "\df create_checkpoint"
```

Expected output:
```
✓ paused_sessions table exists
✓ intervention_actions table exists
✓ notification_preferences table exists
✓ session_checkpoints table exists
✓ checkpoint_recoveries table exists
✓ 5 views created
✓ 7 functions created
```

---

## Integration Steps

### Phase 1: Code Integration (No Breaking Changes)

#### 1.1 Merge Feature Branch

```bash
# Switch to main branch
git checkout main

# Merge feature branch
git merge feature/production-hardening

# Resolve any conflicts (unlikely)
```

#### 1.2 Install Dependencies

```bash
# No new dependencies required - all use existing packages
pip install -r requirements.txt  # Verify
```

#### 1.3 Run Tests

```bash
# Run all tests to ensure integration
python -m pytest tests/ -v

# Expected: 128+ tests passing (64 existing + 64 new)
```

### Phase 2: Database Retry Logic (Immediate Effect)

**Status**: ✅ Active immediately upon merge

The database retry logic is applied automatically to all database operations through decorators. No code changes required.

**Verify**:
```bash
# Check retry logic is working
python -c "from core.database_retry import get_retry_stats; print(get_retry_stats())"
```

### Phase 3: Intervention System (Optional Activation)

The intervention system is ready to use but requires explicit activation in your code.

#### 3.1 Enable in Orchestrator

Edit `core/orchestrator.py` or `core/agent.py`:

```python
from core.session_manager import PausedSessionManager
from core.intervention import InterventionManager

# In session setup
session_manager = PausedSessionManager()
intervention_mgr = InterventionManager(config)
intervention_mgr.set_session_info(session_id, project_name)

# During agent loop - check for blockers
is_blocked, reason = await intervention_mgr.check_tool_use(tool_name, tool_input)
if is_blocked:
    # Pause session
    paused_session_id = await session_manager.pause_session(
        session_id=session_id,
        project_id=project_id,
        reason=reason,
        pause_type="retry_limit",
        intervention_manager=intervention_mgr,
        current_task=current_task
    )
    # Handle pause (notify user, stop session, etc.)
    break
```

#### 3.2 Test Intervention

```bash
# Test pause/resume functionality
python tests/test_session_manager.py -v

# Test intervention detection
python tests/test_intervention.py -v
```

### Phase 4: Session Checkpointing (Gradual Rollout)

Checkpointing can be enabled incrementally:

#### 4.1 Basic Checkpointing

Add checkpoint creation after each task completion:

```python
from core.checkpoint import CheckpointManager

# In agent loop (after task completion)
checkpoint_mgr = CheckpointManager(session_id, project_id)

checkpoint_id = await checkpoint_mgr.create_checkpoint(
    checkpoint_type="task_completion",
    conversation_history=messages,  # Full conversation
    current_task_id=completed_task_id,
    message_count=len(messages),
    completed_tasks=completed_task_ids,
    metrics_snapshot=current_metrics
)
```

#### 4.2 Recovery on Startup

Add recovery check on session start:

```python
from core.checkpoint import CheckpointRecoveryManager

# On session initialization
recovery_mgr = CheckpointRecoveryManager()

# Check if session has resumable checkpoint
checkpoint = await db.get_resumable_checkpoint(session_id)

if checkpoint:
    # Ask user if they want to resume
    user_choice = prompt_user_resume(checkpoint)

    if user_choice == "resume":
        # Restore state
        state = await recovery_mgr.restore_from_checkpoint(checkpoint['id'])

        # Start recovery tracking
        recovery_id = await recovery_mgr.start_recovery(
            checkpoint['id'],
            recovery_method="manual"
        )

        # Continue with restored state
        messages = state['conversation_history']
        current_task_id = state['current_task_id']
        # ... etc
```

#### 4.3 Test Checkpointing

```bash
# Test checkpoint creation and recovery
python tests/test_checkpoint.py -v
```

---

## Testing

### Unit Tests

```bash
# Run all new tests
python -m pytest tests/test_database_retry.py -v          # 30 tests
python -m pytest tests/test_session_manager.py -v         # 15 tests
python -m pytest tests/test_checkpoint.py -v              # 19 tests

# Expected: 64 tests passing
```

### Integration Tests

```bash
# Test database connection with retry
python -c "
import asyncio
from core.database_connection import get_db

async def test():
    db = await get_db()
    # This will retry automatically on failure
    async with db.acquire() as conn:
        result = await conn.fetchval('SELECT 1')
        print(f'✓ Database connection with retry: {result}')

asyncio.run(test())
"
```

### Manual Testing

1. **Test Database Retry**:
   - Temporarily stop PostgreSQL
   - Start a session
   - Restart PostgreSQL within retry window
   - Session should continue automatically

2. **Test Intervention**:
   - Create a session that triggers retry limit
   - Verify session is paused
   - Check database for paused_sessions record
   - Resume session manually

3. **Test Checkpointing**:
   - Start a session
   - Complete a task (checkpoint created)
   - Force-kill the session
   - Restart and verify checkpoint recovery

---

## Deployment Checklist

### Pre-Deployment
- [ ] All tests passing (128+ tests)
- [ ] Database backup completed
- [ ] Schema migration tested in staging
- [ ] Code review completed
- [ ] Documentation updated

### Deployment
- [ ] Apply database schema (011 + 012)
- [ ] Merge feature branch to main
- [ ] Deploy updated code
- [ ] Verify retry logic active
- [ ] Monitor for errors (first 24 hours)

### Post-Deployment
- [ ] Verify database retry statistics
- [ ] Check intervention system logs
- [ ] Monitor checkpoint creation
- [ ] Validate recovery attempts
- [ ] Update monitoring dashboards

---

## Rollback Plan

### Emergency Rollback (Code Only)

If critical issues arise with the code:

```bash
# Revert to previous version
git revert HEAD~4..HEAD

# Or reset to before merge
git reset --hard <commit-before-merge>

# Deploy reverted code
```

**Impact**: Database tables remain but are unused. Safe to leave in place.

### Database Rollback (If Needed)

**Not recommended** unless absolutely necessary. Tables can remain without harm.

If rollback is required:

```bash
# Drop new tables (loses all intervention/checkpoint data)
psql -U agent -d yokeflow <<EOF
DROP VIEW IF EXISTS v_checkpoint_recovery_history;
DROP VIEW IF EXISTS v_resumable_checkpoints;
DROP VIEW IF EXISTS v_latest_checkpoints;
DROP VIEW IF EXISTS v_intervention_history;
DROP VIEW IF EXISTS v_active_interventions;

DROP TABLE IF EXISTS checkpoint_recoveries;
DROP TABLE IF EXISTS session_checkpoints;
DROP TABLE IF EXISTS intervention_actions;
DROP TABLE IF EXISTS notification_preferences;
DROP TABLE IF EXISTS paused_sessions;

DROP FUNCTION IF EXISTS complete_checkpoint_recovery;
DROP FUNCTION IF EXISTS start_checkpoint_recovery;
DROP FUNCTION IF EXISTS get_latest_resumable_checkpoint;
DROP FUNCTION IF EXISTS invalidate_checkpoints;
DROP FUNCTION IF EXISTS create_checkpoint;
DROP FUNCTION IF EXISTS resume_session;
DROP FUNCTION IF EXISTS pause_session;
EOF

# Restore from backup if needed
psql -U agent -d yokeflow < yokeflow_backup_*.sql
```

---

## Monitoring

### Key Metrics to Monitor

1. **Database Retry Stats**:
   ```python
   from core.database_retry import get_retry_stats
   stats = get_retry_stats()
   # Monitor: total_retries, retry_success_rate, failed_operations
   ```

2. **Intervention Events**:
   ```sql
   SELECT COUNT(*) FROM paused_sessions WHERE resolved = FALSE;
   SELECT pause_type, COUNT(*) FROM paused_sessions GROUP BY pause_type;
   ```

3. **Checkpoint Health**:
   ```sql
   SELECT COUNT(*) FROM session_checkpoints WHERE created_at > NOW() - INTERVAL '24 hours';
   SELECT checkpoint_type, COUNT(*) FROM session_checkpoints GROUP BY checkpoint_type;
   ```

4. **Recovery Success Rate**:
   ```sql
   SELECT
       recovery_status,
       COUNT(*) as count,
       AVG(recovery_duration_seconds) as avg_duration
   FROM v_checkpoint_recovery_history
   GROUP BY recovery_status;
   ```

---

## Support

### Common Issues

**Issue**: "Function pause_session does not exist"
- **Cause**: Schema 011 not applied
- **Fix**: Run `psql -f schema/postgresql/011_paused_sessions.sql`

**Issue**: "Column 'conversation_history' does not exist"
- **Cause**: Schema 012 not applied
- **Fix**: Run `psql -f schema/postgresql/012_session_checkpoints.sql`

**Issue**: Tests failing with import errors
- **Cause**: Code not properly merged
- **Fix**: Ensure all new files are present in `core/` directory

### Getting Help

- Review commit history: `git log feature/production-hardening`
- Check test output: `pytest tests/ -v --tb=short`
- Verify database schema: `psql -c "\dt"` and `psql -c "\df"`
- Review logs: `tail -f generations/*/logs/*.txt`

---

## Success Criteria

✅ **Deployment Successful When**:
- All 128+ tests passing
- Database schemas applied without errors
- No increase in error rates
- Retry logic statistics showing activity
- Sessions completing normally
- Checkpoints being created after tasks

---

## Next Steps After Integration

1. **Monitor Production** (Week 1):
   - Watch retry statistics
   - Check for intervention triggers
   - Verify checkpoint creation

2. **Gradual Feature Enablement** (Week 2-3):
   - Enable intervention system in orchestrator
   - Add checkpoint creation after tasks
   - Implement recovery prompts

3. **Optimization** (Week 4+):
   - Tune retry parameters based on metrics
   - Adjust checkpoint frequency
   - Optimize database queries

4. **Consider P1 Improvements**:
   - Input validation (8-10h)
   - Health check endpoints (6-8h)
   - Structured logging (10-12h)
   - Comprehensive test suite (20-30h)

---

**Integration Guide Version**: 1.0
**Last Updated**: January 5, 2026
**Maintained By**: YokeFlow Development Team
