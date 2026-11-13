<?php

declare(strict_types=1);

namespace Gnomon\Laravel;

use Closure;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;

/**
 * Middleware: the request works on the branch its X-Gnomon-Branch header names (config
 * gnomon.header), when the name matches gnomon.allow (a regular expression; none by default, so
 * the middleware does nothing until it is configured). The branch goes back to main afterwards,
 * which matters under Octane, where the container outlives the request.
 *
 *   Route::middleware(\Gnomon\Laravel\UseBranch::class)->group(...);
 */
final class UseBranch
{
    public function __construct(private BranchManager $branches)
    {
    }

    public function handle(Request $request, Closure $next): Response
    {
        $branch = $request->header((string) config('gnomon.header', 'X-Gnomon-Branch'));
        $allow = config('gnomon.allow');
        if (!is_string($branch) || $branch === '' || !is_string($allow) || !preg_match($allow, $branch)) {
            return $next($request);
        }
        return $this->branches->on($branch, fn () => $next($request));
    }
}
