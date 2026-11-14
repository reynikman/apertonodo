-- "Subgenre" relations before 30.09.2026 were loaded inverted: parent_mbid
-- held the subgenre. Walking up the tree went downward and never reached our
-- roots, and 125,419 artists fell into "World". Loader fixed
-- (app/mbcopy.py), here is a one-off reversal of already loaded data.
-- No reciprocal pairs exist in table (verified on production), so UPDATE will
-- not conflict with primary key. Does nothing on empty table.
UPDATE mb_genre_edge SET child_mbid = parent_mbid, parent_mbid = child_mbid
WHERE kind = 'subgenre';
