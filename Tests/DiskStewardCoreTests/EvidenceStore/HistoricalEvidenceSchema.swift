// Frozen DDL from released source, deliberately independent of today's migrator.
// v5: b94bf56 Sources/DiskStewardCore/EvidenceStore/EvidenceStore.swift:2490-2810.
// v6 additions: 8918e30, same path:3397-3432 (nullable columns before backfill).
// Do not regenerate from current schema or merely relabel PRAGMA user_version.
enum HistoricalEvidenceSchema {
    static let v5 = """
    CREATE TABLE snapshots (
        snapshot_id TEXT PRIMARY KEY NOT NULL,
        observed_at REAL NOT NULL,
        payload BLOB NOT NULL
    );
    CREATE INDEX snapshots_observed_at ON snapshots(observed_at);
    
    CREATE TABLE events (
        event_id TEXT PRIMARY KEY NOT NULL,
        observed_at REAL NOT NULL,
        operation TEXT NOT NULL,
        path TEXT NOT NULL,
        logical_delta INTEGER NOT NULL,
        allocated_delta INTEGER NOT NULL,
        consumer_category TEXT NOT NULL,
        confidence TEXT NOT NULL,
        is_anomaly INTEGER NOT NULL CHECK(is_anomaly IN (0, 1)),
        is_reviewed INTEGER NOT NULL CHECK(is_reviewed IN (0, 1))
    );
    CREATE INDEX events_observed_at ON events(observed_at);
    CREATE INDEX events_path_time ON events(path, observed_at);
    
    CREATE TABLE hourly_summaries (
        bucket_start REAL NOT NULL,
        path TEXT NOT NULL,
        operation TEXT NOT NULL,
        event_count INTEGER NOT NULL,
        logical_delta INTEGER NOT NULL,
        allocated_delta INTEGER NOT NULL,
        PRIMARY KEY(bucket_start, path, operation)
    );
    
    CREATE TABLE daily_summaries (
        bucket_start REAL NOT NULL,
        path TEXT NOT NULL,
        operation TEXT NOT NULL,
        event_count INTEGER NOT NULL,
        logical_delta INTEGER NOT NULL,
        allocated_delta INTEGER NOT NULL,
        PRIMARY KEY(bucket_start, path, operation)
    );
    
    PRAGMA user_version=1;
    
    CREATE TABLE scope_versions (
        scope_version_id TEXT PRIMARY KEY NOT NULL,
        effective_at REAL NOT NULL,
        roots_json TEXT NOT NULL,
        exclusions_json TEXT NOT NULL,
        maximum_entries INTEGER NOT NULL,
        maximum_depth INTEGER NOT NULL
    );
    
    CREATE TABLE observation_runs (
        observation_id TEXT PRIMARY KEY NOT NULL,
        scope_version_id TEXT NOT NULL REFERENCES scope_versions(scope_version_id),
        trigger TEXT NOT NULL,
        started_at REAL NOT NULL,
        completed_at REAL NOT NULL,
        coverage TEXT NOT NULL,
        event_gap INTEGER NOT NULL CHECK(event_gap IN (0, 1))
    );
    CREATE INDEX observation_runs_completed_at ON observation_runs(completed_at);
    
    CREATE TABLE observation_roots (
        observation_id TEXT NOT NULL REFERENCES observation_runs(observation_id) ON DELETE CASCADE,
        root_path TEXT NOT NULL,
        coverage TEXT NOT NULL,
        limitations_json TEXT NOT NULL,
        PRIMARY KEY(observation_id, root_path)
    );
    
    CREATE TABLE file_objects (
        object_id TEXT PRIMARY KEY NOT NULL,
        identity_method TEXT NOT NULL,
        first_observed_at REAL NOT NULL,
        last_observed_at REAL NOT NULL,
        lifecycle_state TEXT NOT NULL
    );
    
    CREATE TABLE path_bindings (
        binding_id TEXT PRIMARY KEY NOT NULL,
        object_id TEXT NOT NULL REFERENCES file_objects(object_id),
        path TEXT NOT NULL,
        valid_from REAL NOT NULL,
        valid_through REAL,
        opening_reason TEXT NOT NULL,
        closing_reason TEXT,
        confidence TEXT NOT NULL
    );
    CREATE INDEX path_bindings_path_time ON path_bindings(path, valid_from, valid_through);
    
    CREATE TABLE file_state_observations (
        observation_id TEXT NOT NULL REFERENCES observation_runs(observation_id) ON DELETE CASCADE,
        object_id TEXT NOT NULL REFERENCES file_objects(object_id),
        path TEXT NOT NULL,
        root_path TEXT NOT NULL,
        logical_bytes INTEGER NOT NULL,
        allocated_bytes INTEGER NOT NULL,
        modified_at REAL,
        existence TEXT NOT NULL,
        confidence TEXT NOT NULL,
        PRIMARY KEY(observation_id, object_id)
    );
    
    CREATE TABLE current_file_state (
        object_id TEXT PRIMARY KEY NOT NULL REFERENCES file_objects(object_id),
        identity_method TEXT NOT NULL,
        path TEXT NOT NULL UNIQUE,
        root_path TEXT NOT NULL,
        scope_version_id TEXT NOT NULL REFERENCES scope_versions(scope_version_id),
        logical_bytes INTEGER NOT NULL,
        allocated_bytes INTEGER NOT NULL,
        modified_at REAL,
        presence TEXT NOT NULL,
        state_as_of_observation_id TEXT NOT NULL REFERENCES observation_runs(observation_id),
        observed_at REAL NOT NULL,
        actionable INTEGER NOT NULL CHECK(actionable IN (0, 1))
    );
    CREATE INDEX current_file_state_presence_bytes ON current_file_state(presence, actionable, allocated_bytes DESC);
    
    CREATE TABLE change_events (
        event_id TEXT PRIMARY KEY NOT NULL REFERENCES events(event_id) ON DELETE CASCADE,
        operation TEXT NOT NULL,
        object_id TEXT NOT NULL REFERENCES file_objects(object_id),
        before_observation_id TEXT,
        after_observation_id TEXT NOT NULL REFERENCES observation_runs(observation_id),
        path_before TEXT,
        path_after TEXT,
        logical_delta INTEGER NOT NULL,
        allocated_delta INTEGER NOT NULL,
        detected_at REAL NOT NULL,
        occurred_start REAL NOT NULL,
        occurred_end REAL NOT NULL,
        coverage TEXT NOT NULL
    );
    CREATE INDEX change_events_object_time ON change_events(object_id, detected_at);
    
    CREATE TABLE coverage_gaps (
        gap_id TEXT PRIMARY KEY NOT NULL,
        observation_id TEXT NOT NULL REFERENCES observation_runs(observation_id),
        root_path TEXT NOT NULL,
        reason TEXT NOT NULL,
        started_at REAL NOT NULL,
        ended_at REAL,
        state TEXT NOT NULL
    );
    CREATE INDEX coverage_gaps_time ON coverage_gaps(started_at, ended_at);
    
    PRAGMA user_version=2;
    
    CREATE TABLE fsevent_hints (
        hint_id TEXT PRIMARY KEY NOT NULL,
        observation_id TEXT NOT NULL REFERENCES observation_runs(observation_id) ON DELETE CASCADE,
        event_id INTEGER NOT NULL,
        observed_at REAL NOT NULL,
        path TEXT NOT NULL,
        kind TEXT NOT NULL,
        raw_flags INTEGER NOT NULL,
        requires_rescan INTEGER NOT NULL CHECK(requires_rescan IN (0, 1)),
        signals_json BLOB NOT NULL,
        limitations_json BLOB NOT NULL
    );
    CREATE INDEX fsevent_hints_observation_event ON fsevent_hints(observation_id, event_id);
    
    CREATE TABLE endpoint_observations (
        endpoint_id TEXT PRIMARY KEY NOT NULL,
        observation_id TEXT REFERENCES observation_runs(observation_id) ON DELETE SET NULL,
        evidence_event_id TEXT REFERENCES events(event_id) ON DELETE SET NULL,
        observed_at REAL NOT NULL,
        payload BLOB NOT NULL
    );
    CREATE INDEX endpoint_observations_event ON endpoint_observations(evidence_event_id, observed_at);
    
    CREATE TABLE provenance_claims (
        claim_id TEXT PRIMARY KEY NOT NULL,
        event_id TEXT NOT NULL REFERENCES events(event_id) ON DELETE CASCADE,
        method TEXT NOT NULL,
        confidence TEXT NOT NULL,
        detected_at REAL NOT NULL,
        occurred_start REAL NOT NULL,
        occurred_end REAL NOT NULL,
        session_registration_id TEXT,
        supersedes_claim_id TEXT REFERENCES provenance_claims(claim_id),
        superseded_by_claim_id TEXT REFERENCES provenance_claims(claim_id),
        payload BLOB NOT NULL
    );
    CREATE INDEX provenance_claims_event_time ON provenance_claims(event_id, detected_at);
    CREATE INDEX provenance_claims_session ON provenance_claims(session_registration_id, occurred_start, occurred_end);
    
    CREATE TABLE agent_sessions (
        registration_id TEXT PRIMARY KEY NOT NULL,
        session_id TEXT NOT NULL,
        client TEXT NOT NULL,
        registered_at REAL NOT NULL,
        heartbeat_at REAL NOT NULL,
        expires_at REAL NOT NULL,
        ended_at REAL,
        lifecycle TEXT NOT NULL,
        task_context TEXT,
        payload BLOB NOT NULL
    );
    CREATE INDEX agent_sessions_session_time ON agent_sessions(session_id, registered_at, expires_at);
    CREATE INDEX agent_sessions_lifecycle_expiry ON agent_sessions(lifecycle, expires_at);
    
    PRAGMA user_version=3;
    
    CREATE TABLE retention_runs (
        run_id TEXT PRIMARY KEY NOT NULL,
        trigger TEXT NOT NULL,
        policy BLOB NOT NULL,
        started_at REAL NOT NULL,
        completed_at REAL,
        storage_bytes_before INTEGER NOT NULL,
        storage_bytes_after INTEGER,
        aggregated_raw_events INTEGER NOT NULL DEFAULT 0,
        aggregated_hourly_summaries INTEGER NOT NULL DEFAULT 0,
        deleted_daily_summaries INTEGER NOT NULL DEFAULT 0,
        deleted_snapshots INTEGER NOT NULL DEFAULT 0,
        deleted_historical_rows INTEGER NOT NULL DEFAULT 0,
        forced_evictions INTEGER NOT NULL DEFAULT 0,
        result TEXT NOT NULL,
        limitations BLOB NOT NULL
    );
    CREATE INDEX retention_runs_started_at ON retention_runs(started_at);
    
    CREATE TABLE retention_coverage_gaps (
        gap_id TEXT PRIMARY KEY NOT NULL,
        retention_run_id TEXT NOT NULL REFERENCES retention_runs(run_id) ON DELETE CASCADE,
        reason TEXT NOT NULL,
        affected_precision TEXT NOT NULL,
        started_at REAL NOT NULL,
        rows_removed INTEGER NOT NULL
    );
    CREATE INDEX retention_coverage_gaps_started_at ON retention_coverage_gaps(started_at);
    
    CREATE TABLE export_records (
        export_id TEXT PRIMARY KEY NOT NULL,
        kind TEXT NOT NULL,
        requested_from REAL NOT NULL,
        requested_through REAL NOT NULL,
        actual_from REAL,
        actual_through REAL,
        precision TEXT NOT NULL,
        path_detail TEXT NOT NULL,
        path TEXT,
        bytes INTEGER NOT NULL,
        manifest_sha256 TEXT,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        status TEXT NOT NULL,
        failure TEXT
    );
    CREATE INDEX export_records_updated_at ON export_records(updated_at);
    
    PRAGMA user_version=4;
    
    CREATE TABLE scan_generations (
        generation_id TEXT PRIMARY KEY NOT NULL,
        scope_version_id TEXT NOT NULL REFERENCES scope_versions(scope_version_id),
        status TEXT NOT NULL,
        started_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        completed_at REAL,
        processed_entry_count INTEGER NOT NULL,
        staged_file_count INTEGER NOT NULL,
        progress BLOB NOT NULL
    );
    CREATE INDEX scan_generations_status_updated ON scan_generations(status, updated_at);
    
    CREATE TABLE scan_generation_entries (
        generation_id TEXT NOT NULL REFERENCES scan_generations(generation_id) ON DELETE CASCADE,
        path TEXT NOT NULL,
        payload BLOB NOT NULL,
        PRIMARY KEY(generation_id, path)
    );
    
    PRAGMA user_version=5;
    """

    static let v6Additions = """
    ALTER TABLE scan_generation_entries ADD COLUMN object_id TEXT;
    ALTER TABLE scan_generation_entries ADD COLUMN identity_method TEXT;
    ALTER TABLE scan_generation_entries ADD COLUMN root_path TEXT;
    ALTER TABLE scan_generation_entries ADD COLUMN logical_bytes INTEGER;
    ALTER TABLE scan_generation_entries ADD COLUMN allocated_bytes INTEGER;
    ALTER TABLE scan_generation_entries ADD COLUMN modified_at REAL;
    ALTER TABLE scan_generation_entries ADD COLUMN link_count INTEGER;
    CREATE INDEX scan_generation_entries_object_path ON scan_generation_entries(generation_id, object_id, path);
    CREATE TABLE IF NOT EXISTS reconciliation_invalidations (
        invalidation_id TEXT PRIMARY KEY NOT NULL,
        root_path TEXT NOT NULL,
        reason TEXT NOT NULL,
        observed_at REAL NOT NULL,
        resolved_at REAL,
        state TEXT NOT NULL CHECK(state IN ('open', 'resolved'))
    );
    CREATE INDEX reconciliation_invalidations_state_time ON reconciliation_invalidations(state, observed_at);
    PRAGMA user_version=6;
    """
}
