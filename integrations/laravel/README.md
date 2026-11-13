# gnomon for PHP and Laravel

Branches of a PostgreSQL database with gnomon from PDO, a Laravel connection resolver and
middleware, and a PHPUnit and Pest trait that gives each test its own scratch branch.

Tests: `composer install && GNOMON_TEST_DSN='pgsql:host=/socket/dir;port=5432;dbname=app;user=postgres'
vendor/bin/phpunit`: the PDO helpers on a real branch, and through Laravel (Orchestra Testbench)
the resolver, the middleware, transaction mode and the test trait.

```php
// PDO: sessions that start on a branch
$pdo = new PDO(Gnomon::dsn('pgsql:host=db;dbname=app', 'feature'), $user, $password);   // true for the C module

// one transaction on a branch (behind pgbouncer in transaction mode)
Gnomon::withBranch($pdo, 'feature', fn (PDO $pdo) => $pdo->exec('...'));

// errors: the stable slug
catch (PDOException $e) { if (Gnomon::code($e) === 'ddl_on_branch') { ... } }
```

## Laravel

The service provider is discovered automatically. It makes every `pgsql` connection follow the
current branch (`Gnomon\Laravel\BranchManager`, main by default):

```php
app(BranchManager::class)->on('feature', fn () => Order::create([...]));   // a job, a command

Route::middleware(\Gnomon\Laravel\UseBranch::class)->group(...);           // X-Gnomon-Branch header
// config/gnomon.php: ['allow' => '/^preview\//'] — the middleware ignores names it does not allow

// config/database.php, a connection pinned to a branch, or per transaction behind pgbouncer
'pgsql' => [..., 'gnomon' => ['branch' => 'feature']],
'pgsql' => [..., 'gnomon' => ['mode' => 'transaction']],
```

In transaction mode a statement outside a transaction on a branch is refused (a `LogicException`)
rather than run on main; wrap branch work in `DB::transaction`.

## Tests

```php
class SignupTest extends TestCase
{
    use \Gnomon\Laravel\Testing\UsesGnomonBranch;   // in place of RefreshDatabase

    public function test_signup(): void { $this->post('/signup', [...])->assertOk(); }
}

uses(Tests\TestCase::class, \Gnomon\Laravel\Testing\UsesGnomonBranch::class)->in('Feature');   // Pest
```

Each test forks main (or `protected string $gnomonParent`) into a scratch branch, dropped after
the test; `GNOMON_KEEP=1` keeps them.
