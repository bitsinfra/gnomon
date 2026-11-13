<?php

declare(strict_types=1);

namespace Gnomon\Laravel;

/**
 * The branch the current request or job works on (main unless set). Connections made by the
 * resolver read it before each statement, so setting it mid-request moves the connection.
 */
final class BranchManager
{
    private string $branch = 'main';

    public function current(): string
    {
        return $this->branch;
    }

    public function set(?string $branch): void
    {
        $this->branch = $branch === null || $branch === '' ? 'main' : $branch;
    }

    /** Run $fn with the branch set, then put the previous one back. */
    public function on(string $branch, callable $fn): mixed
    {
        $prev = $this->branch;
        $this->set($branch);
        try {
            return $fn();
        } finally {
            $this->branch = $prev;
        }
    }
}
