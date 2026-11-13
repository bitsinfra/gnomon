<?php

declare(strict_types=1);

namespace Gnomon\Tests;

use Gnomon\Laravel\BranchManager;
use Gnomon\Laravel\GnomonServiceProvider;
use Gnomon\Laravel\UseBranch;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Route;
use Orchestra\Testbench\TestCase;

/** The Laravel pieces against GNOMON_TEST_DSN: resolver, middleware, transaction mode. */
abstract class GnomonLaravelCase extends TestCase
{
    protected function getPackageProviders($app): array
    {
        return [GnomonServiceProvider::class];
    }

    protected function defineEnvironment($app): void
    {
        $dsn = (string) getenv('GNOMON_TEST_DSN');
        preg_match_all('/(\w+)=([^;]*)/', substr($dsn, strlen('pgsql:')), $m, PREG_SET_ORDER);
        $kv = [];
        foreach ($m as [, $k, $v]) {
            $kv[$k] = $v;
        }
        $conn = ['driver' => 'pgsql', 'host' => $kv['host'] ?? '127.0.0.1', 'port' => $kv['port'] ?? '5432', 'database' => $kv['dbname'] ?? 'postgres',
                 'username' => $kv['user'] ?? 'postgres', 'password' => '', 'charset' => 'utf8', 'prefix' => '', 'search_path' => 'public', 'sslmode' => 'disable'];
        $app['config']->set('database.default', 'pgsql');
        $app['config']->set('database.connections.pgsql', $conn);
        $app['config']->set('database.connections.pgsql_tx', $conn + ['gnomon' => ['mode' => 'transaction']]);
        $app['config']->set('gnomon.allow', '/^lv-/');
    }

    protected function setUp(): void
    {
        if (getenv('GNOMON_TEST_DSN') === false) {
            $this->markTestSkipped('GNOMON_TEST_DSN is not set');
        }
        parent::setUp();
        $this->app->make(BranchManager::class)->on('main', function () {
            DB::statement('create table if not exists lv_item (id int primary key, name text)');
            DB::statement("select gnomon.track('lv_item') where not exists (select 1 from gnomon.tracked where relname = 'lv_item')");
            DB::statement("select gnomon.create_branch('lv-a') where not exists (select 1 from gnomon.branch where name = 'lv-a')");
        });
    }

    protected function tearDown(): void
    {
        $this->app->make(BranchManager::class)->on('main', function () {
            DB::statement("select gnomon.drop_branch(name, true) from gnomon.branch where name like 'lv-%'");
            DB::table('lv_item')->delete();
        });
        parent::tearDown();
    }

    protected function rows(string $branch, string $conn = 'pgsql'): int
    {
        return $this->app->make(BranchManager::class)->on($branch, fn () => $conn === 'pgsql'
            ? DB::table('lv_item')->count()
            : DB::connection($conn)->transaction(fn ($c) => $c->table('lv_item')->count()));
    }
}
