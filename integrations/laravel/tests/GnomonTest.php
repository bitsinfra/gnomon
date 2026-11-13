<?php

declare(strict_types=1);

namespace Gnomon\Tests;

use Gnomon\Gnomon;
use PDO;
use PHPUnit\Framework\TestCase;

final class GnomonTest extends TestCase
{
    public function testOptions(): void
    {
        $this->assertSame('-c gnomon.branch=f', Gnomon::branchOptions('f', true));
        $this->assertSame('-c gnomon.branch=f -c search_path=gnomon_r_public,public', Gnomon::branchOptions('f'));
        $this->assertSame("pgsql:host=db;options='-c gnomon.branch=f'", Gnomon::dsn('pgsql:host=db;', 'f', true));
        $this->assertSame('gnomon_r_app__s', Gnomon::routingSchema('app', true));
    }

    public function testCode(): void
    {
        $this->assertSame('ddl_on_branch', Gnomon::code(new \RuntimeException('x', 0, new \RuntimeException('refused [gnomon:ddl_on_branch]'))));
        $this->assertNull(Gnomon::code(new \RuntimeException('plain')));
    }

    /** With GNOMON_TEST_DSN (a pgsql DSN with user and password), against a real database. */
    public function testBranch(): void
    {
        $dsn = getenv('GNOMON_TEST_DSN');
        if ($dsn === false) {
            $this->markTestSkipped('GNOMON_TEST_DSN is not set');
        }
        $pdo = new PDO($dsn, null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
        $b = Gnomon::createScratch($pdo, 'phpunit');
        try {
            $on = new PDO(Gnomon::withOptions($dsn, (string) Gnomon::connectionOptions($pdo, $b)), null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
            $this->assertSame($b, $on->query("select current_setting('gnomon.branch')")->fetchColumn());
            $this->assertSame($b, Gnomon::withBranch($pdo, $b, fn (PDO $p) => $p->query("select current_setting('gnomon.branch')")->fetchColumn()));
        } finally {
            Gnomon::dropBranch($pdo, $b);
        }
    }
}
