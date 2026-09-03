CREATE TEMP TABLE expected_delta_event_t AS
SELECT id,
       host AS host_id,
       type AS event_type,
       subject AS aggregate_id,
       data,
       COALESCE(
         NULLIF(aggregateversion, '')::BIGINT,
         (data ->> 'newAggregateVersion')::BIGINT,
         (data ->> 'aggregateVersion')::BIGINT
       ) AS aggregate_version
  FROM jsonb_to_recordset(:'expected_json'::jsonb)
       AS expected(id UUID, host UUID, type TEXT, subject TEXT, aggregateversion TEXT, data JSONB);

DO $verify$
DECLARE
  missing_events TEXT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM expected_delta_event_t) OR EXISTS (
    SELECT 1
      FROM expected_delta_event_t
     WHERE id IS NULL OR host_id IS NULL
        OR event_type IS NULL OR btrim(event_type) = ''
        OR aggregate_id IS NULL OR btrim(aggregate_id) = ''
        OR data IS NULL OR aggregate_version IS NULL
  ) THEN
    RAISE EXCEPTION 'event delta must be a non-empty array with id, host, type, subject, data, and aggregate version for every event';
  END IF;

  SELECT string_agg(
           expected.id || ' aggregate=' || expected.aggregate_id ||
           ' expectedVersion=' || expected.aggregate_version,
           E'\n'
           ORDER BY expected.id
         )
    INTO missing_events
    FROM expected_delta_event_t expected
    LEFT JOIN event_store_t exact_event ON exact_event.id = expected.id
   WHERE exact_event.id IS NULL
     AND NOT EXISTS (
       SELECT 1
         FROM event_store_t equivalent
        WHERE (
                equivalent.host_id = expected.host_id
                OR (
                  expected.event_type = 'HostCreatedEvent'
                  AND equivalent.event_type = expected.event_type
                  AND equivalent.payload -> 'data' ->> 'hostId' = expected.data ->> 'hostId'
                )
              )
          AND equivalent.aggregate_id = expected.aggregate_id
          AND equivalent.aggregate_version >= expected.aggregate_version
          AND (
            equivalent.aggregate_version > expected.aggregate_version
            OR equivalent.event_type = expected.event_type
          )
          AND (equivalent.payload -> 'data') @> (
              -- hostId is matched by host_id above, or directly for a Host birth
              -- whose command-authority Host legitimately differs. Snapshot exports
              -- can regenerate or omit configId and refresh audit metadata. V2
              -- operational registrations normalize away command aliases and
              -- lifecycle-derived flags, while Config Property snapshots omit the
              -- configName lookup alias. The remaining fields pin the logical state.
              expected.data - 'hostId' - 'aggregateVersion'
                            - 'newAggregateVersion' - 'configId' - 'updateTs'
                            - 'updateUser'
                            - CASE
                                WHEN expected.event_type = 'OperationalStoreBindingRegisteredEvent'
                                  THEN ARRAY['targetHostId', 'scopeKind', 'active', 'published']::TEXT[]
                                WHEN expected.event_type = 'ConfigPropertyCreatedEvent'
                                  THEN ARRAY['configName']::TEXT[]
                                ELSE ARRAY[]::TEXT[]
                              END
          )
     );

  IF missing_events IS NOT NULL THEN
    RAISE EXCEPTION 'event delta events were neither imported nor superseded by equivalent aggregate state:%', E'\n' || missing_events;
  END IF;
END
$verify$;
