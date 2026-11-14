-- FT-720 (R-A88): core does not know where a book comes from. The key and the hint are opaque
-- columns `asset_key` and `asset_hint`, parsed by the extension.
-- FT-905: migration 055 now creates these columns directly. On production this version
-- is already recorded and the columns were renamed by the earlier text of this file.
SELECT 1;
