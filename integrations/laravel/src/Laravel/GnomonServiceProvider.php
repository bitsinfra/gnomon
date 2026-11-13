<?php

declare(strict_types=1);

namespace Gnomon\Laravel;

use Illuminate\Database\Connection;
use Illuminate\Support\ServiceProvider;

/**
 * Registers the BranchManager and the pgsql connection resolver, so every pgsql connection
 * follows the current branch. config/gnomon.php (optional):
 *
 *   return ['header' => 'X-Gnomon-Branch', 'allow' => '/^(preview|agent)\//'];
 *
 * A connection's own 'gnomon' => ['branch' => 'feature'] pins it to one branch whatever the
 * request says; 'gnomon' => ['mode' => 'transaction'] for pgbouncer in transaction mode.
 */
final class GnomonServiceProvider extends ServiceProvider
{
    public function register(): void
    {
        $this->app->scoped(BranchManager::class, fn () => new BranchManager());
        Connection::resolverFor('pgsql', fn ($connection, $database, $prefix, $config) =>
            new BranchPostgresConnection($connection, $database, $prefix, $config));
    }
}
