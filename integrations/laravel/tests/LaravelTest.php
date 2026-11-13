<?php

declare(strict_types=1);

namespace Gnomon\Tests;

use Gnomon\Laravel\BranchManager;
use Gnomon\Laravel\GnomonServiceProvider;
use Gnomon\Laravel\UseBranch;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Route;

final class LaravelTest extends GnomonLaravelCase
{
    public function testTheResolverFollowsTheCurrentBranch(): void
    {
        $branches = $this->app->make(BranchManager::class);
        $branches->on('lv-a', fn () => DB::table('lv_item')->insert(['id' => 1, 'name' => 'on the branch']));
        $this->assertSame(0, $this->rows('main'), 'main does not see the branch write');
        $this->assertSame(1, $this->rows('lv-a'));
        $this->assertSame('main', $branches->current(), 'the branch is put back');
    }

    public function testTheMiddleware(): void
    {
        Route::post('/items', function () {
            DB::table('lv_item')->insert(['id' => (int) request('id'), 'name' => 'request']);
            return 'ok';
        })->middleware(UseBranch::class);
        $this->post('/items', ['id' => 2], ['X-Gnomon-Branch' => 'lv-a'])->assertOk();
        $this->assertSame(1, $this->rows('lv-a'), 'an allowed branch name routes the request');
        $this->assertSame(0, $this->rows('main'));
        $this->post('/items', ['id' => 3], ['X-Gnomon-Branch' => 'not-allowed'])->assertOk();
        $this->assertSame(1, $this->rows('main'), 'a name gnomon.allow does not match is ignored');
    }

    public function testTransactionMode(): void
    {
        $branches = $this->app->make(BranchManager::class);
        $branches->on('lv-a', fn () => DB::connection('pgsql_tx')->transaction(fn ($c) => $c->table('lv_item')->insert(['id' => 4, 'name' => 'tx'])));
        $this->assertSame(1, $this->rows('lv-a', 'pgsql_tx'), 'a transaction is on the branch');
        $this->assertSame(0, $this->rows('main'));
        $this->expectException(\LogicException::class);
        $branches->on('lv-a', fn () => DB::connection('pgsql_tx')->table('lv_item')->count());
    }
}
