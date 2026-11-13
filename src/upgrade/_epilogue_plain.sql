-- Upgrade epilogue (plain-SQL form): rebuild every per-table object from the new code.
select set_config('gnomon._in_ddl', '', true);
select _gnomon.upgrade_regenerate();
