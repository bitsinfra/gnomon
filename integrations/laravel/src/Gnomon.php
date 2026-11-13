<?php

declare(strict_types=1);

namespace Gnomon;

use PDO;
use Throwable;

/**
 * Branches of a PostgreSQL database with gnomon, from PDO. Framework-free; the
 * Laravel pieces are in Gnomon\Laravel.
 *
 *   $pdo = new PDO(Gnomon::dsn('pgsql:host=db;dbname=app', 'feature'));   // sessions start on a branch
 *   Gnomon::use($pdo, 'feature');                                            // or put a session on one
 *   Gnomon::withBranch($pdo, 'feature', fn (PDO $pdo) => ...);               // one transaction (poolers)
 */
final class Gnomon
{
    /** The routing schema of a user schema; scratch branches have their own. */
    public static function routingSchema(string $schema, bool $scratch = false): string
    {
        return 'gnomon_r_' . $schema . ($scratch ? '__s' : '');
    }

    /** The libpq options value that starts sessions on a branch. */
    public static function branchOptions(string $branch, bool $cModule = false, array $schemas = ['public']): string
    {
        $o = '-c gnomon.branch=' . $branch;
        if ($cModule) {
            return $o;
        }
        $path = [];
        foreach ($schemas as $s) {
            $path[] = self::routingSchema($s);
            $path[] = $s;
        }
        return $o . ' -c search_path=' . implode(',', $path);
    }

    /** A PDO pgsql DSN whose sessions start on a branch. */
    public static function dsn(string $dsn, string $branch, bool $cModule = false): string
    {
        return self::withOptions($dsn, self::branchOptions($branch, $cModule));
    }

    /** A DSN with an options value the database computed (connectionOptions). */
    public static function withOptions(string $dsn, string $options): string
    {
        return rtrim($dsn, ';') . ";options='" . str_replace(["\\", "'"], ["\\\\", "\\'"], $options) . "'";
    }

    /** What a branch's sessions need (schema versions and masks included). */
    public static function connectionOptions(PDO $pdo, string $branch, bool $cModule = false): ?string
    {
        return self::value($pdo, 'select gnomon.connection_options(?, ?)', [$branch, $cModule ? 'true' : 'false']);
    }

    /** Put a session on a branch ('main' leaves it); returns the search path. */
    public static function use(PDO $pdo, string $branch): ?string
    {
        return self::value($pdo, 'select gnomon.use(?)', [$branch]);
    }

    /** Put the current transaction on a branch. */
    public static function begin(PDO $pdo, string $branch): void
    {
        self::value($pdo, 'select gnomon.begin(?)', [$branch]);
    }

    /** Run $fn in one transaction on a branch, committed when it returns. */
    public static function withBranch(PDO $pdo, string $branch, callable $fn): mixed
    {
        $pdo->beginTransaction();
        try {
            self::begin($pdo, $branch);
            $r = $fn($pdo);
            $pdo->commit();
            return $r;
        } catch (Throwable $e) {
            $pdo->rollBack();
            throw $e;
        }
    }

    public static function createBranch(PDO $pdo, string $name, string $parent = 'main', string $kind = 'logged'): int
    {
        return (int) self::value($pdo, 'select gnomon.create_branch(?, ?, ?)::text', [$name, $parent, $kind]);
    }

    /** A scratch branch with a fresh name, for a test. */
    public static function createScratch(PDO $pdo, string $prefix = 'test', string $parent = 'main'): string
    {
        $name = (string) self::value($pdo, "select ?::text || '/' || substr(md5(random()::text), 1, 10)", [$prefix]);
        self::createBranch($pdo, $name, $parent, 'scratch');
        return $name;
    }

    public static function dropBranch(PDO $pdo, string $name): void
    {
        self::value($pdo, 'select gnomon.drop_branch(?, true)::text', [$name]);
    }

    /** Merge a branch into its parent (or target); returns the merge's status. */
    public static function merge(PDO $pdo, string $source, ?string $target = null): ?string
    {
        $id = self::value($pdo, 'select gnomon.merge(?, ?)::text', [$source, $target]);
        return self::value($pdo, 'select status from gnomon.merge where id = ?::bigint', [$id]);
    }

    /** The stable [gnomon:<slug>] of an error, or null. */
    public static function code(Throwable $e): ?string
    {
        for ($x = $e; $x !== null; $x = $x->getPrevious()) {
            if (preg_match('/\[gnomon:([a-z_0-9]+)\]/', $x->getMessage(), $m)) {
                return $m[1];
            }
        }
        return null;
    }

    /** @internal */
    public static function value(PDO $pdo, string $sql, array $args = []): ?string
    {
        $st = $pdo->prepare($sql);
        $st->execute($args);
        $v = $st->fetchColumn();
        return $v === false || $v === null ? null : (string) $v;
    }
}
