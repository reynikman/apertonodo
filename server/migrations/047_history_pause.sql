-- FT-630 (R-A49): temporary pause of history recording ("Do not record history").
-- Duration rather than flag: pause turns off automatically after three hours (e.g. if
-- phone was given to a child or guests), preventing user from forgetting to turn recording
-- back on and losing playback history permanently.
-- One row per user, reenabling updates duration.

CREATE TABLE IF NOT EXISTS history_pause (
    user_id uuid PRIMARY KEY,
    until timestamptz NOT NULL
);
