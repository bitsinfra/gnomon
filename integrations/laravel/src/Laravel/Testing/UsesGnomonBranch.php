<?php

declare(strict_types=1);

namespace Gnomon\Laravel\Testing;

use Gnomon\Gnomon;
use Gnomon\Laravel\BranchManager;
use Illuminate\Support\Facades\DB;

/**
 * PHPUnit and Pest: each test runs on its own scratch branch of the seeded database, in place of
 * RefreshDatabase or DatabaseTransactions; the code under test may commit. Laravel calls
 * setUpUsesGnomonBranch and tearDownUsesGnomonBranch for a test case that uses the trait.
 *
 *   class SignupTest extends TestCase { use UsesGnomonBranch; ... }
 *   uses(Tests\TestCase::class, UsesGnomonBranch::class)->in('Feature');      // Pest
 *
 * GNOMON_KEEP=1 keeps the branches; $gnomonParent picks the branch to fork (main).
 */
trait UsesGnomonBranch
{
    protected string $gnomonBranch = '';

    protected function gnomonParent(): string
    {
        return property_exists($this, 'gnomonParent') ? $this->gnomonParent : 'main';
    }

    public function setUpUsesGnomonBranch(): void
    {
        $branches = $this->app->make(BranchManager::class);
        $branches->set('main');
        $pdo = DB::connection()->getPdo();
        $this->gnomonBranch = Gnomon::createScratch($pdo, 'phpunit', $this->gnomonParent());
        $branches->set($this->gnomonBranch);
    }

    public function tearDownUsesGnomonBranch(): void
    {
        if ($this->gnomonBranch === '') {
            return;
        }
        $this->app->make(BranchManager::class)->set('main');
        $pdo = DB::connection()->getPdo();
        if (getenv('GNOMON_KEEP') !== '1') {
            Gnomon::dropBranch($pdo, $this->gnomonBranch);
        }
        $this->gnomonBranch = '';
    }
}
