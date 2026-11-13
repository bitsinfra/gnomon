<?php

declare(strict_types=1);

namespace Gnomon\Laravel;

use Closure;
use Gnomon\Gnomon;
use Illuminate\Database\PostgresConnection;

/**
 * The pgsql connection the resolver makes (Connection::resolverFor). In session mode (the
 * default) it calls gnomon.use when the branch it is on differs from the BranchManager's, before a
 * statement runs; a reconnect starts over. In transaction mode ('gnomon' => ['mode' =>
 * 'transaction'] in the connection's config, for pgbouncer in transaction mode) it sets no session
 * state and calls gnomon.begin at the start of each outermost transaction instead; a statement
 * outside a transaction on a branch is then refused rather than run on main: run branch work in
 * DB::transaction.
 */
class BranchPostgresConnection extends PostgresConnection
{
    private ?int $routedPdo = null;
    private ?string $routedTo = null;

    private function manager(): BranchManager
    {
        return app(BranchManager::class);
    }

    private function transactionMode(): bool
    {
        return ($this->config['gnomon']['mode'] ?? 'session') === 'transaction';
    }

    /** The connection's pinned branch ('gnomon' => ['branch' => ...]) or the current one. */
    private function branch(): string
    {
        return $this->config['gnomon']['branch'] ?? $this->manager()->current();
    }

    private function route(\PDO $pdo): \PDO
    {
        if ($this->transactionMode()) {
            return $pdo;
        }
        $branch = $this->branch();
        $id = spl_object_id($pdo);
        if ($this->routedPdo !== $id || $this->routedTo !== $branch) {
            if (!($this->routedPdo !== $id && $branch === 'main')) { // a new session starts on main
                Gnomon::use($pdo, $branch);
            }
            $this->routedPdo = $id;
            $this->routedTo = $branch;
        }
        return $pdo;
    }

    public function getPdo()
    {
        return $this->route(parent::getPdo());
    }

    public function getReadPdo()
    {
        // the parent hands out the write PDO through getPdo (already routed) inside transactions
        // and on sticky connections; a separate read PDO is routed on its own
        $pdo = parent::getReadPdo();
        return $pdo === $this->pdo ? $pdo : $this->routeRead($pdo);
    }

    private ?int $routedRead = null;
    private ?string $routedReadTo = null;

    private function routeRead(\PDO $pdo): \PDO
    {
        if ($this->transactionMode()) {
            return $pdo;
        }
        $branch = $this->branch();
        $id = spl_object_id($pdo);
        if ($this->routedRead !== $id || $this->routedReadTo !== $branch) {
            Gnomon::use($pdo, $branch);
            $this->routedRead = $id;
            $this->routedReadTo = $branch;
        }
        return $pdo;
    }

    protected function run($query, $bindings, Closure $callback)
    {
        if ($this->transactionMode() && $this->transactions === 0 && $this->branch() !== 'main') {
            throw new \LogicException(sprintf(
                'gnomon: connection [%s] routes transactions only (transaction mode): run this in DB::transaction() [branch %s]',
                $this->getName(), $this->branch()));
        }
        return parent::run($query, $bindings, $callback);
    }

    protected function createTransaction()
    {
        parent::createTransaction();
        // beginTransaction counts the transaction after createTransaction: 0 is the outermost
        if ($this->transactionMode() && $this->transactions === 0 && $this->branch() !== 'main') {
            Gnomon::begin(parent::getPdo(), $this->branch());
        }
    }
}
