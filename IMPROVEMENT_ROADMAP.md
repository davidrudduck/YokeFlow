# YokeFlow Improvement Roadmap

**Created:** January 4, 2026
**Based On:** Comprehensive architecture analysis
**Status:** Ready for implementation

---

## Quick Reference

| Priority | Item | Effort | Impact | Status |
|----------|------|--------|--------|--------|
| P0 | Complete Intervention System | 8-12h | Safety | ✅ **COMPLETE** (6h) |
| P0 | Add DB Connection Retries | 4-6h | Reliability | ✅ **COMPLETE** (4h) |
| P0 | Session Resumption | 12-16h | Resilience | ✅ **COMPLETE** (8h) |
| P1 | Test Suite (70% coverage) | 20-30h | Confidence | 🚧 **IN PROGRESS** (64 tests) |
| P1 | Input Validation Framework | 8-10h | Robustness | Not Started |
| P1 | Structured Logging | 10-12h | Observability | ✅ **COMPLETE** (10h) |
| P1 | Health Checks | 6-8h | Operations | Not Started |
| P2 | Error Hierarchy | 8-10h | Consistency | ✅ **COMPLETE** (8h) |
| P2 | Resource Manager | 10-12h | Concurrency | Not Started |
| P2 | Performance Metrics | 8-10h | Insights | Not Started |

**Total Effort:** ~95-105 hours for all improvements
**Completed:** 36 hours (5 items) | **Remaining:** ~59-69 hours (5 items)

---

## P0: Critical Improvements (24-34 hours)

### 1. Complete Intervention System (8-12 hours)

**Current State:**
```python
# core/session_manager.py - STUBBED
async def pause_session(self, session_id: UUID, reason: str):
    return None  # Does nothing

async def get_active_pauses(self) -> List:
    return []  # Always empty

async def resume_session(self, session_id: UUID):
    return None  # Not implemented
```

**Implementation Plan:**

1. Create `core/intervention_database.py`:
```python
from uuid import UUID
from datetime import datetime
from typing import List, Optional

class InterventionDatabase:
    """Database layer for intervention system"""
    
    def __init__(self, db):
        self.db = db
    
    async def pause_session(self, session_id: UUID, reason: str, 
                          details: Optional[dict] = None):
        """Pause a running session and save context"""
        await self.db.execute("""
            INSERT INTO paused_sessions 
            (session_id, reason, context, created_at, updated_at)
            VALUES ($1, $2, $3, NOW(), NOW())
        """, session_id, reason, json.dumps(details or {}))
    
    async def get_active_pauses(self) -> List[dict]:
        """Get all active (unresolved) paused sessions"""
        rows = await self.db.fetch("""
            SELECT * FROM v_active_interventions
            ORDER BY created_at DESC
        """)
        return [dict(row) for row in rows]
    
    async def resume_session(self, session_id: UUID) -> dict:
        """Mark session as resolved and return checkpoint"""
        result = await self.db.fetchrow("""
            UPDATE paused_sessions
            SET resolved = true, resolved_at = NOW()
            WHERE session_id = $1
            RETURNING *
        """, session_id)
        return dict(result) if result else None
    
    async def get_session_checkpoint(self, session_id: UUID) -> dict:
        """Get saved session context for resumption"""
        row = await self.db.fetchrow("""
            SELECT context, last_task_id
            FROM paused_sessions
            WHERE session_id = $1 AND resolved = false
        """, session_id)
        return dict(row) if row else None
```

2. Update `core/session_manager.py`:
```python
class SessionManager:
    def __init__(self, db):
        self.db = db
        self.intervention_db = InterventionDatabase(db)
    
    async def pause_and_wait(self, session_id: UUID, reason: str,
                            context: Optional[dict] = None):
        """Pause session and wait for user intervention"""
        # Save pause state
        await self.intervention_db.pause_session(
            session_id, reason, context
        )
        
        # Wait for resume
        while True:
            checkpoint = await self.intervention_db.get_session_checkpoint(
                session_id
            )
            if not checkpoint:
                # Session was resumed and resolved
                return checkpoint
            
            await asyncio.sleep(1)  # Poll every second
```

3. Apply schema migration:
```bash
psql $DATABASE_URL < schema/postgresql/011_paused_sessions.sql
```

4. Test intervention workflow:
```python
# tests/test_intervention_database.py
@pytest.mark.asyncio
async def test_pause_and_resume_session(db):
    """Test full pause/resume workflow"""
    session_id = uuid4()
    intervention_db = InterventionDatabase(db)
    
    # Pause session
    await intervention_db.pause_session(
        session_id, 
        "Infinite loop detected",
        {"last_task": 42}
    )
    
    # Get active pauses
    pauses = await intervention_db.get_active_pauses()
    assert any(p['session_id'] == str(session_id) for p in pauses)
    
    # Resume session
    await intervention_db.resume_session(session_id)
    
    # Verify resolved
    pauses = await intervention_db.get_active_pauses()
    assert not any(p['session_id'] == str(session_id) for p in pauses)
```

### 2. Add Database Connection Retry Logic (4-6 hours)

**Current State:**
```python
# core/database.py - FAILS IMMEDIATELY
async def connect(self, min_size: int = 10, max_size: int = 20):
    self.pool = await asyncpg.create_pool(...)
    # No retry on failure
```

**Implementation:**

```python
import asyncio
from typing import Optional

class TaskDatabase:
    async def connect(self, min_size: int = 10, max_size: int = 20,
                     max_retries: int = 5, initial_backoff: float = 1.0):
        """
        Create connection pool with exponential backoff retry.
        
        Args:
            min_size: Minimum pool connections
            max_size: Maximum pool connections
            max_retries: Number of retry attempts (5 = ~30 seconds)
            initial_backoff: Initial wait time (1 second)
        """
        backoff = initial_backoff
        last_error = None
        
        for attempt in range(max_retries):
            try:
                self.pool = await asyncpg.create_pool(
                    self.connection_url,
                    min_size=min_size,
                    max_size=max_size,
                    command_timeout=60
                )
                logger.info(f"Connected to PostgreSQL (attempt {attempt + 1})")
                return
                
            except (asyncpg.PostgresError, OSError) as e:
                last_error = e
                if attempt < max_retries - 1:
                    logger.warning(
                        f"Database connection failed (attempt {attempt + 1}/"
                        f"{max_retries}), retrying in {backoff}s: {e}"
                    )
                    await asyncio.sleep(backoff)
                    backoff *= 2  # Exponential backoff
                else:
                    logger.error(
                        f"Database connection failed after {max_retries} "
                        f"attempts: {e}"
                    )
        
        raise ConnectionError(
            f"Could not connect to database after {max_retries} attempts"
        ) from last_error
    
    async def get_or_reconnect(self):
        """Get connection, reconnect if pool closed"""
        if not self.pool or self.pool._holders is None:
            logger.info("Reconnecting to database...")
            await self.connect()
        return self.pool
```

**Test coverage:**

```python
# tests/test_database_retry.py
@pytest.mark.asyncio
async def test_database_retry_on_connection_failure(monkeypatch):
    """Test retry logic on transient failures"""
    attempt_count = 0
    
    async def failing_create_pool(*args, **kwargs):
        nonlocal attempt_count
        attempt_count += 1
        if attempt_count < 3:
            raise ConnectionRefusedError("Database not ready")
        # Success on 3rd attempt
        return AsyncMock()  # Mock pool
    
    monkeypatch.setattr(asyncpg, "create_pool", failing_create_pool)
    
    db = TaskDatabase("postgresql://...")
    await db.connect(max_retries=5, initial_backoff=0.1)
    
    assert attempt_count == 3  # Failed twice, succeeded on third

@pytest.mark.asyncio
async def test_database_fail_after_max_retries():
    """Test failure after max retries exceeded"""
    db = TaskDatabase("postgresql://invalid")
    
    with pytest.raises(ConnectionError):
        await db.connect(max_retries=2, initial_backoff=0.01)
```

### 3. Implement Session Resumption (12-16 hours)

**Current State:**
- No checkpoint saving during execution
- Interruption requires complete restart
- Session context lost on failure

**Implementation:**

1. Create `core/checkpoint.py`:
```python
from dataclasses import dataclass
from datetime import datetime
from typing import Optional, Dict, Any
from uuid import UUID

@dataclass
class SessionCheckpoint:
    """Saved session state for resumption"""
    session_id: UUID
    project_id: UUID
    current_task_id: Optional[int]
    last_completed_task_id: Optional[int]
    session_context: Dict[str, Any]
    created_at: datetime
    
    async def save(self, db):
        """Save checkpoint to database"""
        await db.execute("""
            INSERT INTO session_checkpoints 
            (session_id, project_id, current_task_id, 
             last_completed_task_id, context, created_at)
            VALUES ($1, $2, $3, $4, $5, NOW())
        """, self.session_id, self.project_id, 
            self.current_task_id, self.last_completed_task_id,
            json.dumps(self.session_context))
    
    @staticmethod
    async def load(db, session_id: UUID) -> Optional["SessionCheckpoint"]:
        """Load checkpoint from database"""
        row = await db.fetchrow("""
            SELECT * FROM session_checkpoints
            WHERE session_id = $1
            ORDER BY created_at DESC
            LIMIT 1
        """, session_id)
        
        if not row:
            return None
        
        return SessionCheckpoint(
            session_id=row['session_id'],
            project_id=row['project_id'],
            current_task_id=row['current_task_id'],
            last_completed_task_id=row['last_completed_task_id'],
            session_context=json.loads(row['context']),
            created_at=row['created_at']
        )
```

2. Update `core/agent.py` to save checkpoints:
```python
async def run_agent_session(
    client: ClaudeSDKClient,
    message: str,
    project_dir: Path,
    logger: SessionLogger,
    session_id: UUID,
    db: TaskDatabase,
    verbose: bool = False,
    **kwargs
) -> tuple[str, str]:
    """Run session with checkpoint support"""
    
    # Load checkpoint if exists
    checkpoint = await SessionCheckpoint.load(db, session_id)
    if checkpoint:
        logger.info(f"Resuming from checkpoint at task {checkpoint.current_task_id}")
        start_task = checkpoint.last_completed_task_id + 1
    else:
        start_task = None
    
    try:
        # ... session execution ...
        
        # Save checkpoint after each task
        checkpoint = SessionCheckpoint(
            session_id=session_id,
            project_id=project_id,
            current_task_id=current_task,
            last_completed_task_id=completed_task,
            session_context={"model": client.model}
        )
        await checkpoint.save(db)
        
    except KeyboardInterrupt:
        # Save state before exit
        await checkpoint.save(db)
        raise
```

3. Add checkpoint schema:
```sql
-- schema/postgresql/012_session_checkpoints.sql
CREATE TABLE session_checkpoints (
    id SERIAL PRIMARY KEY,
    session_id UUID NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    project_id UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    current_task_id INTEGER,
    last_completed_task_id INTEGER,
    context JSONB,
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    
    CONSTRAINT valid_task_progress CHECK (
        last_completed_task_id IS NULL 
        OR current_task_id IS NULL 
        OR current_task_id > last_completed_task_id
    )
);

CREATE INDEX idx_session_checkpoints_session_id 
    ON session_checkpoints(session_id);
CREATE INDEX idx_session_checkpoints_created_at 
    ON session_checkpoints(created_at DESC);
```

---

## P1: High Priority Improvements (44-50 hours)

### 1. Build Comprehensive Test Suite (20-30 hours)

Target: 70%+ code coverage

**Create `tests/conftest.py`:**
```python
import pytest
import pytest_asyncio
import tempfile
from pathlib import Path
from uuid import uuid4

@pytest_asyncio.fixture
async def db():
    """Database fixture with cleanup"""
    from core.database import TaskDatabase
    
    db = TaskDatabase("postgresql://test:test@localhost/yokeflow_test")
    await db.connect()
    
    yield db
    
    await db.disconnect()

@pytest_asyncio.fixture
async def project(db):
    """Create test project"""
    project_id = uuid4()
    await db.execute("""
        INSERT INTO projects (id, name, created_at)
        VALUES ($1, $2, NOW())
    """, project_id, f"test-project-{project_id}")
    
    yield project_id
    
    await db.execute("DELETE FROM projects WHERE id = $1", project_id)

@pytest_asyncio.fixture
async def api_client(db):
    """FastAPI test client"""
    from fastapi.testclient import TestClient
    from api.main import app
    
    async with AsyncClient(app=app, base_url="http://test") as client:
        yield client

@pytest.fixture
def temp_project_dir():
    """Temporary project directory"""
    with tempfile.TemporaryDirectory() as tmpdir:
        yield Path(tmpdir)
```

**Create `tests/test_api_integration.py`:**
```python
@pytest.mark.asyncio
async def test_create_project_endpoint(api_client):
    """Test POST /projects"""
    response = await api_client.post("/projects", json={
        "name": "test-api-project",
        "spec_content": "# Test Spec\n\nA test specification."
    })
    assert response.status_code == 201
    project = response.json()
    assert project["name"] == "test-api-project"

@pytest.mark.asyncio
async def test_list_projects_endpoint(api_client):
    """Test GET /projects"""
    response = await api_client.get("/projects")
    assert response.status_code == 200
    projects = response.json()
    assert isinstance(projects, list)

@pytest.mark.asyncio
async def test_invalid_project_name(api_client):
    """Test validation of project name"""
    response = await api_client.post("/projects", json={
        "name": "",  # Invalid: empty
        "spec_content": "# Spec"
    })
    assert response.status_code == 422  # Validation error
```

**Create `tests/test_database_abstraction.py`:**
```python
@pytest.mark.asyncio
async def test_connection_pool_cleanup(db):
    """Test connection pool properly cleans up"""
    # Get multiple connections
    for _ in range(5):
        async with db.acquire() as conn:
            await conn.fetchval("SELECT 1")
    
    # Pool should be healthy
    assert db.pool is not None

@pytest.mark.asyncio
async def test_transaction_rollback(db):
    """Test transaction rollback on error"""
    try:
        async with db.transaction() as conn:
            await conn.execute("""
                INSERT INTO projects (id, name, created_at)
                VALUES ($1, $2, NOW())
            """, uuid4(), "test")
            raise ValueError("Simulate error")
    except ValueError:
        pass
    
    # Insert should be rolled back
    count = await db.fetchval("SELECT COUNT(*) FROM projects WHERE name = 'test'")
    assert count == 0
```

### 2. Add Input Validation Framework (8-10 hours)

**Create `core/validation.py`:**
```python
from pydantic import BaseModel, Field, validator
from typing import Optional

class ProjectCreateValidator(BaseModel):
    """Validated project creation request"""
    name: str = Field(
        ...,
        min_length=1,
        max_length=255,
        regex="^[a-zA-Z0-9_-]+$"
    )
    spec_content: Optional[str] = Field(
        None,
        min_length=100,
        max_length=1_000_000
    )
    force: bool = Field(False)
    
    @validator('name')
    def name_not_reserved(cls, v):
        reserved = ['api', 'static', 'admin']
        if v.lower() in reserved:
            raise ValueError(f"'{v}' is reserved")
        return v
    
    @validator('spec_content')
    def spec_has_sections(cls, v):
        if v and not any(
            section in v.lower() 
            for section in ['epic', 'task', 'requirement']
        ):
            raise ValueError("Spec must contain epics/tasks/requirements")
        return v

# Update api/main.py
from core.validation import ProjectCreateValidator

@app.post("/projects")
async def create_project(request: ProjectCreateValidator):
    # request is now fully validated
    ...
```

### 3. Implement Structured Logging (10-12 hours)

**Create `core/structured_logging.py`:**
```python
import json
import logging
from typing import Dict, Any

class StructuredLogFormatter(logging.Formatter):
    """Format logs as JSON for ELK/Datadog integration"""
    
    def format(self, record: logging.LogRecord) -> str:
        log_data = {
            "timestamp": self.formatTime(record),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }
        
        # Add custom fields
        if hasattr(record, 'session_id'):
            log_data['session_id'] = record.session_id
        if hasattr(record, 'project_id'):
            log_data['project_id'] = record.project_id
        if hasattr(record, 'correlation_id'):
            log_data['correlation_id'] = record.correlation_id
        
        if record.exc_info:
            log_data['exception'] = self.formatException(record.exc_info)
        
        return json.dumps(log_data)

def setup_structured_logging():
    """Configure structured logging for production"""
    handler = logging.StreamHandler()
    handler.setFormatter(StructuredLogFormatter())
    
    logger = logging.getLogger()
    logger.addHandler(handler)
    logger.setLevel(logging.INFO)
    
    return logger

# Usage
logger = setup_structured_logging()
logger.info("Session started", extra={
    "session_id": session_id,
    "project_id": project_id,
    "model": "claude-sonnet-4.5"
})
```

### 4. Create Health Check System (6-8 hours)

**Create `core/health.py`:**
```python
from dataclasses import dataclass
from enum import Enum
from typing import List, Dict, Any
import asyncio

class HealthStatus(str, Enum):
    HEALTHY = "healthy"
    DEGRADED = "degraded"
    UNHEALTHY = "unhealthy"

@dataclass
class HealthCheck:
    name: str
    status: HealthStatus
    message: str
    latency_ms: float

class HealthChecker:
    def __init__(self, db, docker_client):
        self.db = db
        self.docker = docker_client
    
    async def check_database(self) -> HealthCheck:
        """Check PostgreSQL connectivity"""
        try:
            async with self.db.acquire() as conn:
                await conn.fetchval("SELECT 1")
            return HealthCheck(
                name="database",
                status=HealthStatus.HEALTHY,
                message="PostgreSQL responding",
                latency_ms=0
            )
        except Exception as e:
            return HealthCheck(
                name="database",
                status=HealthStatus.UNHEALTHY,
                message=str(e),
                latency_ms=0
            )
    
    async def check_docker(self) -> HealthCheck:
        """Check Docker daemon"""
        try:
            await self.docker.containers.list()
            return HealthCheck(
                name="docker",
                status=HealthStatus.HEALTHY,
                message="Docker daemon responding",
                latency_ms=0
            )
        except Exception as e:
            return HealthCheck(
                name="docker",
                status=HealthStatus.UNHEALTHY,
                message=str(e),
                latency_ms=0
            )
    
    async def check_claude_api(self) -> HealthCheck:
        """Check Claude API token validity"""
        # Implementation with token validation
        pass
    
    async def get_readiness(self) -> bool:
        """All systems ready for new session?"""
        checks = await asyncio.gather(
            self.check_database(),
            self.check_docker(),
            self.check_claude_api()
        )
        return all(c.status == HealthStatus.HEALTHY for c in checks)

# API endpoints
from api.main import app

@app.get("/health")
async def health(checker: HealthChecker = Depends()):
    checks = await asyncio.gather(
        checker.check_database(),
        checker.check_docker(),
        checker.check_claude_api()
    )
    return {
        "status": "healthy",
        "timestamp": datetime.utcnow().isoformat(),
        "checks": [
            {
                "name": c.name,
                "status": c.status,
                "message": c.message
            }
            for c in checks
        ]
    }

@app.get("/ready")
async def ready(checker: HealthChecker = Depends()):
    ready = await checker.get_readiness()
    return {"ready": ready}, (200 if ready else 503)
```

---

## P2: Medium Priority Improvements (26-32 hours)

### 1. Error Handling Framework (8-10 hours)

**Create `core/errors.py`:**
```python
from enum import Enum

class ErrorCategory(str, Enum):
    DATABASE = "database"
    NETWORK = "network"
    SANDBOX = "sandbox"
    VALIDATION = "validation"
    TOOL_EXECUTION = "tool_execution"

class YokeFlowError(Exception):
    """Base exception for YokeFlow"""
    category: ErrorCategory
    recoverable: bool = False
    error_code: str = "UNKNOWN"
    
    def __init__(self, message: str, recoverable: bool = False):
        super().__init__(message)
        self.recoverable = recoverable

class DatabaseError(YokeFlowError):
    category = ErrorCategory.DATABASE
    error_code = "DB_ERROR"

class ConnectionError(DatabaseError):
    error_code = "DB_CONNECTION"

class ToolExecutionError(YokeFlowError):
    category = ErrorCategory.TOOL_EXECUTION
    
    def __init__(self, tool_name: str, message: str, recoverable: bool = True):
        super().__init__(f"{tool_name}: {message}", recoverable)
        self.tool_name = tool_name

# Usage in core/agent.py
try:
    result = await tool.execute()
except ToolExecutionError as e:
    if e.recoverable:
        # Retry with backoff
        await retry_with_exponential_backoff(tool, max_retries=3)
    else:
        # Escalate to intervention system
        await orchestrator.intervention_manager.trigger(
            session_id, 
            f"Tool execution failed: {e}"
        )
```

### 2. Resource Management System (10-12 hours)

**Create `core/resource_manager.py`:**
```python
from typing import Dict, Set
from uuid import UUID

class ResourceAllocation:
    def __init__(self, port: int, memory_limit: str, disk_limit: str):
        self.port = port
        self.memory_limit = memory_limit
        self.disk_limit = disk_limit

class ResourceManager:
    def __init__(self, port_start: int = 3000, port_end: int = 4000):
        self.port_start = port_start
        self.port_end = port_end
        self.allocated_ports: Set[int] = set()
        self.active_sessions: Dict[UUID, ResourceAllocation] = {}
    
    async def allocate_resources(self, session_id: UUID) -> ResourceAllocation:
        """Allocate resources for a session"""
        # Find available port
        for port in range(self.port_start, self.port_end):
            if port not in self.allocated_ports:
                self.allocated_ports.add(port)
                
                allocation = ResourceAllocation(
                    port=port,
                    memory_limit="2GB",
                    disk_limit="50GB"
                )
                self.active_sessions[session_id] = allocation
                return allocation
        
        raise RuntimeError("No available ports for new session")
    
    async def release_resources(self, session_id: UUID):
        """Release session resources"""
        if session_id in self.active_sessions:
            allocation = self.active_sessions.pop(session_id)
            self.allocated_ports.discard(allocation.port)
```

### 3. Performance Monitoring (8-10 hours)

**Create `core/performance.py`:**
```python
from prometheus_client import Counter, Histogram
import time

# Define metrics
tool_execution_time = Histogram(
    'tool_execution_seconds',
    'Time spent executing tools',
    ['tool_name']
)

database_query_time = Histogram(
    'database_query_seconds',
    'Time spent on database queries',
    ['query_type']
)

session_errors = Counter(
    'session_errors_total',
    'Total session errors',
    ['error_type']
)

# Usage in agent execution
@contextmanager
def measure_tool_execution(tool_name: str):
    start = time.time()
    try:
        yield
    finally:
        duration = time.time() - start
        tool_execution_time.labels(tool_name=tool_name).observe(duration)
```

---

## Implementation Timeline

**Week 1-2: P0 Critical Fixes**
- Day 1-3: Intervention system completion
- Day 4-5: Database connection retries
- Day 6-7: Session resumption logic

**Week 3-4: P1 High Priority**
- Day 8-12: Test suite (70% coverage)
- Day 13-14: Input validation
- Day 15-16: Structured logging
- Day 17: Health checks

**Week 5-6: P2 Medium Priority**
- Day 18-19: Error handling framework
- Day 20-21: Resource manager
- Day 22-23: Performance monitoring

---

## Testing Strategy

1. **Unit Tests** (Individual component tests)
   - Error handling
   - Validation logic
   - Health checks

2. **Integration Tests** (Component interaction)
   - API endpoints
   - Database operations
   - Session lifecycle

3. **System Tests** (End-to-end)
   - Full project creation → completion
   - Multi-session scenarios
   - Error recovery

4. **Performance Tests**
   - Concurrent sessions
   - Connection pool stress
   - Large project handling

---

## Success Criteria

- P0 items: 100% complete and tested
- Test coverage: 70%+ of core code
- All API endpoints validated
- Health checks passing
- Error handling consistent
- Input validation on all endpoints
- Structured logging enabled
- No silent failures in critical paths

---

## Risk Mitigation

| Risk | Mitigation |
|------|-----------|
| Regression in existing functionality | Comprehensive test suite |
| Data loss during checkpoint save | Transaction-based writes |
| Resource exhaustion | Resource manager with limits |
| Database connection issues | Retry logic with exponential backoff |
| Silent failures | Structured exception handling |

---

## Dependencies

All improvements use existing dependencies:
- asyncpg (already used)
- pydantic (already used)
- prometheus_client (new, optional)
- pytest-asyncio (already used)

No new major dependencies required.

