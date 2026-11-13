<?php

declare(strict_types=1);

namespace Gnomon\Tests;

use Gnomon\Laravel\BranchManager;
use Gnomon\Laravel\Testing\UsesGnomonBranch;
use Illuminate\Support\Facades\DB;

/** UsesGnomonBranch: each test on a scratch branch of its own, dropped after it. */
final class TraitTest extends GnomonLaravelCase
{
    use UsesGnomonBranch;

    public function testRunsOnItsOwnBranch(): void
    {
        $this->assertStringStartsWith('phpunit/', $this->gnomonBranch);
        DB::table('lv_item')->insert(['id' => 10, 'name' => 'scratch']);
        $this->assertSame(1, DB::table('lv_item')->count(), 'the test sees its write');
        $this->assertSame(0, $this->app->make(BranchManager::class)->on('main', fn () => DB::table('lv_item')->count()), 'main does not');
    }

    public function testTheBranchIsDroppedAfterwards(): void
    {
        $left = $this->app->make(BranchManager::class)->on('main', fn () => DB::table('gnomon.branch')->where('name', 'like', 'phpunit/%')
            ->where('name', '<>', $this->gnomonBranch)->where('status', 'open')->count());
        $this->assertSame(0, $left);
    }
}
