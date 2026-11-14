-- Purging third-party secrets from the database.
-- Before this migration playback_sessions stored the indexer link together with its
-- apikey: backup sources were stored in alternates as raw Prowlarr links, and
-- source_locator stored the same link when Prowlarr served the release payload itself.
-- There are no more backup sources, and the locator is now only a URI without private
-- source keys. Previously recorded data is scrubbed here.
-- Migrations run in full on every startup, so everything below can be
-- repeated any number of times without harm.
-- There can be no semicolons in comments here: migrate.py splits
-- migrations on them, and half of the comment would become a separate statement.
UPDATE playback_sessions SET alternates = NULL WHERE alternates IS NOT NULL;
UPDATE playback_sessions SET source_locator = NULL
WHERE source_locator IS NOT NULL
  AND (source_locator NOT ILIKE 'magnet:%' OR source_locator ~* '(apikey|passkey|api_key|[?&]pk)=');
DELETE FROM playback_sessions WHERE expires_at < now() - interval '1 day';
