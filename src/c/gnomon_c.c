/*
 * gnomon_c: the optional C module for Gnomon.
 *
 * Load with shared_preload_libraries = 'gnomon_c'. Where it is loaded it adds:
 *   - a background worker that runs gnomon.heartbeat() every second (ticks, scheduled
 *     changes, early warnings, the ledger) in the databases listed in gnomon.heartbeat_databases;
 *   - transparent routing: SET gnomon.branch (or gnomon.as_of / gnomon.valid_at) alone routes
 *     reads and writes of tracked tables to their routing views, schema-qualified names included;
 *   - branch DML the SQL core cannot do: SELECT ... FOR UPDATE/SHARE takes real locks,
 *     INSERT ... ON CONFLICT works, TRUNCATE becomes gnomon.truncate();
 *   - read-set tracking for stale-read detection (gnomon.track_reads);
 *   - a C versioning trigger for main writes (_gnomon.c_version_trigger, via the gnomon_c
 *     extension), selected per table with gnomon.use_c_trigger().
 * The SQL core never calls this module; it reads current_setting('gnomon.c_module').
 */
#include "postgres.h"

#include "access/detoast.h"
#include "access/genam.h"
#include "access/heapam.h"
#include "common/hashfn.h"
#include "storage/bufmgr.h"
#include "access/relscan.h"
#include "access/table.h"
#include "access/tableam.h"
#include "access/htup_details.h"
#include "access/transam.h"
#include "access/xact.h"
#include "access/xlog.h"
#include "catalog/index.h"
#include "catalog/namespace.h"
#include "catalog/pg_class.h"
#include "catalog/pg_collation.h"
#include "catalog/pg_constraint.h"
#include "catalog/pg_namespace.h"
#include "catalog/pg_trigger.h"
#include "catalog/pg_type.h"
#include "commands/trigger.h"
#include "executor/executor.h"
#include "executor/spi.h"
#include "funcapi.h"
#include "miscadmin.h"
#include "nodes/makefuncs.h"
#include "nodes/nodeFuncs.h"
#include "optimizer/planner.h"
#include "parser/analyze.h"
#include "parser/parse_func.h"
#include "parser/parsetree.h"
#include "parser/parser.h"
#include "pgstat.h"
#include "port/atomics.h"
#include "postmaster/bgworker.h"
#include "postmaster/interrupt.h"
#include "replication/origin.h"
#include "storage/ipc.h"
#include "storage/latch.h"
#include "storage/lmgr.h"
#include "storage/lwlock.h"
#include "storage/shmem.h"
#include "storage/proc.h"
#include "tcop/utility.h"
#include "utils/acl.h"
#include "utils/builtins.h"
#include "utils/datum.h"
#include "utils/fmgroids.h"
#include "utils/fmgrprotos.h"
#include "utils/array.h"
#include "access/relation.h"
#include "catalog/pg_am.h"
#include "commands/defrem.h"
#include "utils/varlena.h"
#include "rewrite/rewriteManip.h"
#include "nodes/extensible.h"
#include "optimizer/pathnode.h"
#include "optimizer/paths.h"
#include "optimizer/restrictinfo.h"
#include "optimizer/optimizer.h"
#include "commands/explain.h"
#if PG_VERSION_NUM >= 180000
#include "commands/explain_format.h"
#endif
#include "utils/guc.h"
#include "utils/hsearch.h"
#include "utils/inval.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/rel.h"
#include "utils/snapmgr.h"
#include "utils/syscache.h"
#include "utils/timestamp.h"
#include "utils/typcache.h"
#include "utils/syscache.h"
#include "utils/varbit.h"
#include "utils/pg_lsn.h"
#include "utils/ruleutils.h"
#include "utils/json.h"
#include "utils/jsonb.h"

#if PG_VERSION_NUM >= 180000
PG_MODULE_MAGIC_EXT(.name = "gnomon_c", .version = "1.0.1");
#else
PG_MODULE_MAGIC;
#endif

void		_PG_init(void);
PGDLLEXPORT void gnomon_worker_main(Datum arg);

/* GUCs */
static char *c_module_flag = NULL;
static char *heartbeat_databases = NULL;
static int	heartbeat_interval_ms = 1000;
static bool routing_enabled = true;
static bool track_reads = false;
static bool direct_inserts = true;

/* previous hooks */
static post_parse_analyze_hook_type prev_post_parse_analyze = NULL;
static ProcessUtility_hook_type prev_process_utility = NULL;
static ExecutorStart_hook_type prev_executor_start = NULL;
static ExecutorEnd_hook_type prev_executor_end = NULL;

static void wm_note(Oid relid, int64 key);
static void tf_shmem_request(void);
static void tf_shmem_startup(void);
static bool point_enabled = true;
static bool search_auto = true;	/* gnomon.c_search_views */
/* gnomon.report_coordinate and gnomon.last_coordinate (see statement_coordinate) */
static bool report_coordinate = false;
static char *last_coordinate = NULL;
static int	report_epoch = -1;		/* gnomon's cluster epoch, looked up once per session */
static bool substitute_enabled = true;
static bool in_point_fallback = false;

/*
 * Counters in shared memory: how point reads were answered, what the touched-key
 * filter saved, DDL sent to gnomon.ddl and queries given the search views, summed over every
 * session since the server started (_gnomon.c_counters(), gnomon.metrics()). The per-session
 * copies stay for tests (_gnomon.c_point_stats()).
 */
#define GN_NCOUNTERS 10
static const char *const gn_counter_names[GN_NCOUNTERS] = {
	"point_none", "point_main", "point_head", "point_view", "point_rebuilt",
	"filter_skips", "filter_scans", "ddl_redirects", "search_view_queries", "upserts"
};
enum
{
	GC_FILTER_SKIPS = 5, GC_FILTER_SCANS, GC_DDL_REDIRECTS, GC_SEARCH_VIEWS, GC_UPSERTS
};
typedef struct GnCounters
{
	pg_atomic_uint64 c[GN_NCOUNTERS];
}			GnCounters;
static GnCounters *gn_counters = NULL;

static inline void
gn_count(int i)
{
	if (gn_counters != NULL)
		pg_atomic_fetch_add_u64(&gn_counters->c[i], 1);
}

static void point_rewrite(Query *q);
static void coord_parts(Datum coord, int16 *epoch, Datum *snap);
static Oid	c_point_fn = InvalidOid;

/*
 * The C trigger's SPI connection and its "enable_seqscan = off" (for the SPI plans it falls back
 * to) are opened on first need: the direct paths use neither, and opening both for every row cost
 * as much as a heap insert. Outside the trigger these do nothing; callers there connect themselves.
 */
static bool in_ctrig = false;
static bool trig_spi_on = false;
static int	trig_guc_nest = -1;

static inline void
trig_spi(void)
{
	if (in_ctrig && !trig_spi_on)
	{
		SPI_connect();
		trig_spi_on = true;
	}
}

static inline void
trig_plans(void)
{
	trig_spi();
	if (in_ctrig && trig_guc_nest < 0)
	{
		/* probes are always by key: never let stale "empty" statistics pick a sequential scan */
		trig_guc_nest = NewGUCNestLevel();
		(void) set_config_option("enable_seqscan", "off", PGC_USERSET, PGC_S_SESSION, GUC_ACTION_SAVE, true, 0, false);
	}
}
static bool wm_unchanged(Oid relid, Oid trig, int64 kxmin);
static Oid rel_c_trigger(Relation rel);
static int	exec_nesting = 0;
static bool upsert_pending = false;

/* ------------------------------------------------------------------------
 * Context
 * ------------------------------------------------------------------------ */

static bool
setting_set(const char *name)
{
	const char *v = GetConfigOption(name, true, false);

	return v != NULL && v[0] != '\0';
}

/* True when the session reads something other than main now, outside gnomon's own code. */
static bool
routing_active(void)
{
	const char *b;
	const char *sp;

	if (!routing_enabled || !IsTransactionState())
		return false;
	b = GetConfigOption("gnomon.branch", true, false);
	if (!((b != NULL && b[0] != '\0' && strcmp(b, "main") != 0) ||
		  setting_set("gnomon.as_of") || setting_set("gnomon.valid_at")))
		return false;
	/* gnomon's internal functions pin search_path to "pg_catalog, pg_temp": never rewrite there */
	sp = GetConfigOption("search_path", true, false);
	if (sp != NULL && strncmp(sp, "pg_catalog, pg_temp", 19) == 0)
		return false;
	{
		const char *ddl = GetConfigOption("gnomon._in_ddl", true, false);

		if (ddl != NULL && strcmp(ddl, "1") == 0)
			return false;
	}
	return true;
}

static bool
is_gnomon_internal_namespace(const char *nsp)
{
	return strcmp(nsp, "gnomon") == 0 || strcmp(nsp, "_gnomon") == 0 ||
		strncmp(nsp, "gnomon_r_", 9) == 0 || strcmp(nsp, "pg_catalog") == 0 ||
		strcmp(nsp, "information_schema") == 0 || strncmp(nsp, "pg_toast", 8) == 0 ||
		strncmp(nsp, "pg_temp", 7) == 0;
}

/*
 * What routing needs to know of the session's branch: whether it is a scratch branch, whose rows
 * are read through the scratch routing schemas (gnomon_r_<schema>__s), and its schema version,
 * whose views only gnomon.use() puts on the path. One catalog lookup per
 * transaction and branch name; the same lookup touches the branch's last_used once a minute,
 * since a session the module routes never calls gnomon.use() (expiry).
 */
static char kind_name[NAMEDATALEN];
static bool kind_scratch = false;
static int	kind_version = 0;
static LocalTransactionId kind_lxid = InvalidLocalTransactionId;
static bool kind_busy = false;
static TimestampTz kind_touched = 0;
static char kind_touched_name[NAMEDATALEN];

static void
branch_lookup(void)
{
	const char *b = GetConfigOption("gnomon.branch", true, false);
#if PG_VERSION_NUM >= 170000
	LocalTransactionId lxid = MyProc->vxid.lxid;
#else
	LocalTransactionId lxid = MyProc->lxid;
#endif

	if (b == NULL || b[0] == '\0' || strcmp(b, "main") == 0 || kind_busy)
	{
		kind_scratch = false;
		kind_version = 0;
		return;
	}
	if (kind_lxid == lxid && strncmp(kind_name, b, NAMEDATALEN) == 0)
		return;
	kind_busy = true;
	PG_TRY();
	{
		Oid			argtypes[1] = {TEXTOID};
		Datum		values[1] = {CStringGetTextDatum(b)};
		TimestampTz now = GetCurrentTimestamp();
		bool		touch = !RecoveryInProgress() && !XactReadOnly &&
			(strncmp(kind_touched_name, b, NAMEDATALEN) != 0 ||
			 TimestampDifferenceExceeds(kind_touched, now, 60 * 1000));

		SPI_connect();
		kind_scratch = false;
		kind_version = 0;
		if (SPI_execute_with_args("select kind = 'scratch', coalesce(schema_version, 0) from gnomon.branch where name = $1",
								  1, argtypes, values, NULL, true, 1) == SPI_OK_SELECT && SPI_processed == 1)
		{
			bool		isnull;
			Datum		d;

			d = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &isnull);
			kind_scratch = !isnull && DatumGetBool(d);
			d = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 2, &isnull);
			kind_version = isnull ? 0 : DatumGetInt32(d);
		}
		/* never waits: a branch another transaction is touching is left alone */
		if (touch)
		{
			SPI_execute_with_args("select gnomon._touch_nowait($1)", 1, argtypes, values, NULL, false, 0);
			kind_touched = now;
			strlcpy(kind_touched_name, b, NAMEDATALEN);
		}
		SPI_finish();
	}
	PG_FINALLY();
	{
		kind_busy = false;
	}
	PG_END_TRY();
	strlcpy(kind_name, b, NAMEDATALEN);
	kind_lxid = lxid;
}

static bool
branch_is_scratch(void)
{
	branch_lookup();
	return kind_scratch;
}

/* The routing schema for a user schema: a mask-profile schema on the search path wins. */
static Oid
routing_namespace(const char *nsp)
{
	char		buf[NAMEDATALEN * 2];
	List	   *path = fetch_search_path(false);
	ListCell   *lc;
	Oid			result = InvalidOid;
	size_t		plen;

	snprintf(buf, sizeof(buf), "gnomon_r_%s__m", nsp);
	plen = strlen(buf);
	foreach(lc, path)
	{
		char	   *n = get_namespace_name(lfirst_oid(lc));

		if (n != NULL && strncmp(n, buf, plen) == 0)
		{
			result = lfirst_oid(lc);
			break;
		}
	}
	list_free(path);
	if (OidIsValid(result))
		return result;
	/* a branch on a schema version reads through the version's views */
	branch_lookup();
	if (kind_version != 0 && !kind_scratch)
	{
		snprintf(buf, sizeof(buf), "gnomon_r_%s__v%d", nsp, kind_version);
		result = get_namespace_oid(buf, true);
		if (OidIsValid(result))
		{
			bool		on_path = false;

			path = fetch_search_path(false);
			foreach(lc, path)
				if (lfirst_oid(lc) == result)
					on_path = true;
			list_free(path);
			if (!on_path)
				ereport(ERROR,
						(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
						 errmsg("branch \"%s\" is on schema version %d, which SET gnomon.branch alone does not route",
								GetConfigOption("gnomon.branch", true, false), kind_version),
						 errhint("Use gnomon.use() or gnomon.begin(), or the options of gnomon.connection_options(), which put the version's views on the path. [gnomon:schema_version_routing]")));
			return result;
		}
	}
	if (branch_is_scratch())
	{
		snprintf(buf, sizeof(buf), "gnomon_r_%s__s", nsp);
		result = get_namespace_oid(buf, true);
		if (OidIsValid(result))
			return result;
	}
	snprintf(buf, sizeof(buf), "gnomon_r_%s", nsp);
	return get_namespace_oid(buf, true);
}

static bool
has_dropped_columns(Oid relid)
{
	Relation	rel = RelationIdGetRelation(relid);
	bool		dropped = false;

	if (rel == NULL)
		return false;
	for (int i = 0; i < RelationGetNumberOfAttributes(rel); i++)
		if (TupleDescAttr(RelationGetDescr(rel), i)->attisdropped)
			dropped = true;
	RelationClose(rel);
	return dropped;
}

/* Routing (or pass-through) view for a user relation, or InvalidOid. */
static Oid
routed_relid(Oid relid)
{
	char		kind = get_rel_relkind(relid);
	char	   *nsp;
	Oid			rnsp;

	if (!(kind == RELKIND_RELATION || kind == RELKIND_PARTITIONED_TABLE ||
		  kind == RELKIND_FOREIGN_TABLE || kind == RELKIND_MATVIEW || kind == RELKIND_VIEW))
		return InvalidOid;
	nsp = get_namespace_name(get_rel_namespace(relid));
	if (nsp == NULL || is_gnomon_internal_namespace(nsp))
		return InvalidOid;
	rnsp = routing_namespace(nsp);
	if (!OidIsValid(rnsp))
		return InvalidOid;
	return get_relname_relid(get_rel_name(relid), rnsp);
}

/* For a routing view, its base table; InvalidOid if relid is not a routing view of a table. */
static Oid
routing_view_base(Oid relid)
{
	char	   *nsp;
	char		base_nsp[NAMEDATALEN];
	char	   *m;
	Oid			bnsp;
	Oid			base;

	if (get_rel_relkind(relid) != RELKIND_VIEW)
		return InvalidOid;
	nsp = get_namespace_name(get_rel_namespace(relid));
	if (nsp == NULL || strncmp(nsp, "gnomon_r_", 9) != 0)
		return InvalidOid;
	strlcpy(base_nsp, nsp + 9, sizeof(base_nsp));
	m = strstr(base_nsp, "__m");
	if (m != NULL)
		*m = '\0';
	else
	{
		size_t		l = strlen(base_nsp);

		if (l > 3 && strcmp(base_nsp + l - 3, "__s") == 0)
			base_nsp[l - 3] = '\0';	/* a scratch-branch routing schema */
	}
	bnsp = get_namespace_oid(base_nsp, true);
	if (!OidIsValid(bnsp))
		return InvalidOid;
	base = get_relname_relid(get_rel_name(relid), bnsp);
	if (!OidIsValid(base))
		return InvalidOid;
	{
		char		k = get_rel_relkind(base);

		if (k != RELKIND_RELATION && k != RELKIND_PARTITIONED_TABLE)
			return InvalidOid;
	}
	/* only tracked tables have an INSTEAD OF trigger; pass-through views of untracked tables do not */
	return base;
}

/* ------------------------------------------------------------------------
 * Query rewriting at parse analysis
 * ------------------------------------------------------------------------ */

static Oid
lookup_func(const char *schema, const char *name, int nargs, Oid *argtypes)
{
	List	   *fname = list_make2(makeString(pstrdup(schema)), makeString(pstrdup(name)));

	return LookupFuncName(fname, nargs, argtypes, false);
}

/* gnomon._lock_row(regclass, anyelement) or gnomon._note_read(...) on the RTE's whole row */
static TargetEntry *
row_call_tle(Query *q, int rti, Oid view, Oid base, const char *fname, const char *resname)
{
	Oid			argtypes[2] = {REGCLASSOID, ANYELEMENTOID};
	Oid			fn = lookup_func("gnomon", fname, 2, argtypes);
	Var		   *whole = makeVar(rti, InvalidAttrNumber, get_rel_type_id(view), -1, InvalidOid, 0);
	Const	   *rel = makeConst(REGCLASSOID, -1, InvalidOid, sizeof(Oid), ObjectIdGetDatum(base), false, true);
	FuncExpr   *call = makeFuncExpr(fn, BOOLOID, list_make2(rel, whole), InvalidOid, InvalidOid, COERCE_EXPLICIT_CALL);

	return makeTargetEntry((Expr *) call, list_length(q->targetList) + 1, pstrdup(resname), true);
}


/*
 * INSERT ... ON CONFLICT on a branch: the planner cannot infer arbiters on a view, so the
 * conflict clause is removed and its meaning handed to the branch write path through
 * gnomon._upsert, set by a qual evaluated as the rows are produced (and so on every execution
 * of a prepared statement). ExecutorEnd clears it at the outermost level.
 *
 * The meaning is a JSON spec: the action, the arbiter columns, arbiter
 * expressions and a partial index's predicate (over the existing row v and the proposed row p),
 * and for DO UPDATE the SET expressions and the WHERE clause, deparsed over the existing row gn_t
 * and the excluded row gn_x. The branch write function evaluates them (_gnomon.upsert_row).
 */
typedef struct UpsertCtx
{
	int			target;
	int			excl;
} UpsertCtx;

/* target Vars become varno 1 (deparsed under an alias), excluded ones become numbered Params */
static Node *
upsert_mutator(Node *node, UpsertCtx *ctx)
{
	if (node == NULL)
		return NULL;
	if (IsA(node, Var))
	{
		Var		   *v = (Var *) node;

		if (v->varlevelsup == 0 && ctx->excl > 0 && v->varno == ctx->excl)
		{
			Param	   *p = makeNode(Param);

			p->paramkind = PARAM_EXTERN;
			p->paramid = 10000 + v->varattno;
			p->paramtype = v->vartype;
			p->paramtypmod = v->vartypmod;
			p->paramcollid = v->varcollid;
			p->location = -1;
			return (Node *) p;
		}
		if (v->varlevelsup == 0 && v->varno == ctx->target)
		{
			Var		   *nv = copyObject(v);

			nv->varno = 1;
#if PG_VERSION_NUM >= 130000
			nv->varnosyn = 1;
#endif
			return (Node *) nv;
		}
	}
	return expression_tree_mutator(node, upsert_mutator, (void *) ctx);
}

/* An expression as SQL over alias (the target row) and gn_x (the excluded row). */
static char *
upsert_deparse(Node *expr, Oid base, const char *alias, UpsertCtx *ctx)
{
	Node	   *m;
	char	   *raw;
	StringInfoData out;

	if (checkExprHasSubLink(expr))
		ereport(ERROR, (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
						errmsg("on gnomon branches ON CONFLICT expressions cannot contain subqueries")));
	m = upsert_mutator(expr, ctx);
	raw = deparse_expression(m, deparse_context_for(alias, base), true, false);
	initStringInfo(&out);
	for (char *c = raw; *c; c++)
	{
		if (*c == '$' && isdigit((unsigned char) c[1]))
		{
			char	   *end;
			long		n = strtol(c + 1, &end, 10);

			if (n > 10000)
			{
				appendStringInfo(&out, "gn_x.%s", quote_identifier(get_attname(base, (AttrNumber) (n - 10000), false)));
				c = end - 1;
				continue;
			}
		}
		appendStringInfoChar(&out, *c);
	}
	return out.data;
}

static void
json_str(StringInfo s, const char *key, const char *val, bool comma)
{
	if (comma)
		appendStringInfoChar(s, ',');
	escape_json(s, key);
	appendStringInfoChar(s, ':');
	escape_json(s, val);
}

static void
rewrite_on_conflict(Query *q, Oid base)
{
	OnConflictExpr *oc = q->onConflict;
	List	   *arb = NIL;
	ListCell   *lc;
	StringInfoData spec;
	StringInfoData arbx;
	Oid			argtypes[3] = {TEXTOID, TEXTOID, BOOLOID};
	Oid			setcfg;
	FuncExpr   *call;
	NullTest   *nt;
	UpsertCtx	ctx = {q->resultRelation, oc->exclRelIndex};
	UpsertCtx	actx = {q->resultRelation, 0};
	bool		first;

	initStringInfo(&arbx);
	foreach(lc, oc->arbiterElems)
	{
		InferenceElem *ie = lfirst_node(InferenceElem, lc);

		if (IsA(ie->expr, Var))
			arb = lappend_int(arb, ((Var *) ie->expr)->varattno);
		else
		{
			/* an expression index: the existing row v and the proposed row p compared by it */
			if (arbx.len > 0)
				appendStringInfoChar(&arbx, ',');
			appendStringInfoChar(&arbx, '{');
			json_str(&arbx, "v", upsert_deparse((Node *) ie->expr, base, "v", &actx), false);
			json_str(&arbx, "p", upsert_deparse((Node *) ie->expr, base, "p", &actx), true);
			appendStringInfoChar(&arbx, '}');
		}
	}
	if (OidIsValid(oc->constraint))
	{
		HeapTuple	tup = SearchSysCache1(CONSTROID, ObjectIdGetDatum(oc->constraint));

		if (HeapTupleIsValid(tup))
		{
			bool		isnull;
			Datum		d = SysCacheGetAttr(CONSTROID, tup, Anum_pg_constraint_conkey, &isnull);

			if (!isnull)
			{
				ArrayType  *a = DatumGetArrayTypeP(d);
				int16	   *keys = (int16 *) ARR_DATA_PTR(a);

				for (int i = 0; i < ARR_DIMS(a)[0]; i++)
					arb = lappend_int(arb, keys[i]);
			}
			ReleaseSysCache(tup);
		}
	}
	initStringInfo(&spec);
	appendStringInfoChar(&spec, '{');
	json_str(&spec, "action", oc->action == ONCONFLICT_NOTHING ? "nothing" : "update", false);
	appendStringInfoString(&spec, ",\"arbiter\":[");
	first = true;
	foreach(lc, arb)
	{
		if (!first)
			appendStringInfoChar(&spec, ',');
		escape_json(&spec, get_attname(base, lfirst_int(lc), false));
		first = false;
	}
	appendStringInfoChar(&spec, ']');
	if (arbx.len > 0)
		appendStringInfo(&spec, ",\"arbiter_exprs\":[%s]", arbx.data);
	if (oc->arbiterWhere != NULL)
		json_str(&spec, "pred", upsert_deparse(oc->arbiterWhere, base, "v", &actx), true);
	if (oc->action == ONCONFLICT_UPDATE)
	{
		appendStringInfoString(&spec, ",\"set\":{");
		first = true;
		foreach(lc, oc->onConflictSet)
		{
			TargetEntry *te = lfirst_node(TargetEntry, lc);

			if (te->resjunk)
				continue;
			if (!first)
				appendStringInfoChar(&spec, ',');
			escape_json(&spec, get_attname(base, te->resno, false));
			appendStringInfoChar(&spec, ':');
			escape_json(&spec, upsert_deparse((Node *) te->expr, base, "gn_t", &ctx));
			first = false;
		}
		appendStringInfoChar(&spec, '}');
		if (oc->onConflictWhere != NULL)
			json_str(&spec, "where", upsert_deparse(oc->onConflictWhere, base, "gn_t", &ctx), true);
	}
	appendStringInfoChar(&spec, '}');
	q->onConflict = NULL;

	setcfg = LookupFuncName(list_make1(makeString("set_config")), 3, argtypes, false);
	call = makeFuncExpr(setcfg, TEXTOID,
						list_make3(makeConst(TEXTOID, -1, DEFAULT_COLLATION_OID, -1, CStringGetTextDatum("gnomon._upsert"), false, false),
								   makeConst(TEXTOID, -1, DEFAULT_COLLATION_OID, -1, CStringGetTextDatum(spec.data), false, false),
								   makeBoolConst(true, false)),
						InvalidOid, DEFAULT_COLLATION_OID, COERCE_EXPLICIT_CALL);
	nt = makeNode(NullTest);
	nt->arg = (Expr *) call;
	nt->nulltesttype = IS_NOT_NULL;
	nt->argisrow = false;
	nt->location = -1;
	if (q->jointree->quals == NULL)
		q->jointree->quals = (Node *) nt;
	else
		q->jointree->quals = (Node *) makeBoolExpr(AND_EXPR, list_make2(nt, q->jointree->quals), -1);
	upsert_pending = true;
}

/*
 * Search views per query: a SELECT that reads one tracked table, with a restriction
 * whose operator is not leakproof and that an index of the table serves, reads the table's search
 * view (gnomon_q_<schema>) instead of its routing view, where PostgreSQL would not use the index
 * below the branch policy. Only on a logged branch without a schema version or a mask profile,
 * not in the past, and when the role may read the search view, which gnomon grants only to roles
 * that may read the table itself (never to confined or masked ones). Joins stay on the routing
 * views, whose join keys reach main's indexes.
 */
static bool
index_serves(Relation rel, AttrNumber att, Oid op)
{
	List	   *idx = RelationGetIndexList(rel);
	ListCell   *lc;
	bool		found = false;

	foreach(lc, idx)
	{
		Relation	ir = index_open(lfirst_oid(lc), AccessShareLock);

		for (int k = 0; k < ir->rd_index->indnkeyatts && !found; k++)
			if (ir->rd_index->indkey.values[k] == att && op_in_opfamily(op, ir->rd_opfamily[k]))
				found = true;
		index_close(ir, AccessShareLock);
		if (found)
			break;
	}
	list_free(idx);
	return found;
}

static bool
qual_wants_search(Node *qual, int rti, Relation rel)
{
	if (qual == NULL)
		return false;
	if (IsA(qual, BoolExpr) && ((BoolExpr *) qual)->boolop == AND_EXPR)
	{
		ListCell   *lc;

		foreach(lc, ((BoolExpr *) qual)->args)
			if (qual_wants_search(lfirst(lc), rti, rel))
				return true;
		return false;
	}
	if (IsA(qual, OpExpr) && list_length(((OpExpr *) qual)->args) == 2)
	{
		OpExpr	   *op = (OpExpr *) qual;
		Node	   *l = linitial(op->args);
		Node	   *r = lsecond(op->args);
		Oid			opno = op->opno;
		Var		   *v;

		if (IsA(l, RelabelType))
			l = (Node *) ((RelabelType *) l)->arg;
		if (IsA(r, RelabelType))
			r = (Node *) ((RelabelType *) r)->arg;
		if (IsA(r, Var) && !IsA(l, Var))
		{
			Node	   *t = l;

			l = r;
			r = t;
			opno = get_commutator(opno);
			if (!OidIsValid(opno))
				return false;
		}
		if (!IsA(l, Var))
			return false;
		v = (Var *) l;
		if (v->varno != rti || v->varlevelsup != 0 || v->varattno <= 0 ||
			contain_var_clause(r) || contain_volatile_functions(r))
			return false;
		if (get_func_leakproof(get_opcode(opno)))
			return false;		/* a leakproof operator reaches the index through the routing view */
		return index_serves(rel, v->varattno, opno);
	}
	return false;
}

static Oid
search_view_for(Query *q, int rti, Oid base, Oid view)
{
	ListCell   *lc;
	int			nrel = 0;
	char		buf[NAMEDATALEN * 2];
	char	   *nsp;
	Oid			qnsp;
	Oid			sv;
	Relation	rel;
	bool		wants;

	if (!search_auto || q->commandType != CMD_SELECT || q->rowMarks != NIL || q->setOperations != NULL ||
		q->jointree == NULL || list_length(q->jointree->fromlist) != 1 || setting_set("gnomon.as_of"))
		return InvalidOid;
	foreach(lc, q->rtable)
		if (lfirst_node(RangeTblEntry, lc)->rtekind == RTE_RELATION)
			nrel++;
	if (nrel != 1)
		return InvalidOid;
	nsp = get_namespace_name(get_rel_namespace(base));
	snprintf(buf, sizeof(buf), "gnomon_r_%s", nsp);
	if (strcmp(get_namespace_name(get_rel_namespace(view)), buf) != 0)
		return InvalidOid;		/* a scratch, versioned or masked routing schema */
	snprintf(buf, sizeof(buf), "gnomon_q_%s", nsp);
	qnsp = get_namespace_oid(buf, true);
	if (!OidIsValid(qnsp))
		return InvalidOid;
	sv = get_relname_relid(get_rel_name(base), qnsp);
	if (!OidIsValid(sv) || pg_class_aclcheck(sv, GetUserId(), ACL_SELECT) != ACLCHECK_OK)
		return InvalidOid;
	rel = RelationIdGetRelation(base);
	if (rel == NULL)
		return InvalidOid;
	wants = qual_wants_search(q->jointree->quals, rti, rel);
	RelationClose(rel);
	return wants ? sv : InvalidOid;
}

static void
route_query(Query *q, bool top)
{
	ListCell   *lc;
	int			rti = 0;
	List	   *keep_marks = NIL;
	bool		simple_select;

	foreach(lc, q->rtable)
	{
		RangeTblEntry *rte = lfirst_node(RangeTblEntry, lc);
		Oid			view;

		rti++;
		if (rte->rtekind != RTE_RELATION)
			continue;
		if (OidIsValid(routing_view_base(rte->relid)))
			continue;			/* already a routing view (search_path routing) */
		view = routed_relid(rte->relid);
		if (!OidIsValid(view))
			continue;
		if (has_dropped_columns(rte->relid))
		{
			ereport(WARNING, (errmsg("gnomon: %s has dropped columns and is not routed automatically",
									 get_rel_name(rte->relid)),
							  errhint("Use select gnomon.use(branch) so the routing schema is on the search path.")));
			continue;
		}
		{
			Oid			sv = search_view_for(q, rti, rte->relid, view);

			if (OidIsValid(sv))
			{
				view = sv;
				gn_count(GC_SEARCH_VIEWS);
			}
		}
		LockRelationOid(view, rte->rellockmode);
		rte->relid = view;
		rte->relkind = RELKIND_VIEW;
		rte->inh = false;
#if PG_VERSION_NUM >= 160000
		/* permissions live in RTEPermissionInfo from 16 on; before, in the RTE (relid, done above) */
		if (rte->perminfoindex > 0)
		{
			RTEPermissionInfo *pi = list_nth_node(RTEPermissionInfo, q->rteperminfos, rte->perminfoindex - 1);

			pi->relid = view;
		}
#endif
	}

	/* INSERT ... ON CONFLICT into a routing view */
	if (q->commandType == CMD_INSERT && q->onConflict != NULL && q->resultRelation > 0)
	{
		RangeTblEntry *rte = rt_fetch(q->resultRelation, q->rtable);
		Oid			base = routing_view_base(rte->relid);

		if (OidIsValid(base))
		{
			rewrite_on_conflict(q, base);
			gn_count(GC_UPSERTS);
		}
	}

	/* SELECT ... FOR UPDATE/SHARE: lock rows on the branch instead of the (lock-less) view */
	foreach(lc, q->rowMarks)
	{
		RowMarkClause *rc = lfirst_node(RowMarkClause, lc);
		RangeTblEntry *rte = rt_fetch(rc->rti, q->rtable);
		Oid			base = (rte->rtekind == RTE_RELATION) ? routing_view_base(rte->relid) : InvalidOid;

		if (OidIsValid(base) && q->commandType == CMD_SELECT)
		{
			if (q->hasAggs || q->groupClause != NIL || q->distinctClause != NIL || q->setOperations != NULL)
				ereport(ERROR, (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
								errmsg("FOR UPDATE with aggregation is not supported on gnomon branches")));
			q->targetList = lappend(q->targetList, row_call_tle(q, rc->rti, rte->relid, base, "_lock_row", "gnomon_lock"));
		}
		else
			keep_marks = lappend(keep_marks, rc);
	}
	q->rowMarks = keep_marks;
	q->hasForUpdate = keep_marks != NIL;

	/* read-set tracking on plain SELECTs */
	simple_select = q->commandType == CMD_SELECT && !q->hasAggs && q->groupClause == NIL &&
		q->distinctClause == NIL && q->setOperations == NULL && !q->hasWindowFuncs && q->havingQual == NULL;
	if (track_reads && top && simple_select)
	{
		rti = 0;
		foreach(lc, q->rtable)
		{
			RangeTblEntry *rte = lfirst_node(RangeTblEntry, lc);
			Oid			base;

			rti++;
			if (rte->rtekind != RTE_RELATION || !rte->inFromCl)
				continue;
			base = routing_view_base(rte->relid);
			if (OidIsValid(base))
				q->targetList = lappend(q->targetList, row_call_tle(q, rti, rte->relid, base, "_note_read", "gnomon_read"));
		}
	}
}

static bool route_walker(Node *node, void *ctx);

static bool
route_walker(Node *node, void *ctx)
{
	if (node == NULL)
		return false;
	if (IsA(node, Query))
	{
		Query	   *q = (Query *) node;

		route_query(q, ctx != NULL);
		return query_tree_walker(q, route_walker, NULL, 0);
	}
	return expression_tree_walker(node, route_walker, NULL);
}

static void
gnomon_post_parse_analyze(ParseState *pstate, Query *query, JumbleState *jstate)
{
	if (prev_post_parse_analyze)
		prev_post_parse_analyze(pstate, query, jstate);
	if (query->commandType == CMD_UTILITY)
		return;
	if (routing_active())
	{
		if (get_namespace_oid("gnomon", true) == InvalidOid)
			return;
		route_query(query, true);
		query_tree_walker(query, route_walker, NULL, 0);
	}
	if (point_enabled && substitute_enabled && !in_point_fallback && query->commandType == CMD_SELECT && IsTransactionState())
		point_rewrite(query);
}

/* ------------------------------------------------------------------------
 * TRUNCATE on a branch
 * ------------------------------------------------------------------------ */

/* ------------------------------------------------------------------------
 * Schema changes from a branch session
 *
 * DDL on a tracked table, and CREATE TABLE in a schema with tracked tables, goes to gnomon.ddl
 * when the session is on a branch: a migration tool that runs its own DDL changes the branch's
 * schema version, not main. gnomon's own DDL (gnomon._in_ddl, gnomon._ddl_internal, the pinned
 * search path of its functions), temporary tables and sessions on main pass through; what
 * gnomon.ddl does not take it refuses by name, as when called directly.
 * ------------------------------------------------------------------------ */

static bool in_ddl_redirect = false;

/*
 * The user's relation a name means: an unqualified name is looked up in the schemas of the path
 * that are not gnomon's (a branch session has its routing or version views first), a routing
 * view stands for its table.
 */
static Oid
user_relid(RangeVar *rv)
{
	Oid			r = InvalidOid;

	if (rv->schemaname != NULL)
		r = RangeVarGetRelid(rv, NoLock, true);
	else
	{
		List	   *path = fetch_search_path(false);
		ListCell   *lc;

		foreach(lc, path)
		{
			char	   *n = get_namespace_name(lfirst_oid(lc));

			if (n == NULL || is_gnomon_internal_namespace(n))
				continue;
			r = get_relname_relid(rv->relname, lfirst_oid(lc));
			if (OidIsValid(r))
				break;
		}
		list_free(path);
	}
	if (OidIsValid(r) && OidIsValid(routing_view_base(r)))
		r = routing_view_base(r);
	return r;
}

/* the relation a qualified name list names, or InvalidOid */
static Oid
names_relid(List *names)
{
	if (names == NIL)
		return InvalidOid;
	return user_relid(makeRangeVarFromNameList(names));
}

/*
 * The relations a statement changes and the schema it creates a table in, for the statements
 * gnomon.ddl takes; false for any other statement.
 */
static bool
ddl_targets(Node *parsetree, List **relids, Oid *create_nsp)
{
	*relids = NIL;
	*create_nsp = InvalidOid;
	switch (nodeTag(parsetree))
	{
		case T_CreateStmt:
			{
				CreateStmt *cs = (CreateStmt *) parsetree;

				if (cs->relation->relpersistence == RELPERSISTENCE_TEMP || cs->partbound != NULL || cs->inhRelations != NIL)
					return false;
				if (cs->relation->schemaname != NULL)
					*create_nsp = get_namespace_oid(cs->relation->schemaname, true);
				else
				{
					/* the schema the table is meant for: the first on the path that is not gnomon's
					 * (a branch session has the routing schemas first) */
					List	   *path = fetch_search_path(false);
					ListCell   *lc;

					foreach(lc, path)
					{
						char	   *n = get_namespace_name(lfirst_oid(lc));

						if (n != NULL && !is_gnomon_internal_namespace(n))
						{
							*create_nsp = lfirst_oid(lc);
							break;
						}
					}
					list_free(path);
				}
				return true;
			}
		case T_AlterTableStmt:
			{
				AlterTableStmt *as = (AlterTableStmt *) parsetree;

				if (as->objtype != OBJECT_TABLE)
					return false;
				*relids = list_make1_oid(user_relid(as->relation));
				return true;
			}
		case T_IndexStmt:
			*relids = list_make1_oid(user_relid(((IndexStmt *) parsetree)->relation));
			return true;
		case T_DropStmt:
			{
				DropStmt   *ds = (DropStmt *) parsetree;
				ListCell   *lc;

				if (ds->removeType != OBJECT_TABLE && ds->removeType != OBJECT_INDEX)
					return false;
				foreach(lc, ds->objects)
				{
					Oid			r = names_relid((List *) lfirst(lc));

					if (OidIsValid(r) && ds->removeType == OBJECT_INDEX)
						r = IndexGetRelation(r, true);
					*relids = lappend_oid(*relids, r);
				}
				return true;
			}
		case T_RenameStmt:
			{
				RenameStmt *rs = (RenameStmt *) parsetree;

				if (rs->relation == NULL || !(rs->renameType == OBJECT_COLUMN || rs->renameType == OBJECT_TABLE ||
											  rs->renameType == OBJECT_TABCONSTRAINT))
					return false;
				*relids = list_make1_oid(user_relid(rs->relation));
				return true;
			}
		case T_CommentStmt:
			{
				CommentStmt *cs = (CommentStmt *) parsetree;
				List	   *names;

				if (cs->objtype == OBJECT_TABLE)
					names = castNode(List, cs->object);
				else if (cs->objtype == OBJECT_COLUMN)
					names = list_truncate(list_copy(castNode(List, cs->object)), list_length(castNode(List, cs->object)) - 1);
				else
					return false;
				*relids = list_make1_oid(names_relid(names));
				return true;
			}
		default:
			return false;
	}
}

static bool
ddl_redirect(PlannedStmt *pstmt, const char *queryString, QueryCompletion *qc)
{
	Node	   *parsetree = pstmt->utilityStmt;
	const char *b = GetConfigOption("gnomon.branch", true, false);
	const char *internal = GetConfigOption("gnomon._ddl_internal", true, false);
	List	   *relids;
	Oid			create_nsp;
	Datum	   *elems;
	int			n = 0;
	ListCell   *lc;
	bool		hit = false;
	char	   *sql;
	int			loc = pstmt->stmt_location < 0 ? 0 : pstmt->stmt_location;

	if (in_ddl_redirect || !routing_active() || b == NULL || b[0] == '\0' || strcmp(b, "main") == 0 ||
		(internal != NULL && strcmp(internal, "1") == 0) || queryString == NULL)
		return false;
	if (!ddl_targets(parsetree, &relids, &create_nsp))
		return false;
	elems = palloc0(sizeof(Datum) * (list_length(relids) + 1));
	foreach(lc, relids)
		elems[n++] = ObjectIdGetDatum(lfirst_oid(lc));
	SPI_connect();
	{
		Oid			argtypes[2] = {OIDARRAYOID, OIDOID};
		Datum		values[2] = {PointerGetDatum(construct_array(elems, n, OIDOID, sizeof(Oid), true, TYPALIGN_INT)),
		ObjectIdGetDatum(create_nsp)};
		bool		isnull;

		if (SPI_execute_with_args("select exists (select 1 from gnomon.tracked t where t.rel = any($1))"
								  " or exists (select 1 from gnomon.tracked t join pg_catalog.pg_namespace n on n.nspname = t.nsp where n.oid = $2)",
								  2, argtypes, values, NULL, true, 1) != SPI_OK_SELECT || SPI_processed != 1)
			elog(ERROR, "gnomon: could not look up tracked tables");
		hit = DatumGetBool(SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &isnull)) && !isnull;
		if (hit)
		{
			Oid			argtypes1[1] = {TEXTOID};
			Datum		values1[1];

			sql = pstmt->stmt_len > 0 ? pnstrdup(queryString + loc, pstmt->stmt_len) : pstrdup(queryString + loc);
			values1[0] = CStringGetTextDatum(sql);
			in_ddl_redirect = true;
			gn_count(GC_DDL_REDIRECTS);
			PG_TRY();
			{
				if (SPI_execute_with_args("select gnomon.ddl($1)", 1, argtypes1, values1, NULL, false, 0) != SPI_OK_SELECT)
					elog(ERROR, "gnomon.ddl failed");
			}
			PG_FINALLY();
			{
				in_ddl_redirect = false;
			}
			PG_END_TRY();
		}
	}
	SPI_finish();
	if (hit && qc)
		SetQueryCompletion(qc, CreateCommandTag(parsetree), 0);
	return hit;
}

static void
gnomon_process_utility(PlannedStmt *pstmt, const char *queryString, bool readOnlyTree,
					   ProcessUtilityContext context, ParamListInfo params,
					   QueryEnvironment *queryEnv, DestReceiver *dest, QueryCompletion *qc)
{
	Node	   *parsetree = pstmt->utilityStmt;

	if (ddl_redirect(pstmt, queryString, qc))
		return;

	if (IsA(parsetree, TruncateStmt) && routing_active())
	{
		TruncateStmt *ts = (TruncateStmt *) parsetree;
		ListCell   *lc;
		List	   *bases = NIL;

		foreach(lc, ts->relations)
		{
			RangeVar   *rv = lfirst_node(RangeVar, lc);
			Oid			relid = RangeVarGetRelid(rv, AccessShareLock, false);
			Oid			base = routing_view_base(relid);

			if (!OidIsValid(base) && OidIsValid(routed_relid(relid)))
				base = routing_view_base(routed_relid(relid));
			if (!OidIsValid(base))
			{
				if (OidIsValid(routed_relid(relid)) || get_rel_relkind(relid) == RELKIND_VIEW)
					ereport(ERROR, (errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
									errmsg("untracked table \"%s\" refuses writes from a branch", rv->relname)));
				bases = NIL;
				break;
			}
			bases = lappend_oid(bases, base);
		}
		if (bases != NIL)
		{
			SPI_connect();
			foreach(lc, bases)
			{
				Oid			argtypes[1] = {REGCLASSOID};
				Datum		values[1] = {ObjectIdGetDatum(lfirst_oid(lc))};

				if (SPI_execute_with_args("select gnomon.truncate($1)", 1, argtypes, values, NULL, false, 0) != SPI_OK_SELECT)
					elog(ERROR, "gnomon.truncate failed");
			}
			SPI_finish();
			if (qc)
				SetQueryCompletion(qc, CMDTAG_TRUNCATE_TABLE, 0);
			return;
		}
	}
	/*
	 * COPY names a table, so with routing on it reaches the branch like any other statement: COPY
	 * FROM goes into the routing view (its INSTEAD OF trigger writes the branch; a pass-through
	 * view of an untracked table refuses it), and COPY TO, which takes no view, reads
	 * COPY (SELECT ... FROM the routing view) instead.
	 */
	if (IsA(parsetree, CopyStmt) && routing_active() && ((CopyStmt *) parsetree)->relation != NULL)
	{
		CopyStmt   *cs = (CopyStmt *) parsetree;
		Oid			relid = RangeVarGetRelid(cs->relation, AccessShareLock, true);
		Oid			rv = OidIsValid(relid) && get_rel_relkind(relid) != RELKIND_VIEW ? routed_relid(relid) : InvalidOid;

		if (OidIsValid(rv))
		{
			char	   *rvnsp = get_namespace_name(get_rel_namespace(rv));
			char	   *rvname = get_rel_name(rv);

			pstmt = copyObject(pstmt);
			cs = (CopyStmt *) pstmt->utilityStmt;
			if (cs->is_from)
				cs->relation = makeRangeVar(rvnsp, rvname, cs->relation->location);
			else
			{
				StringInfoData sql;
				List	   *raw;
				ListCell   *lc;

				initStringInfo(&sql);
				appendStringInfoString(&sql, "SELECT ");
				if (cs->attlist == NIL)
					appendStringInfoString(&sql, "*");
				foreach(lc, cs->attlist)
				{
					if (lc != list_head(cs->attlist))
						appendStringInfoString(&sql, ", ");
					appendStringInfoString(&sql, quote_identifier(strVal(lfirst(lc))));
				}
				appendStringInfo(&sql, " FROM %s", quote_qualified_identifier(rvnsp, rvname));
				raw = raw_parser(sql.data, RAW_PARSE_DEFAULT);
				cs->query = linitial_node(RawStmt, raw)->stmt;
				cs->relation = NULL;
				cs->attlist = NIL;
			}
			readOnlyTree = false;
		}
	}
	/*
	 * CREATE VIEW analyzes its query through the parse-analysis hook too, and stores it: a view
	 * must never keep the point read's internal function (nor its raw OIDs, which a dump cannot
	 * carry), so the rewrite is off while one is defined.
	 */
	if (IsA(parsetree, ViewStmt))
	{
		bool		prev = in_point_fallback;

		in_point_fallback = true;
		PG_TRY();
		{
			if (prev_process_utility)
				prev_process_utility(pstmt, queryString, readOnlyTree, context, params, queryEnv, dest, qc);
			else
				standard_ProcessUtility(pstmt, queryString, readOnlyTree, context, params, queryEnv, dest, qc);
		}
		PG_FINALLY();
		{
			in_point_fallback = prev;
		}
		PG_END_TRY();
		return;
	}
	if (prev_process_utility)
		prev_process_utility(pstmt, queryString, readOnlyTree, context, params, queryEnv, dest, qc);
	else
		standard_ProcessUtility(pstmt, queryString, readOnlyTree, context, params, queryEnv, dest, qc);
}

/* ------------------------------------------------------------------------
 * Executor hooks: nesting level, and clearing the upsert spec after the outer statement
 * ------------------------------------------------------------------------ */

static void report_epoch_lookup(void);

static void
gnomon_executor_start(QueryDesc *queryDesc, int eflags)
{
	exec_nesting++;
	if (report_coordinate && report_epoch < 0 && exec_nesting == 1 && ActiveSnapshotSet() && !RecoveryInProgress())
		report_epoch_lookup();
	PG_TRY();
	{
		if (prev_executor_start)
			prev_executor_start(queryDesc, eflags);
		else
			standard_ExecutorStart(queryDesc, eflags);
	}
	PG_CATCH();
	{
		exec_nesting--;
		PG_RE_THROW();
	}
	PG_END_TRY();
}

/*
 * The coordinate a statement read (for exact replay): with gnomon.report_coordinate on, each
 * top-level statement's snapshot, in gnomon.coord_text's form, goes into gnomon.last_coordinate, a
 * reported setting, so the client gets it with the statement's result (ParameterStatus) and can
 * replay the read exactly through gnomon.as_of. Primary only, like every coordinate.
 */

static uint64
widen_xid(TransactionId xid, FullTransactionId next)
{
	uint32		epoch = EpochFromFullTransactionId(next);

	if (!TransactionIdIsNormal(xid))
		return (uint64) xid;
	if (xid > XidFromFullTransactionId(next))
		epoch--;
	return ((uint64) epoch << 32) | xid;
}

static int
cmp_uint64(const void *a, const void *b)
{
	uint64		x = *(const uint64 *) a;
	uint64		y = *(const uint64 *) b;

	return x < y ? -1 : (x > y ? 1 : 0);
}

/* gnomon's cluster epoch for gnomon.last_coordinate, once per session (it holds for its life) */
static void
report_epoch_lookup(void)
{
	const char *e = GetConfigOption("gnomon._epoch", true, false);

	if (e != NULL && e[0] != '\0')
	{
		report_epoch = atoi(e);
		return;
	}
	if (get_namespace_oid("gnomon", true) == InvalidOid || SPI_connect() != SPI_OK_CONNECT)
		return;
	if (SPI_execute("select gnomon._epoch_ro()", true, 1) == SPI_OK_SELECT && SPI_processed == 1)
	{
		bool		isnull;
		Datum		d = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &isnull);

		if (!isnull)
			report_epoch = DatumGetInt16(d);
	}
	SPI_finish();
}

static char *
statement_coordinate(Snapshot snap)
{
	FullTransactionId next = ReadNextFullTransactionId();
	StringInfoData buf;
	uint64	   *xips;
	XLogRecPtr	lsn = GetXLogInsertRecPtr();
	int			n = 0;

	initStringInfo(&buf);
	appendStringInfo(&buf, "e%d:" UINT64_FORMAT ":" UINT64_FORMAT ":", report_epoch,
					 widen_xid(snap->xmin, next), widen_xid(snap->xmax, next));
	xips = palloc(sizeof(uint64) * Max(snap->xcnt, 1));
	for (int i = 0; i < snap->xcnt; i++)
		xips[n++] = widen_xid(snap->xip[i], next);
	qsort(xips, n, sizeof(uint64), cmp_uint64);
	for (int i = 0; i < n; i++)
	{
		if (i > 0 && xips[i] == xips[i - 1])
			continue;
		appendStringInfo(&buf, "%s" UINT64_FORMAT, i > 0 ? "," : "", xips[i]);
	}
	appendStringInfo(&buf, "@%X/%X", LSN_FORMAT_ARGS(lsn));
	return buf.data;
}

static void
gnomon_executor_end(QueryDesc *queryDesc)
{
	char	   *coord = NULL;

	if (report_coordinate && exec_nesting == 1 && queryDesc->snapshot != NULL && IsMVCCSnapshot(queryDesc->snapshot)
		&& !RecoveryInProgress() && IsTransactionState())
	{
		if (report_epoch >= 0)
			coord = statement_coordinate(queryDesc->snapshot);
	}
	if (prev_executor_end)
		prev_executor_end(queryDesc);
	else
		standard_ExecutorEnd(queryDesc);
	if (coord != NULL)
		SetConfigOption("gnomon.last_coordinate", coord, PGC_INTERNAL, PGC_S_OVERRIDE);
	exec_nesting--;
	if (exec_nesting <= 0)
	{
		exec_nesting = 0;
		if (upsert_pending || setting_set("gnomon._upsert"))
		{
			(void) set_config_option("gnomon._upsert", "", PGC_USERSET, PGC_S_SESSION, GUC_ACTION_LOCAL, true, 0, false);
			if (setting_set("gnomon._upsert_excl"))
				(void) set_config_option("gnomon._upsert_excl", "", PGC_USERSET, PGC_S_SESSION, GUC_ACTION_LOCAL, true, 0, false);
			upsert_pending = false;
		}
	}
}

static void
xact_callback(XactEvent event, void *arg)
{
	if (event == XACT_EVENT_ABORT || event == XACT_EVENT_COMMIT)
	{
		exec_nesting = 0;
		upsert_pending = false;
	}
}

/* ------------------------------------------------------------------------
 * Background worker: gnomon.heartbeat() every heartbeat_interval in each listed database
 * ------------------------------------------------------------------------ */

void
gnomon_worker_main(Datum arg)
{
	char		dbname[BGW_EXTRALEN];

	strlcpy(dbname, MyBgworkerEntry->bgw_extra, sizeof(dbname));
	pqsignal(SIGHUP, SignalHandlerForConfigReload);
	pqsignal(SIGTERM, die);
	BackgroundWorkerUnblockSignals();
	BackgroundWorkerInitializeConnection(dbname, NULL, 0);
	pgstat_report_appname("gnomon heartbeat");

	for (;;)
	{
		int			rc;

		CHECK_FOR_INTERRUPTS();
		if (ConfigReloadPending)
		{
			ConfigReloadPending = false;
			ProcessConfigFile(PGC_SIGHUP);
		}
		/*
		 * One beat per transaction. An error in it (the extension being dropped or created
		 * under us, a transient I/O error) is reported and the next beat comes as usual: a
		 * worker that exited would leave ticks and scheduled changes waiting for its restart.
		 * FATAL errors and shutdown still end the worker.
		 */
		PG_TRY();
		{
			SetCurrentStatementStartTimestamp();
			StartTransactionCommand();
			SPI_connect();
			PushActiveSnapshot(GetTransactionSnapshot());
			pgstat_report_activity(STATE_RUNNING, "select gnomon.heartbeat()");
			if (SPI_execute("select 1 from pg_extension where extname = 'gnomon'", true, 1) == SPI_OK_SELECT &&
				SPI_processed == 1)
				SPI_execute("select gnomon.heartbeat()", false, 0);
			SPI_finish();
			PopActiveSnapshot();
			CommitTransactionCommand();
		}
		PG_CATCH();
		{
			HOLD_INTERRUPTS();
			EmitErrorReport();
			AbortCurrentTransaction();
			FlushErrorState();
			MemoryContextSwitchTo(TopMemoryContext);
			RESUME_INTERRUPTS();
		}
		PG_END_TRY();
		pgstat_report_stat(true);
		pgstat_report_activity(STATE_IDLE, NULL);

		rc = WaitLatch(MyLatch, WL_LATCH_SET | WL_TIMEOUT | WL_EXIT_ON_PM_DEATH,
					   heartbeat_interval_ms, PG_WAIT_EXTENSION);
		if (rc & WL_LATCH_SET)
			ResetLatch(MyLatch);
	}
}

static void
register_workers(void)
{
	char	   *list;
	char	   *tok;
	char	   *save = NULL;

	if (heartbeat_databases == NULL || heartbeat_databases[0] == '\0')
		return;
	list = pstrdup(heartbeat_databases);
	for (tok = strtok_r(list, ", ", &save); tok != NULL; tok = strtok_r(NULL, ", ", &save))
	{
		BackgroundWorker w;

		memset(&w, 0, sizeof(w));
		w.bgw_flags = BGWORKER_SHMEM_ACCESS | BGWORKER_BACKEND_DATABASE_CONNECTION;
		w.bgw_start_time = BgWorkerStart_RecoveryFinished;
		w.bgw_restart_time = 10;
		strlcpy(w.bgw_library_name, "gnomon_c", BGW_MAXLEN);
		strlcpy(w.bgw_function_name, "gnomon_worker_main", BGW_MAXLEN);
		snprintf(w.bgw_name, BGW_MAXLEN, "gnomon heartbeat %s", tok);
		strlcpy(w.bgw_type, "gnomon heartbeat", BGW_MAXLEN);
		strlcpy(w.bgw_extra, tok, BGW_EXTRALEN);
		RegisterBackgroundWorker(&w);
	}
}

/* ------------------------------------------------------------------------
 * C versioning trigger: the storage semantics of the generated PL/pgSQL row
 * trigger (src/sql/30_storage.sql) with plans prepared once per table and change masks in C.
 * ------------------------------------------------------------------------ */

typedef struct ValCol
{
	AttrNumber	attnum;
	int			slot;
	Oid			typid;
	bool		large;
} ValCol;

typedef struct TableInfo
{
	Oid			relid;			/* hash key */
	bool		valid;
	int			nkeys;
	AttrNumber *keyatt;
	Oid		   *keytyp;
	int			nvals;
	ValCol	   *vals;
	int			nslots;
	int			nlarge;
	int64		part_span;
	int64		track_key;
	int64		track_xid;
	Oid			track_role;
	int			blob_threshold;
	SPIPlanPtr	probe;			/* latest version in a partition: flags, mask */
	SPIPlanPtr	anyv;			/* latest version anywhere: key, xoff, lsn, role */
	SPIPlanPtr	ins;			/* insert one version */
	SPIPlanPtr	blob;			/* _gnomon.blob_put */
	char	   *base;			/* storage name prefix */
	char	   *probe_sql;		/* SQL templates with %s for the version relation */
	char	   *ins_sql;
	Oid		   *probe_types;
	Oid		   *ins_types;
	int			ins_nargs;
	int32		leaf_part;		/* partition the leaf plans target, or -1 */
	SPIPlanPtr	probe_leaf;
	SPIPlanPtr	ins_leaf;
	char	  **ins_cols;		/* the insert's columns, by name, in parameter order */
	Oid			leaf_oid;		/* that leaf, for direct inserts (InvalidOid: use the SPI plan) */
	AttrNumber *leaf_att;		/* parameter -> the leaf's attribute number */
	Oid			vrel;			/* the version table (partitioned) */
	int			nleaves;		/* its leaves with their (keys, gn_key, gn_lsn) index, newest first; -1: not loaded */
	struct VLeaf *leaves;
	struct WcState *wc;			/* the current leaf, open for this transaction (wc_get) */
	uint64		wc_gen;			/* wc_gen when wc was opened */
	int64		wm_key;			/* the last key wm_note recorded for this table */
	/*
	 * What a transaction needs to open the current leaf that holds no lock or pin, kept for the
	 * session (lc_build): its indexes with their IndexInfo (expressions prepared once), the row
	 * index's equality functions, attribute numbers, and the insert slot. In lc_cxt; rebuilt with
	 * the TableInfo.
	 */
	Oid			lc_leaf;
	MemoryContext lc_cxt;
	int			lc_nidx;
	Oid		   *lc_idx;
	IndexInfo **lc_ii;
	int			lc_row;			/* which index is the row index */
	AttrNumber	lc_att[6];		/* gn_key, gn_xoff, gn_lsn, gn_role, gn_flags, gn_mask */
	FmgrInfo   *lc_eq;
	Oid		   *lc_eqtype;
	Oid		   *lc_eqcoll;
	TupleDesc	lc_desc;		/* a copy: slots made from it hold no tuple descriptor pin */
	TupleTableSlot *lc_slot;	/* the version to insert (virtual) */
} TableInfo;

typedef struct VLeaf
{
	int32		part;			/* PG_INT32_MAX for the default partition */
	Oid			heap;
	Oid			idx;
} VLeaf;

static HTAB *table_info = NULL;

/*
 * The current leaf, open for the rest of the statement that first wrote it: the leaf and its
 * indexes open for inserts (with the session's IndexInfos, so their access-method caches are built
 * once per statement, not per row) and a slot for probes. Its memory is a child of the statement's
 * (the trigger's fn_mcxt, the executor's query context), and a reset callback closes the leaf and
 * its indexes when the statement ends: DDL later in the transaction may alter or drop them, which
 * PostgreSQL refuses while this session holds a reference. The relcache references, locks and
 * buffer pins belong to wc_owner, a child of the transaction's resource owner, so a statement's
 * own resource owner never counts them as leaked; on (sub)transaction abort the owner releases
 * them, and the callback that runs later does nothing. The locks stay to commit, as any write's.
 */
typedef struct WcState
{
	Oid			leaf;
	uint64		gen;			/* wc_gen when opened */
	struct TableInfo *ti;		/* whose wc this is (TableInfo entries never move) */
	EState	   *estate;
	ResultRelInfo *rri;
	TupleTableSlot *pslot;		/* a probe's result (the leaf's own slot type) */
	Relation	idx;			/* the row index, one of rri's */
	MemoryContextCallback cb;	/* closes it when the statement's memory goes */
} WcState;

static ResourceOwner wc_owner = NULL;
static List *wc_open = NIL;		/* the open WcStates of this transaction (TopTransactionContext) */
static uint64 wc_gen = 1;		/* bumped whenever the open states are let go */
static MemoryContext wc_stmt_cxt = NULL;	/* the firing statement's memory (the trigger's fn_mcxt) */

static void
relcache_cb(Datum arg, Oid relid)
{
	HASH_SEQ_STATUS st;
	TableInfo  *ti;

	if (table_info == NULL)
		return;
	hash_seq_init(&st, table_info);
	while ((ti = hash_seq_search(&st)) != NULL)
		if (relid == InvalidOid || ti->relid == relid || (OidIsValid(ti->leaf_oid) && ti->leaf_oid == relid) ||
			(OidIsValid(ti->vrel) && ti->vrel == relid))
			ti->valid = false;
}

static char *
q_ident(const char *s)
{
	return (char *) quote_identifier(s);
}

static void
load_table_info(TableInfo *ti, Relation rel)
{
	Oid			argt[1] = {REGCLASSOID};
	Datum		argv[1] = {ObjectIdGetDatum(ti->relid)};
	char	   *vtab;
	StringInfoData sql;
	MemoryContext old;
	int			nv = 0;

	trig_spi();
	if (SPI_execute_with_args(
							  "select t.base, t.part_span, t.track_key, ((t.track_key & 281474976710655) - t.track_xoff), t.track_role, "
							  "t.blob_threshold, t.nslots, t.wide_key, t.id from gnomon.tracked t where t.rel = $1",
							  1, argt, argv, NULL, true, 1) != SPI_OK_SELECT || SPI_processed != 1)
		ereport(ERROR, (errmsg("gnomon: %s is not tracked", RelationGetRelationName(rel))));
	{
		HeapTuple	tup = SPI_tuptable->vals[0];
		TupleDesc	td = SPI_tuptable->tupdesc;
		bool		isnull;
		int32		tid;

		vtab = psprintf("_gnomon.%s", q_ident(psprintf("%s__v", SPI_getvalue(tup, td, 1))));
		ti->base = MemoryContextStrdup(TopMemoryContext, SPI_getvalue(tup, td, 1));
		ti->part_span = DatumGetInt64(SPI_getbinval(tup, td, 2, &isnull));
		ti->track_key = DatumGetInt64(SPI_getbinval(tup, td, 3, &isnull));
		ti->track_xid = DatumGetInt64(SPI_getbinval(tup, td, 4, &isnull));
		ti->track_role = DatumGetObjectId(SPI_getbinval(tup, td, 5, &isnull));
		ti->blob_threshold = DatumGetInt32(SPI_getbinval(tup, td, 6, &isnull));
		ti->nslots = DatumGetInt32(SPI_getbinval(tup, td, 7, &isnull));
		if (DatumGetBool(SPI_getbinval(tup, td, 8, &isnull)))
			ereport(ERROR, (errmsg("gnomon: the C trigger does not support wide keys (%s)", RelationGetRelationName(rel))));
		tid = DatumGetInt32(SPI_getbinval(tup, td, 9, &isnull));
		argv[0] = Int32GetDatum(tid);
		argt[0] = INT4OID;
	}
	if (SPI_execute_with_args("select c.num, c.slot, c.typoid, c.large, c.iskey from unnest(_gnomon.tcols($1)) c order by c.num",
							  1, argt, argv, NULL, false, 0) != SPI_OK_SELECT)
		elog(ERROR, "gnomon: cannot read columns");

	old = MemoryContextSwitchTo(TopMemoryContext);
	ti->keyatt = palloc(sizeof(AttrNumber) * SPI_processed);
	ti->keytyp = palloc(sizeof(Oid) * SPI_processed);
	ti->vals = palloc(sizeof(ValCol) * SPI_processed);
	ti->nkeys = 0;
	ti->nlarge = 0;
	for (uint64 i = 0; i < SPI_processed; i++)
	{
		HeapTuple	tup = SPI_tuptable->vals[i];
		TupleDesc	td = SPI_tuptable->tupdesc;
		bool		isnull;
		AttrNumber	att = DatumGetInt16(SPI_getbinval(tup, td, 1, &isnull));

		if (DatumGetBool(SPI_getbinval(tup, td, 5, &isnull)))
		{
			ti->keyatt[ti->nkeys] = att;
			ti->keytyp[ti->nkeys] = DatumGetObjectId(SPI_getbinval(tup, td, 3, &isnull));
			ti->nkeys++;
		}
		else
		{
			ti->vals[nv].attnum = att;
			ti->vals[nv].slot = DatumGetInt32(SPI_getbinval(tup, td, 2, &isnull));
			ti->vals[nv].typid = DatumGetObjectId(SPI_getbinval(tup, td, 3, &isnull));
			ti->vals[nv].large = DatumGetBool(SPI_getbinval(tup, td, 4, &isnull));
			if (ti->vals[nv].large)
				ti->nlarge++;
			nv++;
		}
	}
	ti->nvals = nv;
	MemoryContextSwitchTo(old);

	/* prepared statements */
	{
		int			np = ti->nkeys;
		Oid		   *types = palloc(sizeof(Oid) * (ti->nkeys + 8 + 2 * ti->nvals));
		StringInfoData where;

		initStringInfo(&where);
		for (int k = 0; k < ti->nkeys; k++)
		{
			appendStringInfo(&where, "%s%s = $%d", k ? " and " : "",
							 q_ident(get_attname(ti->relid, ti->keyatt[k], false)), k + 1);
			types[k] = ti->keytyp[k];
		}
		initStringInfo(&sql);
		appendStringInfo(&sql, "select gn_flags, gn_mask from %%s where %s and gn_part = $%d order by gn_key desc, gn_lsn desc limit 1",
						 where.data, np + 1);
		ti->probe_sql = MemoryContextStrdup(TopMemoryContext, sql.data);
		types[np] = INT4OID;
		ti->probe_types = MemoryContextAlloc(TopMemoryContext, sizeof(Oid) * (np + 1));
		memcpy(ti->probe_types, types, sizeof(Oid) * (np + 1));
		ti->probe = SPI_prepare(psprintf(ti->probe_sql, vtab), np + 1, types);
		SPI_keepplan(ti->probe);

		resetStringInfo(&sql);
		appendStringInfo(&sql, "select gn_key, gn_xoff, gn_lsn, gn_role from %s where %s order by gn_key desc, gn_lsn desc limit 1",
						 vtab, where.data);
		ti->anyv = SPI_prepare(sql.data, np, types);
		SPI_keepplan(ti->anyv);

		resetStringInfo(&sql);
		appendStringInfoString(&sql, "insert into %s (");
		for (int k = 0; k < ti->nkeys; k++)
			appendStringInfo(&sql, "%s, ", q_ident(get_attname(ti->relid, ti->keyatt[k], false)));
		appendStringInfoString(&sql, "gn_key, gn_xoff, gn_lsn, gn_role, gn_flags, gn_part, gn_mask");
		for (int v = 0; v < ti->nvals; v++)
		{
			appendStringInfo(&sql, ", gn_c%d", ti->vals[v].slot);
			if (ti->vals[v].large)
				appendStringInfo(&sql, ", gn_h%d", ti->vals[v].slot);
		}
		appendStringInfoString(&sql, ") values (");
		{
			int			p = 0;
			int			c = 0;

			ti->ins_cols = MemoryContextAlloc(TopMemoryContext, sizeof(char *) * (ti->nkeys + 7 + 2 * ti->nvals));
			for (int k = 0; k < ti->nkeys; k++)
				ti->ins_cols[c++] = MemoryContextStrdup(TopMemoryContext, get_attname(ti->relid, ti->keyatt[k], false));
			{
				static const char *const fixedn[7] = {"gn_key", "gn_xoff", "gn_lsn", "gn_role", "gn_flags", "gn_part", "gn_mask"};

				for (int f = 0; f < 7; f++)
					ti->ins_cols[c++] = MemoryContextStrdup(TopMemoryContext, fixedn[f]);
			}
			for (int v = 0; v < ti->nvals; v++)
			{
				ti->ins_cols[c++] = MemoryContextStrdup(TopMemoryContext, psprintf("gn_c%d", ti->vals[v].slot));
				if (ti->vals[v].large)
					ti->ins_cols[c++] = MemoryContextStrdup(TopMemoryContext, psprintf("gn_h%d", ti->vals[v].slot));
			}

			for (int k = 0; k < ti->nkeys; k++)
			{
				appendStringInfo(&sql, "%s$%d", p ? ", " : "", p + 1);
				types[p++] = ti->keytyp[k];
			}
			for (int s = 0; s < 7; s++)
			{
				static const Oid fixed[7] = {INT8OID, INT4OID, LSNOID, OIDOID, INT2OID, INT4OID, VARBITOID};

				appendStringInfo(&sql, ", $%d", p + 1);
				types[p++] = fixed[s];
			}
			for (int v = 0; v < ti->nvals; v++)
			{
				appendStringInfo(&sql, ", $%d", p + 1);
				types[p++] = ti->vals[v].typid;
				if (ti->vals[v].large)
				{
					appendStringInfo(&sql, ", $%d", p + 1);
					types[p++] = BYTEAOID;
				}
			}
			appendStringInfoChar(&sql, ')');
			ti->ins_sql = MemoryContextStrdup(TopMemoryContext, sql.data);
			ti->ins_types = MemoryContextAlloc(TopMemoryContext, sizeof(Oid) * p);
			memcpy(ti->ins_types, types, sizeof(Oid) * p);
			ti->ins_nargs = p;
			ti->ins = SPI_prepare(psprintf(ti->ins_sql, vtab), p, types);
			SPI_keepplan(ti->ins);
		}
		types[0] = TEXTOID;
		ti->blob = SPI_prepare("select _gnomon.blob_put($1)", 1, types);
		SPI_keepplan(ti->blob);
	}
	ti->leaf_part = -1;
	ti->probe_leaf = NULL;
	ti->ins_leaf = NULL;
	ti->leaf_oid = InvalidOid;
	ti->leaf_att = NULL;
	ti->vrel = get_relname_relid(psprintf("%s__v", ti->base), get_namespace_oid("_gnomon", false));
	ti->nleaves = -1;
	ti->leaves = NULL;
	ti->valid = true;
}

/* The version table's leaves and their row index, newest first (the default partition first). */
static void
load_leaves(TableInfo *ti)
{
	trig_spi();
	Oid			argt[1] = {TEXTOID};
	Datum		argv[1];

	argv[0] = CStringGetTextDatum(psprintf("_gnomon.%s", q_ident(psprintf("%s__v_row", ti->base))));
	ti->nleaves = 0;
	if (SPI_execute_with_args(
							  "select i.indrelid::oid, ci.inhrelid::oid, "
							  "coalesce(substring(pg_get_expr(c.relpartbound, c.oid) from 'FROM \\(([0-9-]+)\\)')::int, 2147483647) as part "
							  "from pg_inherits ci join pg_index i on i.indexrelid = ci.inhrelid join pg_class c on c.oid = i.indrelid "
							  "where ci.inhparent = to_regclass($1) order by part desc",
							  1, argt, argv, NULL, true, 0) != SPI_OK_SELECT)
		return;
	ti->leaves = MemoryContextAlloc(TopMemoryContext, sizeof(VLeaf) * Max(SPI_processed, 1));
	for (uint64 i = 0; i < SPI_processed; i++)
	{
		bool		isnull;
		HeapTuple	t = SPI_tuptable->vals[i];
		TupleDesc	td = SPI_tuptable->tupdesc;

		ti->leaves[i].heap = DatumGetObjectId(SPI_getbinval(t, td, 1, &isnull));
		ti->leaves[i].idx = DatumGetObjectId(SPI_getbinval(t, td, 2, &isnull));
		ti->leaves[i].part = DatumGetInt32(SPI_getbinval(t, td, 3, &isnull));
	}
	ti->nleaves = (int) SPI_processed;
}

/* The write-time partition of a version key (gnomon._part). */
static int32
gnomon_part_of(TableInfo *ti, int64 key)
{
	int64		ep = key >> 48;
	int64		raw = key & INT64CONST(281474976710655);

	return (int32) (ep * 1000000 + Min(raw / Max(ti->part_span, 1), 999999));
}

/* What a version lookup returns. */
typedef struct VFound
{
	bool		found;
	int64		key;
	int32		xoff;
	XLogRecPtr	lsn;
	Oid			role;
	int16		flags;
	Datum		mask;			/* copied; (Datum) 0 when null */
} VFound;

/*
 * The latest version of a key in one leaf: a backward scan of its (keys, gn_key, gn_lsn) index,
 * with the snapshot the caller took (a fresh one under READ COMMITTED, as the SPI path had).
 */
static void
latest_in_leaf(TableInfo *ti, const VLeaf *lf, Datum *keys, Snapshot snap, VFound *out)
{
	Relation	heap = table_open(lf->heap, AccessShareLock);
	Relation	idx = index_open(lf->idx, AccessShareLock);
	ScanKeyData sk[INDEX_MAX_KEYS];
	IndexScanDesc scan;
	TupleTableSlot *slot;
	TupleDesc	td = RelationGetDescr(heap);

	out->found = false;
	for (int k = 0; k < ti->nkeys; k++)
	{
		Oid			opno = get_opfamily_member(idx->rd_opfamily[k], idx->rd_opcintype[k], idx->rd_opcintype[k], BTEqualStrategyNumber);

		ScanKeyEntryInitialize(&sk[k], 0, k + 1, BTEqualStrategyNumber, idx->rd_opcintype[k],
							   idx->rd_indcollation[k], get_opcode(opno), keys[k]);
	}
#if PG_VERSION_NUM >= 180000
	scan = index_beginscan(heap, idx, snap, NULL, ti->nkeys, 0);
#else
	scan = index_beginscan(heap, idx, snap, ti->nkeys, 0);
#endif
	index_rescan(scan, sk, ti->nkeys, NULL, 0);
	slot = table_slot_create(heap, NULL);
	if (index_getnext_slot(scan, BackwardScanDirection, slot))
	{
		bool		isnull;
		Datum		m;

		out->found = true;
		out->key = DatumGetInt64(slot_getattr(slot, get_attnum(lf->heap, "gn_key"), &isnull));
		out->xoff = DatumGetInt32(slot_getattr(slot, get_attnum(lf->heap, "gn_xoff"), &isnull));
		out->lsn = DatumGetLSN(slot_getattr(slot, get_attnum(lf->heap, "gn_lsn"), &isnull));
		out->role = DatumGetObjectId(slot_getattr(slot, get_attnum(lf->heap, "gn_role"), &isnull));
		out->flags = DatumGetInt16(slot_getattr(slot, get_attnum(lf->heap, "gn_flags"), &isnull));
		m = slot_getattr(slot, get_attnum(lf->heap, "gn_mask"), &isnull);
		out->mask = isnull ? (Datum) 0 : datumCopy(m, false, -1);
	}
	(void) td;
	ExecDropSingleTupleTableSlot(slot);
	index_endscan(scan);
	index_close(idx, AccessShareLock);
	table_close(heap, AccessShareLock);
}

static Snapshot
fresh_snapshot(void)
{
	CommandCounterIncrement();	/* this transaction's own earlier versions are visible, as with SPI */
	return RegisterSnapshot(GetTransactionSnapshot());
}

/*
 * Let go of every open state. clean: before commit or prepare, with the states intact, so the
 * access methods' insert caches are cleaned up first. Otherwise (a subtransaction abort) the
 * resource owner alone releases what they hold. Locks pass to the transaction either way.
 */
static void
wc_release(bool clean)
{
	ResourceOwner save = CurrentResourceOwner;

	if (wc_owner != NULL)
	{
		CurrentResourceOwner = wc_owner;
#if PG_VERSION_NUM >= 170000
		if (clean)
		{
			ListCell   *lc;

			foreach(lc, wc_open)
			{
				WcState    *w = (WcState *) lfirst(lc);

				for (int i = 0; i < w->rri->ri_NumIndices; i++)
					if (w->rri->ri_IndexRelationDescs[i] != NULL)
						index_insert_cleanup(w->rri->ri_IndexRelationDescs[i], w->rri->ri_IndexRelationInfo[i]);
			}
		}
#endif
		ResourceOwnerRelease(wc_owner, RESOURCE_RELEASE_BEFORE_LOCKS, false, false);
		ResourceOwnerRelease(wc_owner, RESOURCE_RELEASE_LOCKS, true, false);
		ResourceOwnerRelease(wc_owner, RESOURCE_RELEASE_AFTER_LOCKS, false, false);
		CurrentResourceOwner = save;
		ResourceOwnerDelete(wc_owner);
		wc_owner = NULL;
	}
	wc_open = NIL;
	wc_gen++;
}

static void
wc_xact_cb(XactEvent event, void *arg)
{
	switch (event)
	{
		case XACT_EVENT_PRE_COMMIT:
		case XACT_EVENT_PARALLEL_PRE_COMMIT:
		case XACT_EVENT_PRE_PREPARE:
			wc_release(true);
			break;
		default:
			/* the transaction's resource owner releases wc_owner, a child, with it */
			wc_owner = NULL;
			wc_open = NIL;
			wc_gen++;
			break;
	}
}

static void
wc_subxact_cb(SubXactEvent event, SubTransactionId mySubid, SubTransactionId parentSubid, void *arg)
{
	if (event == SUBXACT_EVENT_ABORT_SUB)
		wc_release(false);
}

/*
 * The session part of the current leaf's state (TableInfo.lc_*), from the leaf rel (open, under
 * wc_owner): its index list with an IndexInfo each, expressions and predicates prepared here so no
 * transaction prepares them again; the row index's equality functions; attribute numbers; and a
 * copy of the row type. false: the leaf has an unexpected shape (callers keep the per-row paths).
 */
static bool
lc_build(TableInfo *ti, Relation rel, Oid ridx)
{
	static const char *const names[6] = {"gn_key", "gn_xoff", "gn_lsn", "gn_role", "gn_flags", "gn_mask"};
	MemoryContext cxt;
	MemoryContext old;
	List	   *il;
	ListCell   *lc;
	int			i = 0;
	bool		ok = true;

	/* the previous cache may back this transaction's open states: it goes with the transaction */
	if (ti->lc_cxt != NULL)
		MemoryContextSetParent(ti->lc_cxt, TopTransactionContext);
	ti->lc_cxt = NULL;
	ti->lc_leaf = InvalidOid;
	cxt = AllocSetContextCreate(TopMemoryContext, "gnomon leaf cache", ALLOCSET_SMALL_SIZES);
	old = MemoryContextSwitchTo(cxt);
	il = RelationGetIndexList(rel);
	ti->lc_nidx = list_length(il);
	ti->lc_idx = palloc(sizeof(Oid) * Max(ti->lc_nidx, 1));
	ti->lc_ii = palloc(sizeof(IndexInfo *) * Max(ti->lc_nidx, 1));
	ti->lc_eq = palloc(sizeof(FmgrInfo) * Max(ti->nkeys, 1));
	ti->lc_eqtype = palloc(sizeof(Oid) * Max(ti->nkeys, 1));
	ti->lc_eqcoll = palloc(sizeof(Oid) * Max(ti->nkeys, 1));
	ti->lc_row = -1;
	foreach(lc, il)
	{
		Oid			io = lfirst_oid(lc);
		Relation	ir = index_open(io, RowExclusiveLock);
		IndexInfo  *ii = BuildIndexInfo(ir);

		if (ii->ii_Expressions != NIL)
		{
			List	   *states = NIL;
			ListCell   *e;

			foreach(e, ii->ii_Expressions)
				states = lappend(states, ExecInitExpr(expression_planner((Expr *) lfirst(e)), NULL));
			ii->ii_ExpressionsState = states;
		}
		if (ii->ii_Predicate != NIL)
			ii->ii_PredicateState = ExecInitQual((List *) expression_planner((Expr *) ii->ii_Predicate), NULL);
		if (io == ridx)
		{
			ti->lc_row = i;
			ok = ir->rd_index->indnkeyatts >= ti->nkeys;
			for (int k = 0; k < ti->nkeys && ok; k++)
			{
				Oid			opno = get_opfamily_member(ir->rd_opfamily[k], ir->rd_opcintype[k],
													   ir->rd_opcintype[k], BTEqualStrategyNumber);

				ok = OidIsValid(opno);
				if (ok)
				{
					fmgr_info_cxt(get_opcode(opno), &ti->lc_eq[k], cxt);
					ti->lc_eqtype[k] = ir->rd_opcintype[k];
					ti->lc_eqcoll[k] = ir->rd_indcollation[k];
				}
			}
		}
		ti->lc_idx[i] = io;
		ti->lc_ii[i++] = ii;
		index_close(ir, NoLock);	/* (each transaction opens its own; the lock stays) */
	}
	for (int a = 0; a < 6 && ok; a++)
	{
		ti->lc_att[a] = get_attnum(RelationGetRelid(rel), names[a]);
		ok = ti->lc_att[a] != InvalidAttrNumber;
	}
	ti->lc_desc = CreateTupleDescCopy(RelationGetDescr(rel));
	ti->lc_slot = MakeSingleTupleTableSlot(ti->lc_desc, &TTSOpsVirtual);
	MemoryContextSwitchTo(old);
	if (!ok || ti->lc_row < 0)
	{
		MemoryContextDelete(cxt);
		return false;
	}
	ti->lc_cxt = cxt;
	ti->lc_leaf = RelationGetRelid(rel);
	return true;
}

/*
 * The end of the statement that opened w: close the leaf and its indexes, keeping their locks.
 * When the (sub)transaction ended first, its resource owner has let go of everything already.
 */
static void
wc_stmt_end(void *arg)
{
	WcState    *w = (WcState *) arg;
	ResourceOwner save;

	if (w->ti->wc == w)
		w->ti->wc = NULL;
	if (w->gen != wc_gen || wc_owner == NULL)
		return;
	save = CurrentResourceOwner;
	CurrentResourceOwner = wc_owner;
	for (int i = 0; i < w->rri->ri_NumIndices; i++)
	{
#if PG_VERSION_NUM >= 170000
		index_insert_cleanup(w->rri->ri_IndexRelationDescs[i], w->rri->ri_IndexRelationInfo[i]);
#endif
		index_close(w->rri->ri_IndexRelationDescs[i], NoLock);
	}
	table_close(w->rri->ri_RelationDesc, NoLock);
	CurrentResourceOwner = save;
	wc_open = list_delete_ptr(wc_open, w);
}

/* The current leaf's open state, opened on first use in the statement; NULL: use the per-row
 * paths (no leaf for the partition, or one of an unexpected shape). */
static WcState *
wc_get(TableInfo *ti)
{
	WcState    *w = ti->wc;
	Oid			ridx = InvalidOid;
	Relation	rel;
	MemoryContext old;
	ResourceOwner save;

	if (w != NULL && ti->wc_gen == wc_gen && w->gen == wc_gen && w->leaf == ti->leaf_oid)
		return w;
	ti->wc = NULL;
	w = NULL;
	if (!OidIsValid(ti->leaf_oid))
		return NULL;
	if (ti->nleaves < 0)
		load_leaves(ti);
	for (int i = 0; i < ti->nleaves; i++)
		if (ti->leaves[i].heap == ti->leaf_oid)
			ridx = ti->leaves[i].idx;
	if (!OidIsValid(ridx))
		return NULL;
	save = CurrentResourceOwner;
	if (wc_owner == NULL)
		wc_owner = ResourceOwnerCreate(TopTransactionResourceOwner, "gnomon trigger");
	old = MemoryContextSwitchTo(TopTransactionContext);
	CurrentResourceOwner = wc_owner;
	rel = try_table_open(ti->leaf_oid, RowExclusiveLock);
	/* (the lock may have brought invalidations: then the next row starts from a rebuilt TableInfo) */
	if (rel != NULL && ti->valid && (ti->lc_leaf == ti->leaf_oid || lc_build(ti, rel, ridx)))
	{
		MemoryContext cxt = AllocSetContextCreate(wc_stmt_cxt != NULL ? wc_stmt_cxt : TopTransactionContext,
												  "gnomon trigger leaf", ALLOCSET_SMALL_SIZES);

		MemoryContextSwitchTo(cxt);
		w = palloc0(sizeof(WcState));
		w->leaf = ti->leaf_oid;
		w->gen = wc_gen;
		w->ti = ti;
		w->estate = CreateExecutorState();
		w->rri = makeNode(ResultRelInfo);
		InitResultRelInfo(w->rri, rel, 1, NULL, 0);
		w->rri->ri_NumIndices = ti->lc_nidx;
		w->rri->ri_IndexRelationDescs = palloc(sizeof(Relation) * Max(ti->lc_nidx, 1));
		w->rri->ri_IndexRelationInfo = palloc(sizeof(IndexInfo *) * Max(ti->lc_nidx, 1));
		for (int i = 0; i < ti->lc_nidx; i++)
		{
			IndexInfo  *ii = ti->lc_ii[i];

			/* access-method caches (BRIN's revmap, with a pinned buffer) live for one statement */
			ii->ii_AmCache = NULL;
			ii->ii_Context = cxt;
			w->rri->ri_IndexRelationDescs[i] = index_open(ti->lc_idx[i], RowExclusiveLock);
			w->rri->ri_IndexRelationInfo[i] = ii;
		}
		w->idx = w->rri->ri_IndexRelationDescs[ti->lc_row];
		w->pslot = ExecInitExtraTupleSlot(w->estate, ti->lc_desc, table_slot_callbacks(rel));
		w->cb.func = wc_stmt_end;
		w->cb.arg = w;
		MemoryContextRegisterResetCallback(cxt, &w->cb);
		MemoryContextSwitchTo(TopTransactionContext);
		wc_open = lappend(wc_open, w);
	}
	else if (rel != NULL)
		table_close(rel, NoLock);	/* (no reference may outlive the statement) */
	CurrentResourceOwner = save;
	MemoryContextSwitchTo(old);
	ti->wc = w;
	ti->wc_gen = wc_gen;
	return w;
}

/* latest_in_leaf for the open current leaf */
static void
latest_in_wc(TableInfo *ti, WcState *w, Datum *keys, Snapshot snap, VFound *out)
{
	ScanKeyData sk[INDEX_MAX_KEYS];
	IndexScanDesc scan;
	TupleTableSlot *slot = w->pslot;
	ResourceOwner save = CurrentResourceOwner;

	out->found = false;
	for (int k = 0; k < ti->nkeys; k++)
		ScanKeyEntryInitializeWithInfo(&sk[k], 0, k + 1, BTEqualStrategyNumber, ti->lc_eqtype[k], ti->lc_eqcoll[k],
									   &ti->lc_eq[k], keys[k]);
	CurrentResourceOwner = wc_owner;
#if PG_VERSION_NUM >= 180000
	scan = index_beginscan(w->rri->ri_RelationDesc, w->idx, snap, NULL, ti->nkeys, 0);
#else
	scan = index_beginscan(w->rri->ri_RelationDesc, w->idx, snap, ti->nkeys, 0);
#endif
	index_rescan(scan, sk, ti->nkeys, NULL, 0);
	if (index_getnext_slot(scan, BackwardScanDirection, slot))
	{
		bool		isnull;
		Datum		m;

		out->found = true;
		out->key = DatumGetInt64(slot_getattr(slot, ti->lc_att[0], &isnull));
		out->xoff = DatumGetInt32(slot_getattr(slot, ti->lc_att[1], &isnull));
		out->lsn = DatumGetLSN(slot_getattr(slot, ti->lc_att[2], &isnull));
		out->role = DatumGetObjectId(slot_getattr(slot, ti->lc_att[3], &isnull));
		out->flags = DatumGetInt16(slot_getattr(slot, ti->lc_att[4], &isnull));
		m = slot_getattr(slot, ti->lc_att[5], &isnull);
		out->mask = isnull ? (Datum) 0 : datumCopy(m, false, -1);
	}
	ExecClearTuple(slot);		/* no buffer pin left between rows */
	index_endscan(scan);
	CurrentResourceOwner = save;
}


/* The latest version of a key in write-time partition part (and the default partition). */
static bool
probe_direct(TableInfo *ti, Datum *keys, int32 part, VFound *out)
{
	Snapshot	snap;
	VFound		d;
	WcState    *w;

	if (!direct_inserts)
		return false;
	if (ti->nleaves < 0)
		load_leaves(ti);
	out->found = false;
	/*
	 * The current partition's leaf, open for the transaction. With it attached the default
	 * partition holds no version of this partition: its constraint excludes the leaf's range.
	 */
	w = part == ti->leaf_part ? wc_get(ti) : NULL;
	snap = fresh_snapshot();
	if (w != NULL)
	{
		latest_in_wc(ti, w, keys, snap, out);
		UnregisterSnapshot(snap);
		return true;
	}
	for (int i = 0; i < ti->nleaves; i++)
	{
		const VLeaf *lf = &ti->leaves[i];

		if (lf->part != part && lf->part != PG_INT32_MAX)
			continue;
		latest_in_leaf(ti, lf, keys, snap, &d);
		/* the default partition holds versions of any partition number: only this one's count */
		if (d.found && lf->part == PG_INT32_MAX && gnomon_part_of(ti, d.key) != part)
			d.found = false;
		if (d.found && (!out->found || d.key > out->key || (d.key == out->key && d.lsn > out->lsn)))
			*out = d;
	}
	UnregisterSnapshot(snap);
	return true;
}

/* The latest version of a key below write-time partition part: leaves newest first, stopping at
 * the first that has one, plus the default partition (versions of any partition number). */
static bool
latest_before_direct(TableInfo *ti, Datum *keys, int32 part, VFound *out)
{
	Snapshot	snap;
	VFound		d;

	if (!direct_inserts)
		return false;
	if (ti->nleaves < 0)
		load_leaves(ti);
	out->found = false;
	snap = fresh_snapshot();
	for (int i = 0; i < ti->nleaves; i++)
	{
		const VLeaf *lf = &ti->leaves[i];

		if (lf->part != PG_INT32_MAX && lf->part >= part)
			continue;
		if (lf->part != PG_INT32_MAX && out->found && gnomon_part_of(ti, out->key) > lf->part)
			break;				/* found already, and nothing in older leaves can be newer */
		latest_in_leaf(ti, lf, keys, snap, &d);
		if (d.found && (!out->found || d.key > out->key || (d.key == out->key && d.lsn > out->lsn)))
			*out = d;
	}
	UnregisterSnapshot(snap);
	return true;
}

/* Plans that target the leaf partition of the current write-time partition, when it exists:
 * no tuple routing and no partition pruning per row. */
static void
use_leaf(TableInfo *ti, int32 part)
{
	Oid			nsp;
	char	   *leaf;

	if (ti->leaf_part == part)
		return;
	if (ti->probe_leaf)
	{
		SPI_freeplan(ti->probe_leaf);
		SPI_freeplan(ti->ins_leaf);
		ti->probe_leaf = ti->ins_leaf = NULL;
	}
	ti->leaf_part = part;
	ti->leaf_oid = InvalidOid;
	nsp = get_namespace_oid("_gnomon", false);
	leaf = psprintf("%s__v_p%d", ti->base, part);
	ti->leaf_oid = get_relname_relid(leaf, nsp);
	if (!OidIsValid(ti->leaf_oid))
		return;
	/* direct inserts: map the insert's columns to the leaf's attributes by name */
	if (ti->leaf_att == NULL)
		ti->leaf_att = MemoryContextAlloc(TopMemoryContext, sizeof(AttrNumber) * ti->ins_nargs);
	for (int p = 0; p < ti->ins_nargs; p++)
	{
		ti->leaf_att[p] = get_attnum(ti->leaf_oid, ti->ins_cols[p]);
		if (ti->leaf_att[p] == InvalidAttrNumber)
		{
			ti->leaf_oid = InvalidOid;	/* unexpected shape: keep to the SPI plan */
			break;
		}
	}
	leaf = psprintf("_gnomon.%s", q_ident(leaf));
	trig_spi();
	ti->probe_leaf = SPI_prepare(psprintf(ti->probe_sql, leaf), ti->nkeys + 1, ti->probe_types);
	SPI_keepplan(ti->probe_leaf);
	ti->ins_leaf = SPI_prepare(psprintf(ti->ins_sql, leaf), ti->ins_nargs, ti->ins_types);
	SPI_keepplan(ti->ins_leaf);
}

#define PROBE(ti) ((ti)->probe_leaf ? (ti)->probe_leaf : (ti)->probe)
#define INS(ti) ((ti)->ins_leaf ? (ti)->ins_leaf : (ti)->ins)

static TableInfo *
get_table_info(Relation rel)
{
	Oid			relid = RelationGetRelid(rel);
	TableInfo  *ti;
	bool		found;

	if (table_info == NULL)
	{
		HASHCTL		ctl;

		memset(&ctl, 0, sizeof(ctl));
		ctl.keysize = sizeof(Oid);
		ctl.entrysize = sizeof(TableInfo);
		table_info = hash_create("gnomon table info", 64, &ctl, HASH_ELEM | HASH_BLOBS);
	}
	ti = hash_search(table_info, &relid, HASH_ENTER, &found);
	if (!found || !ti->valid)
	{
		if (found && ti->probe)
		{
			SPI_freeplan(ti->probe);
			SPI_freeplan(ti->anyv);
			SPI_freeplan(ti->ins);
			SPI_freeplan(ti->blob);
			if (ti->probe_leaf)
			{
				SPI_freeplan(ti->probe_leaf);
				SPI_freeplan(ti->ins_leaf);
			}
		}
		/* the leaf cache may back this transaction's open states: it goes with the transaction */
		if (found && ti->lc_cxt != NULL)
			MemoryContextSetParent(ti->lc_cxt, TopTransactionContext);
		memset(((char *) ti) + sizeof(Oid), 0, sizeof(TableInfo) - sizeof(Oid));
		load_table_info(ti, rel);
	}
	return ti;
}

static int
current_epoch(void)
{
	const char *e = GetConfigOption("gnomon._epoch", true, false);

	if (e != NULL && e[0] != '\0')
		return atoi(e);
	trig_plans();
	if (SPI_execute("select gnomon.current_epoch()", false, 1) != SPI_OK_SELECT || SPI_processed != 1)
		elog(ERROR, "gnomon: cannot read the epoch");
	{
		bool		isnull;

		return DatumGetInt16(SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &isnull));
	}
}

/* A varbit of n bits, as varbit_in would build it from '0's and '1's (unused bits zero). */
static Datum
make_mask(const bool *bits, int n)
{
	int			len = VARBITTOTALLEN(n);
	VarBit	   *vb = (VarBit *) palloc0(len);
	bits8	   *p = VARBITS(vb);

	SET_VARSIZE(vb, len);
	VARBITLEN(vb) = n;
	for (int i = 0; i < n; i++)
		if (bits[i])
			p[i / 8] |= (bits8) (1 << (7 - i % 8));
	return VarBitPGetDatum(vb);
}

static void
read_mask(Datum d, bool *bits, int n)
{
	VarBit	   *vb = DatumGetVarBitP(d);
	int			len = VARBITLEN(vb);
	bits8	   *p = VARBITS(vb);

	for (int i = 0; i < n; i++)
		bits[i] = i < len ? ((p[i / 8] >> (7 - i % 8)) & 1) != 0 : false;
}

typedef struct Stamp
{
	int64		key;
	int32		xoff;
	XLogRecPtr	lsn;
	Oid			role;
	int32		part;
} Stamp;

static Stamp
take_stamp(TableInfo *ti, Oid role)
{
	Stamp		s;
	uint64		x = U64FromFullTransactionId(GetTopFullTransactionId());

	/*
	 * A fresh snapshot at every isolation level. Under REPEATABLE READ and
	 * SERIALIZABLE an INSERT can follow a concurrent, committed DELETE of the same key without a
	 * serialization error, and the transaction snapshot would order it before that delete.
	 */
	Snapshot	snap = IsolationUsesXactSnapshot() ? GetLatestSnapshot() : GetTransactionSnapshot();
	FullTransactionId next = ReadNextFullTransactionId();
	uint64		xmax = U64FromFullTransactionId(next) - (uint32) (XidFromFullTransactionId(next) - snap->xmax);
	uint64		raw = Max(x, xmax);
	int64		ep = current_epoch();

	s.key = (ep << 48) | (int64) raw;
	s.xoff = (int32) (raw - x);
	s.lsn = GetXLogInsertRecPtr();
	s.role = role;
	s.part = (int32) (ep * 1000000 + Min((int64) raw / Max(ti->part_span, 1), 999999));
	return s;
}

/*
 * Insert a version straight into the current partition's leaf: a heap insert and its index
 * entries, with no plan to start up. The leaf takes the row as given: its
 * partition is the one the stamp chose, and the values come from the tracked table itself.
 */
static bool
insert_direct(TableInfo *ti, Datum *vals, const char *nulls)
{
	Relation	rel;
	TupleDesc	td;
	EState	   *estate;
	ResultRelInfo *rri;
	TupleTableSlot *slot;
	WcState    *w;

	if (!OidIsValid(ti->leaf_oid))
	{
		elog(DEBUG1, "gnomon: no leaf for partition %d of %s: SPI insert", ti->leaf_part, ti->base);
		return false;
	}
	if ((w = wc_get(ti)) != NULL)
	{
		ResourceOwner save = CurrentResourceOwner;

		slot = ti->lc_slot;
		td = slot->tts_tupleDescriptor;
		ExecClearTuple(slot);
		for (int i = 0; i < td->natts; i++)
		{
			slot->tts_values[i] = (Datum) 0;
			slot->tts_isnull[i] = true;
		}
		for (int p = 0; p < ti->ins_nargs; p++)
		{
			AttrNumber	a = ti->leaf_att[p];

			slot->tts_values[a - 1] = vals[p];
			slot->tts_isnull[a - 1] = (nulls[p] == 'n');
		}
		ExecStoreVirtualTuple(slot);
		CurrentResourceOwner = wc_owner;
		table_tuple_insert(w->rri->ri_RelationDesc, slot, GetCurrentCommandId(true), 0, NULL);
#if PG_VERSION_NUM >= 160000
		(void) ExecInsertIndexTuples(w->rri, slot, w->estate, false, false, NULL, NIL, false);
#else
		(void) ExecInsertIndexTuples(w->rri, slot, w->estate, false, false, NULL, NIL);
#endif
		CurrentResourceOwner = save;
		ResetPerTupleExprContext(w->estate);
		ExecClearTuple(slot);	/* its values belong to the caller */
		return true;
	}
	rel = try_table_open(ti->leaf_oid, RowExclusiveLock);
	if (rel == NULL)
		return false;
	td = RelationGetDescr(rel);
	estate = CreateExecutorState();
	rri = makeNode(ResultRelInfo);
	InitResultRelInfo(rri, rel, 1, NULL, 0);
	ExecOpenIndices(rri, false);
	slot = ExecInitExtraTupleSlot(estate, td, &TTSOpsVirtual);
	ExecClearTuple(slot);
	for (int i = 0; i < td->natts; i++)
	{
		slot->tts_values[i] = (Datum) 0;
		slot->tts_isnull[i] = true;
	}
	for (int p = 0; p < ti->ins_nargs; p++)
	{
		AttrNumber	a = ti->leaf_att[p];

		slot->tts_values[a - 1] = vals[p];
		slot->tts_isnull[a - 1] = (nulls[p] == 'n');
	}
	ExecStoreVirtualTuple(slot);
	table_tuple_insert(rel, slot, GetCurrentCommandId(true), 0, NULL);
#if PG_VERSION_NUM >= 160000
	(void) ExecInsertIndexTuples(rri, slot, estate, false, false, NULL, NIL, false);
#else
	(void) ExecInsertIndexTuples(rri, slot, estate, false, false, NULL, NIL);
#endif
	ExecCloseIndices(rri);
	ExecDropSingleTupleTableSlot(slot);
	FreeExecutorState(estate);
	table_close(rel, NoLock);
	return true;
}

/* Insert one version: keys from tuple kt, values from vt (NULL for a tombstone). */
static void
insert_version(TableInfo *ti, TupleDesc desc, HeapTuple kt, HeapTuple vt, int64 key, int32 xoff,
			   XLogRecPtr lsn, Oid role, int16 flags, int32 part, const bool *mask, bool keyframe)
{
	int			np = ti->nkeys + 7 + ti->nvals + ti->nlarge;
	Datum	   *vals = palloc0(sizeof(Datum) * np);
	char	   *nulls = palloc(np);
	int			p = 0;
	bool	   *ones = palloc(sizeof(bool) * Max(ti->nslots, 1));

	memset(nulls, ' ', np);
	for (int k = 0; k < ti->nkeys; k++)
	{
		bool		isnull;

		vals[p] = heap_getattr(kt, ti->keyatt[k], desc, &isnull);
		nulls[p++] = isnull ? 'n' : ' ';
	}
	vals[p++] = Int64GetDatum(key);
	vals[p++] = Int32GetDatum(xoff);
	vals[p++] = LSNGetDatum(lsn);
	vals[p++] = ObjectIdGetDatum(role);
	vals[p++] = Int16GetDatum(flags);
	vals[p++] = Int32GetDatum(part);
	for (int i = 0; i < ti->nslots; i++)
		ones[i] = true;
	vals[p++] = make_mask(keyframe ? ones : mask, ti->nslots);
	for (int v = 0; v < ti->nvals; v++)
	{
		ValCol	   *c = &ti->vals[v];
		bool		present = vt != NULL && (keyframe || mask[c->slot]);
		bool		isnull = true;
		Datum		d = (Datum) 0;
		bool		to_blob = false;

		if (present)
			d = heap_getattr(vt, c->attnum, desc, &isnull);
		/* the value's own size, as the PL/pgSQL (BEFORE) trigger sees it: this AFTER trigger gets
		 * the stored, possibly compressed datum */
		if (present && !isnull && c->large && toast_raw_datum_size(d) > (Size) ti->blob_threshold)
			to_blob = true;
		vals[p] = d;
		nulls[p++] = (!present || isnull || to_blob) ? 'n' : ' ';
		if (c->large)
		{
			if (to_blob)
			{
				Oid			outf;
				bool		varlena;
				Datum		arg[1];
				bool		bnull;

				getTypeOutputInfo(c->typid, &outf, &varlena);
				arg[0] = CStringGetTextDatum(OidOutputFunctionCall(outf, d));
				trig_plans();
				if (SPI_execute_plan(ti->blob, arg, NULL, false, 1) != SPI_OK_SELECT)
					elog(ERROR, "gnomon: blob_put failed");
				vals[p] = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &bnull);
				vals[p] = datumCopy(vals[p], false, -1);
				nulls[p++] = bnull ? 'n' : ' ';
			}
			else
				nulls[p++] = 'n';
		}
	}
	if (direct_inserts && insert_direct(ti, vals, nulls))
		return;
	trig_plans();
	if (SPI_execute_plan(INS(ti), vals, nulls, false, 0) != SPI_OK_INSERT)
		elog(ERROR, "gnomon: version insert failed");
}

/* No version of the row in this partition yet: carry-forward keyframe or lazy baseline. */
static void
carry_forward(TableInfo *ti, TupleDesc desc, HeapTuple oldt, int32 part, int64 stkey)
{
	Datum	   *keys = palloc(sizeof(Datum) * ti->nkeys);
	char	   *knulls = palloc(ti->nkeys + 1);

	for (int k = 0; k < ti->nkeys; k++)
	{
		bool		isnull;

		keys[k] = heap_getattr(oldt, ti->keyatt[k], desc, &isnull);
		knulls[k] = isnull ? 'n' : ' ';
	}
	{
		VFound		f;

		if (latest_before_direct(ti, keys, part, &f))
		{
			if (f.found)
				insert_version(ti, desc, oldt, oldt, f.key, f.xoff, f.lsn, f.role, 24, part, NULL, true);
			else
			{
				int64		bk = Min(ti->track_key, stkey);

				insert_version(ti, desc, oldt, oldt, bk, (int32) ((bk & INT64CONST(281474976710655)) - ti->track_xid),
							   InvalidXLogRecPtr, ti->track_role, 40, part, NULL, true);
			}
			return;
		}
	}
	/* read_only = false: a fresh snapshot under READ COMMITTED, as a PL/pgSQL statement gets */
	trig_plans();
	if (SPI_execute_plan(ti->anyv, keys, knulls, false, 1) != SPI_OK_SELECT)
		elog(ERROR, "gnomon: version lookup failed");
	if (SPI_processed == 1)
	{
		HeapTuple	t = SPI_tuptable->vals[0];
		TupleDesc	td = SPI_tuptable->tupdesc;
		bool		isnull;
		int64		k = DatumGetInt64(SPI_getbinval(t, td, 1, &isnull));
		int32		x = DatumGetInt32(SPI_getbinval(t, td, 2, &isnull));
		XLogRecPtr	l = DatumGetLSN(SPI_getbinval(t, td, 3, &isnull));
		Oid			r = DatumGetObjectId(SPI_getbinval(t, td, 4, &isnull));

		insert_version(ti, desc, oldt, oldt, k, x, l, r, 24, part, NULL, true);
	}
	else
	{
		int64		bk = Min(ti->track_key, stkey);

		insert_version(ti, desc, oldt, oldt, bk, (int32) ((bk & INT64CONST(281474976710655)) - ti->track_xid),
					   InvalidXLogRecPtr, ti->track_role, 40, part, NULL, true);
	}
}

PG_FUNCTION_INFO_V1(gnomon_c_version_trigger);

Datum
gnomon_c_version_trigger(PG_FUNCTION_ARGS)
{
	TriggerData *td = (TriggerData *) fcinfo->context;
	Relation	rel;
	TupleDesc	desc;
	TableInfo  *ti;
	Oid			caller = GetUserId();
	Oid			save_user;
	int			save_sec;
	Oid			writer;
	Stamp		st;
	HeapTuple	oldt = NULL;
	HeapTuple	newt = NULL;
	bool		keys_same = true;
	int			save_nest;
	bool		save_in,
				save_on;
	MemoryContext save_stmt;

	if (!CALLED_AS_TRIGGER(fcinfo) || !TRIGGER_FIRED_AFTER(td->tg_event) || !TRIGGER_FIRED_FOR_ROW(td->tg_event))
		elog(ERROR, "_gnomon.c_version_trigger must be an AFTER ROW trigger");
	if (replorigin_session_origin != InvalidRepOriginId)
		return PointerGetDatum(NULL);
	{
		const char *er = GetConfigOption("gnomon._erasing", true, false);

		if (er != NULL && strcmp(er, "1") == 0)
			return PointerGetDatum(NULL);
	}
	/*
	 * A session on a branch, or reading the past, does not change main by naming its table (with
	 * routing on, such names reach the branch and never get here); gnomon's own writes to main
	 * carry a merge token, which sets gnomon._main_write. As _gnomon.main_write_refused.
	 */
	{
		const char *br = GetConfigOption("gnomon.branch", true, false);
		const char *ao = GetConfigOption("gnomon.as_of", true, false);
		const char *mw = GetConfigOption("gnomon._main_write", true, false);

		if (((br != NULL && br[0] != '\0' && strcmp(br, "main") != 0) || (ao != NULL && ao[0] != '\0')) &&
			!(mw != NULL && strcmp(mw, "1") == 0))
		{
			if (ao != NULL && ao[0] != '\0')
				ereport(ERROR,
						(errcode(ERRCODE_READ_ONLY_SQL_TRANSACTION),
						 errmsg("writes are refused while gnomon.as_of is set (reading the past is read-only): %s would change main now",
								RelationGetRelationName(td->tg_relation))));
			ereport(ERROR,
					(errcode(ERRCODE_READ_ONLY_SQL_TRANSACTION),
					 errmsg("this session is on branch \"%s\": a write to %s names main's table and would change main",
							br, RelationGetRelationName(td->tg_relation)),
					 errhint("Write the branch through its routing schema, or switch to main first.")));
		}
	}
	rel = td->tg_relation;
	desc = RelationGetDescr(rel);
	if (TRIGGER_FIRED_BY_INSERT(td->tg_event))
		newt = td->tg_trigtuple;
	else if (TRIGGER_FIRED_BY_DELETE(td->tg_event))
		oldt = td->tg_trigtuple;
	else
	{
		oldt = td->tg_trigtuple;
		newt = td->tg_newtuple;
	}

	{
		static Oid	writer_oid = InvalidOid;

		if (!OidIsValid(writer_oid))
			writer_oid = get_role_oid("gnomon_writer", false);
		writer = writer_oid;
	}
	GetUserIdAndSecContext(&save_user, &save_sec);
	SetUserIdAndSecContext(writer, save_sec | SECURITY_LOCAL_USERID_CHANGE);
	save_in = in_ctrig;
	save_on = trig_spi_on;
	save_nest = trig_guc_nest;
	save_stmt = wc_stmt_cxt;
	wc_stmt_cxt = fcinfo->flinfo->fn_mcxt;
	in_ctrig = true;
	trig_spi_on = false;
	trig_guc_nest = -1;
	PG_TRY();
	{
		ti = get_table_info(rel);
		st = take_stamp(ti, caller);
		/* the watermark only rises, and a session's keys never fall (an epoch outlives sessions):
		 * a key at or below one this session noted needs no shared-memory round trip */
		if (st.key > ti->wm_key)
		{
			wm_note(ti->relid, st.key);
			ti->wm_key = st.key;
		}
		use_leaf(ti, st.part);
		{
			const char *actor = GetConfigOption("gnomon.actor", true, false);
			const char *reason = GetConfigOption("gnomon.reason", true, false);

			if ((actor && actor[0]) || (reason && reason[0]))
			{
				trig_plans();
				SPI_execute("select gnomon._log_xact(0)", false, 0);
			}
		}
		if (oldt != NULL && newt != NULL)
		{
			for (int k = 0; k < ti->nkeys && keys_same; k++)
			{
				bool		n1,
							n2;
				Datum		a = heap_getattr(oldt, ti->keyatt[k], desc, &n1);
				Datum		b = heap_getattr(newt, ti->keyatt[k], desc, &n2);
				Form_pg_attribute att = TupleDescAttr(desc, ti->keyatt[k] - 1);

				keys_same = (n1 == n2) && (n1 || datum_image_eq(a, b, att->attbyval, att->attlen));
			}
		}

		if (oldt == NULL)
		{
			insert_version(ti, desc, newt, newt, st.key, st.xoff, st.lsn, st.role, 9, st.part, NULL, true);
		}
		else if (newt != NULL && keys_same)
		{
			bool	   *mask = palloc0(sizeof(bool) * Max(ti->nslots, 1));
			Datum	   *keys = palloc(sizeof(Datum) * (ti->nkeys + 1));
			char	   *knulls = palloc(ti->nkeys + 2);
			int			changed = 0;

			for (int k = 0; k < ti->nkeys; k++)
			{
				bool		isnull;

				keys[k] = heap_getattr(oldt, ti->keyatt[k], desc, &isnull);
				knulls[k] = isnull ? 'n' : ' ';
			}
			keys[ti->nkeys] = Int32GetDatum(st.part);
			knulls[ti->nkeys] = ' ';
			/*
			 * read_only = false: under READ COMMITTED the probe needs a snapshot taken now, after
			 * the row lock this write waited for. The statement's own snapshot predates the
			 * previous writer's commit, and the cumulative mask would miss what it changed.
			 */
			VFound		pf;

			if (probe_direct(ti, keys, st.part, &pf))
			{
				if (!pf.found)
					carry_forward(ti, desc, oldt, st.part, st.key);
				else if ((pf.flags & 8) == 0 && pf.mask != (Datum) 0)
					read_mask(pf.mask, mask, ti->nslots);
			}
			else
			{
			trig_plans();
			if (SPI_execute_plan(PROBE(ti), keys, knulls, false, 1) != SPI_OK_SELECT)
				elog(ERROR, "gnomon: version probe failed");
			if (SPI_processed == 0)
				carry_forward(ti, desc, oldt, st.part, st.key);
			else
			{
				bool		isnull;
				int16		flags = DatumGetInt16(SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &isnull));
				Datum		m = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 2, &isnull);

				if ((flags & 8) == 0 && !isnull)
					read_mask(m, mask, ti->nslots);
			}
			}
			for (int v = 0; v < ti->nvals; v++)
			{
				ValCol	   *c = &ti->vals[v];
				Form_pg_attribute att = TupleDescAttr(desc, c->attnum - 1);
				bool		n1,
							n2;
				Datum		a = heap_getattr(oldt, c->attnum, desc, &n1);
				Datum		b = heap_getattr(newt, c->attnum, desc, &n2);

				if (n1 != n2 || (!n1 && !datum_image_eq(a, b, att->attbyval, att->attlen)))
					mask[c->slot] = true;
			}
			for (int i = 0; i < ti->nslots; i++)
				if (mask[i])
					changed++;
			if (changed * 2 > ti->nvals)
				insert_version(ti, desc, newt, newt, st.key, st.xoff, st.lsn, st.role, 10, st.part, NULL, true);
			else
				insert_version(ti, desc, newt, newt, st.key, st.xoff, st.lsn, st.role, 2, st.part, mask, false);
		}
		else
		{
			/* DELETE, or an UPDATE that changed the key: tombstone + insert */
			bool	   *zero = palloc0(sizeof(bool) * Max(ti->nslots, 1));
			Datum	   *keys = palloc(sizeof(Datum) * (ti->nkeys + 1));
			char	   *knulls = palloc(ti->nkeys + 2);

			for (int k = 0; k < ti->nkeys; k++)
			{
				bool		isnull;

				keys[k] = heap_getattr(oldt, ti->keyatt[k], desc, &isnull);
				knulls[k] = isnull ? 'n' : ' ';
			}
			keys[ti->nkeys] = Int32GetDatum(st.part);
			knulls[ti->nkeys] = ' ';
			/*
			 * read_only = false: under READ COMMITTED the probe needs a snapshot taken now, after
			 * the row lock this write waited for. The statement's own snapshot predates the
			 * previous writer's commit, and the cumulative mask would miss what it changed.
			 */
			VFound		pf;

			if (probe_direct(ti, keys, st.part, &pf))
			{
				if (!pf.found)
					carry_forward(ti, desc, oldt, st.part, st.key);
			}
			else
			{
				trig_plans();
				if (SPI_execute_plan(PROBE(ti), keys, knulls, false, 1) != SPI_OK_SELECT)
					elog(ERROR, "gnomon: version probe failed");
				if (SPI_processed == 0)
					carry_forward(ti, desc, oldt, st.part, st.key);
			}
			insert_version(ti, desc, oldt, NULL, st.key, st.xoff, st.lsn, st.role, 4, st.part, zero, false);
			if (newt != NULL)
				insert_version(ti, desc, newt, newt, st.key, st.xoff, st.lsn, st.role, 9, st.part, NULL, true);
		}
	}
	PG_CATCH();
	{
		/* the transaction's abort closes the SPI connection */
		if (trig_guc_nest >= 0)
			AtEOXact_GUC(true, trig_guc_nest);
		in_ctrig = save_in;
		trig_spi_on = save_on;
		trig_guc_nest = save_nest;
		wc_stmt_cxt = save_stmt;
		SetUserIdAndSecContext(save_user, save_sec);
		PG_RE_THROW();
	}
	PG_END_TRY();
	if (trig_guc_nest >= 0)
		AtEOXact_GUC(true, trig_guc_nest);
	if (trig_spi_on)
		SPI_finish();
	in_ctrig = save_in;
	trig_spi_on = save_on;
	trig_guc_nest = save_nest;
	wc_stmt_cxt = save_stmt;
	SetUserIdAndSecContext(save_user, save_sec);
	return PointerGetDatum(NULL);
}

/* ------------------------------------------------------------------------
 * Faster reads: a cached lineage and shared-memory watermarks.
 *
 * The SQL core reads its per-statement context (branch, lineage, cutoffs) through
 * gnomon._ctx() and a dozen accessors evaluated as initplans; each is a PL/pgSQL call that
 * re-reads settings and parses a cached composite from text. With the module loaded, a planner
 * hook swaps those functions for C ones before the planner inlines anything: one context per
 * statement in backend memory, its fields returned directly. Statements PL/pgSQL plans go
 * through the hook too, so gnomon's own functions get the same context.
 *
 * The same swap gives _gnomon.unchanged_since() a shared-memory watermark per tracked table:
 * the highest version key the C trigger has written. A past read at coordinate C reads the
 * current table as is when the watermark is below C.xmin, with no per-row
 * probe, also on tables whose key index is BRIN.
 * ------------------------------------------------------------------------ */

static planner_hook_type prev_planner = NULL;

/* --- the context cache --------------------------------------------------- */

#define CTX_NFIELDS 11			/* _gnomon.ctx: branch kind status asof lb lc main_cut main_xmin valid_at main_now name */
enum
{
	CF_BRANCH, CF_KIND, CF_STATUS, CF_ASOF, CF_LB, CF_LC, CF_MAIN_CUT, CF_MAIN_XMIN, CF_VALID_AT, CF_MAIN_NOW, CF_NAME
};

typedef struct CtxCache
{
	bool		valid;
	char	   *b,
			   *a,
			   *v;				/* the settings it was computed for */
	TimestampTz stmt;
	TransactionId xid;
	char		marker[32];		/* our value of gnomon._ctxc; gnomon._bump() clears it */
	Datum		ctx;			/* the composite, in TopMemoryContext */
	Datum		f[CTX_NFIELDS];
	bool		n[CTX_NFIELDS];
	Oid			ftype[CTX_NFIELDS];
	int64		main_xmax;
	bool		cross;			/* may serve later statements, while its row tokens match */
	ItemPointerData tok[3];		/* the branch row, its latest base row, the tag row */
	TransactionId tokx[3];
	bool		base_touch;		/* a new base row also gives the branch row a new version */
	bool		cut_ok;			/* main_cut decoded: its epoch and snapshot (in ctx's memory) */
	int16		cut_epoch;
	Datum		cut_snap;
} CtxCache;

static CtxCache cc;

/*
 * Catalog rows a read context depends on: the branch row and its latest base row (for a branch
 * read now), the tag row (for tag:<name>). Read with the statement's snapshot, so a context
 * computed from them is valid for exactly the statements that see the same rows; a rebase, a
 * merge, a status change or a re-tag gives a different row version. Coordinates given as text
 * depend on nothing.
 */
static void
row_token(Oid rel, Oid idx, ScanKeyData *sk, int nkeys, bool backward, ItemPointer tid, TransactionId *xmin)
{
	Relation	r = table_open(rel, AccessShareLock);
	Relation	ir = index_open(idx, AccessShareLock);
	SysScanDesc scan = systable_beginscan_ordered(r, ir, GetActiveSnapshot(), nkeys, sk);
	HeapTuple	t = systable_getnext_ordered(scan, backward ? BackwardScanDirection : ForwardScanDirection);

	if (HeapTupleIsValid(t))
	{
		*tid = t->t_self;
		*xmin = HeapTupleHeaderGetXmin(t->t_data);
	}
	else
	{
		ItemPointerSetInvalid(tid);
		*xmin = InvalidTransactionId;
	}
	systable_endscan_ordered(scan);
	index_close(ir, AccessShareLock);
	table_close(r, AccessShareLock);
}

/*
 * Is this version of a row (TID and xmin) still the one the statement's snapshot sees? A row
 * has at most one visible version: an update or delete makes this one invisible to every later
 * snapshot, so "still visible" means "unchanged", for the price of one buffer read.
 */
typedef enum
{
	TOK_UNKNOWN, TOK_SAME, TOK_GONE
} TokState;

/* gnomon_c's trigger that gives a cached row a new version (gnomon_c--1.0.1.sql) is in place */
static bool
has_touch_trigger(Oid relid)
{
	Relation	r;
	bool		res = false;

	if (!OidIsValid(relid))
		return false;
	r = table_open(relid, AccessShareLock);
	if (r->trigdesc != NULL)
		for (int i = 0; i < r->trigdesc->numtriggers; i++)
			if (strcmp(r->trigdesc->triggers[i].tgname, "gnomon_c_touch") == 0 &&
				r->trigdesc->triggers[i].tgenabled != TRIGGER_DISABLED)
				res = true;
	table_close(r, AccessShareLock);
	return res;
}

static bool ctx_tokens(const char *b, const char *a, ItemPointerData *tid, TransactionId *x);

static TokState
token_visible(Oid relid, ItemPointer tid, TransactionId xmin)
{
	Relation	r;
	HeapTupleData tup;
	Buffer		buf,
				pin;
	BlockNumber blk;
	PrefetchBufferResult pr;
	TokState	res = TOK_UNKNOWN;

	if (!OidIsValid(relid) || !ItemPointerIsValid(tid) || !ActiveSnapshotSet())
		return TOK_UNKNOWN;
	r = table_open(relid, AccessShareLock);
	blk = ItemPointerGetBlockNumber(tid);
	/*
	 * Only a page in shared buffers is read: it exists (a truncation drops its buffers), and the
	 * pin keeps it there. Otherwise the caller looks the row up by its index (no size check,
	 * which costs a system call).
	 */
	pr = PrefetchBuffer(r, MAIN_FORKNUM, blk);
#if PG_VERSION_NUM >= 160000
	if (BufferIsValid(pr.recent_buffer) && ReadRecentBuffer(r->rd_locator, MAIN_FORKNUM, blk, pr.recent_buffer))
#else
	if (BufferIsValid(pr.recent_buffer) && ReadRecentBuffer(r->rd_node, MAIN_FORKNUM, blk, pr.recent_buffer))
#endif
	{
		pin = pr.recent_buffer;
		tup.t_self = *tid;
		if (heap_fetch(r, GetActiveSnapshot(), &tup, &buf, false))
		{
			res = HeapTupleHeaderGetXmin(tup.t_data) == xmin ? TOK_SAME : TOK_GONE;
			ReleaseBuffer(buf);
		}
		else
			res = TOK_GONE;
		ReleaseBuffer(pin);
	}
	table_close(r, AccessShareLock);
	return res;
}

/* The rows a cached cross-statement context came from, still as they were? */
static bool
ctx_still_valid(void)
{
	Oid			nsp = get_namespace_oid("gnomon", true);

	if (!OidIsValid(nsp) || !ActiveSnapshotSet())
		return false;
	if (ItemPointerIsValid(&cc.tok[0]))
	{
		Oid			brel = get_relname_relid("branch_base", nsp),
					bidx = get_relname_relid("branch_base_branch", nsp);
		ScanKeyData sk[1];
		ItemPointerData tid;
		TransactionId x;

		TokState	ts = token_visible(get_relname_relid("branch", nsp), &cc.tok[0], cc.tokx[0]);

		if (ts == TOK_GONE)
			return false;
		if (ts == TOK_UNKNOWN)
		{
			/* the branch row by name, as when the context was made */
			ItemPointerData t3[3];
			TransactionId x3[3];

			if (!ctx_tokens(cc.b, "", t3, x3) || !ItemPointerEquals(&t3[0], &cc.tok[0]) || x3[0] != cc.tokx[0])
				return false;
		}
		/* a rebase or merge adds a newer base row (the old one stays visible) */
		if (cc.base_touch)
			goto tag;			/* ... and its trigger has already changed the branch row */
		if (!OidIsValid(brel) || !OidIsValid(bidx))
			return false;
		ScanKeyInit(&sk[0], get_attnum(brel, "branch"), BTEqualStrategyNumber, F_INT4EQ, cc.f[CF_BRANCH]);
		row_token(brel, bidx, sk, 1, true, &tid, &x);
		if (!ItemPointerEquals(&tid, &cc.tok[1]) || x != cc.tokx[1])
			return false;
	}
tag:
	if (ItemPointerIsValid(&cc.tok[2]))
	{
		TokState	ts = token_visible(get_relname_relid("tag", nsp), &cc.tok[2], cc.tokx[2]);

		if (ts == TOK_GONE)
			return false;
		if (ts == TOK_UNKNOWN)
		{
			ItemPointerData t3[3];
			TransactionId x3[3];

			if (!ctx_tokens("", cc.a, t3, x3) || !ItemPointerEquals(&t3[2], &cc.tok[2]) || x3[2] != cc.tokx[2])
				return false;
		}
	}
	return true;
}

static bool
ctx_tokens(const char *b, const char *a, ItemPointerData *tid, TransactionId *x)
{
	Oid			nsp = get_namespace_oid("gnomon", true);
	ScanKeyData sk[1];

	for (int i = 0; i < 3; i++)
	{
		ItemPointerSetInvalid(&tid[i]);
		x[i] = InvalidTransactionId;
	}
	if (!OidIsValid(nsp) || !ActiveSnapshotSet())
		return false;
	if (b[0] != '\0' && strcmp(b, "main") != 0)
	{
		Oid			rel = get_relname_relid("branch", nsp), idx = get_relname_relid("branch_name_key", nsp);
		Oid			brel = get_relname_relid("branch_base", nsp), bidx = get_relname_relid("branch_base_branch", nsp);
		Relation	r;
		HeapTuple	t;
		SysScanDesc scan;
		Relation	ir;
		int32		id = -1;

		if (!OidIsValid(rel) || !OidIsValid(idx) || !OidIsValid(brel) || !OidIsValid(bidx))
			return false;
		/* systable scans take heap attribute numbers */
		ScanKeyInit(&sk[0], get_attnum(rel, "name"), BTEqualStrategyNumber, F_TEXTEQ, CStringGetTextDatum(b));
		r = table_open(rel, AccessShareLock);
		ir = index_open(idx, AccessShareLock);
		scan = systable_beginscan_ordered(r, ir, GetActiveSnapshot(), 1, sk);
		t = systable_getnext_ordered(scan, ForwardScanDirection);
		if (HeapTupleIsValid(t))
		{
			bool		isnull;

			tid[0] = t->t_self;
			x[0] = HeapTupleHeaderGetXmin(t->t_data);
			id = DatumGetInt32(heap_getattr(t, get_attnum(rel, "id"), RelationGetDescr(r), &isnull));
		}
		systable_endscan_ordered(scan);
		index_close(ir, AccessShareLock);
		table_close(r, AccessShareLock);
		if (id < 0)
			return false;
		ScanKeyInit(&sk[0], get_attnum(brel, "branch"), BTEqualStrategyNumber, F_INT4EQ, Int32GetDatum(id));
		row_token(brel, bidx, sk, 1, true, &tid[1], &x[1]);
	}
	if (strncmp(a, "tag:", 4) == 0)
	{
		Oid			rel = get_relname_relid("tag", nsp), idx = get_relname_relid("tag_pkey", nsp);

		if (!OidIsValid(rel) || !OidIsValid(idx))
			return false;
		ScanKeyInit(&sk[0], get_attnum(rel, "name"), BTEqualStrategyNumber, F_TEXTEQ, CStringGetTextDatum(a + 4));
		row_token(rel, idx, sk, 1, false, &tid[2], &x[2]);
	}
	return true;
}

static bool
ctx_cross_ok(const char *b, const char *a, const char *v)
{
	/* not for valid time, timestamps (resolved through ticks), branch as-of reads, or a standby */
	if (v[0] != '\0' || RecoveryInProgress())
		return false;
	if (a[0] == '\0')
		return true;
	if (b[0] != '\0' && strcmp(b, "main") != 0)
		return false;
	return (a[0] == 'e' && a[1] >= '0' && a[1] <= '9') || strncmp(a, "tag:", 4) == 0;
}
static uint64 cc_counter = 0;

static const char *
setting_or_empty(const char *name)
{
	const char *v = GetConfigOption(name, true, false);

	return v ? v : "";
}

static bool
same_str(const char *x, const char *y)
{
	return strcmp(x ? x : "", y ? y : "") == 0;
}

static void
ctx_fill(void)
{
	const char *b = setting_or_empty("gnomon.branch");
	const char *a = setting_or_empty("gnomon.as_of");
	const char *v = setting_or_empty("gnomon.valid_at");
	const char *mk = GetConfigOption("gnomon._ctxc", true, false);
	TimestampTz stmt = GetCurrentStatementStartTimestamp();
	TransactionId xid = GetTopTransactionIdIfAny();

	if (cc.valid && cc.stmt == stmt && cc.xid == xid && same_str(cc.b, b) && same_str(cc.a, a) &&
		same_str(cc.v, v) && same_str(cc.marker, mk))
		return;
	/* a later statement: the same context if the rows it was computed from are unchanged */
	if (cc.valid && cc.cross && same_str(cc.b, b) && same_str(cc.a, a) && same_str(cc.v, v) && same_str(cc.marker, mk))
	{
		if (ctx_still_valid())
		{
			cc.stmt = stmt;
			cc.xid = xid;
			return;
		}
	}

	{
		MemoryContext old;
		Oid			argt[3] = {TEXTOID, TEXTOID, TEXTOID};
		Datum		argv[3];
		bool		isnull;
		HeapTupleHeader th;
		HeapTupleData tup;
		TupleDesc	desc;
		Datum		d;
		int			ret;

		argv[0] = CStringGetTextDatum(b);
		argv[1] = CStringGetTextDatum(a);
		argv[2] = CStringGetTextDatum(v);
		SPI_connect();
		/* the main-now shortcut of gnomon._ctx() is part of _ctx_compute's answer too */
		ret = SPI_execute_with_args(
									"select x, gnomon._kxmax((x).main_cut) from (select gnomon._ctx_compute(nullif($1, ''), nullif($2, ''), nullif($3, '')) x) s "
									"where not ($1 in ('', 'main') and $2 = '' and $3 = '') "
									"union all select row(0, 'main', 'open', null, '{}'::int[], '{}'::gnomon.coord[], null, null, null, true, '')::_gnomon.ctx, "
									"9223372036854775807 where $1 in ('', 'main') and $2 = '' and $3 = ''",
									3, argt, argv, NULL, true, 1);
		if (ret != SPI_OK_SELECT || SPI_processed != 1)
			elog(ERROR, "gnomon: cannot compute the read context");
		d = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &isnull);
		old = MemoryContextSwitchTo(TopMemoryContext);
		if (cc.valid && cc.ctx)
			pfree(DatumGetPointer(cc.ctx));
		cc.valid = false;
		cc.ctx = datumCopy(d, false, -1);
		cc.main_xmax = DatumGetInt64(SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 2, &isnull));
		if (cc.b) pfree(cc.b);
		if (cc.a) pfree(cc.a);
		if (cc.v) pfree(cc.v);
		cc.b = pstrdup(b);
		cc.a = pstrdup(a);
		cc.v = pstrdup(v);
		MemoryContextSwitchTo(old);
		SPI_finish();

		th = DatumGetHeapTupleHeader(cc.ctx);
		tup.t_len = HeapTupleHeaderGetDatumLength(th);
		ItemPointerSetInvalid(&tup.t_self);
		tup.t_tableOid = InvalidOid;
		tup.t_data = th;
		desc = lookup_rowtype_tupdesc(HeapTupleHeaderGetTypeId(th), HeapTupleHeaderGetTypMod(th));
		if (desc->natts != CTX_NFIELDS)
			elog(ERROR, "gnomon: _gnomon.ctx has %d fields, the C module knows %d", desc->natts, CTX_NFIELDS);
		heap_deform_tuple(&tup, desc, cc.f, cc.n);
		for (int i = 0; i < CTX_NFIELDS; i++)
			cc.ftype[i] = TupleDescAttr(desc, i)->atttypid;
		ReleaseTupleDesc(desc);
		cc.stmt = stmt;
		cc.xid = xid;
		cc.cross = ctx_cross_ok(b, a, v) && ctx_tokens(b, a, cc.tok, cc.tokx);
		cc.base_touch = cc.cross && has_touch_trigger(get_relname_relid("branch_base", get_namespace_oid("gnomon", true)));
		snprintf(cc.marker, sizeof(cc.marker), "c:%llu", (unsigned long long) ++cc_counter);
		(void) set_config_option("gnomon._ctxc", cc.marker, PGC_USERSET, PGC_S_SESSION, GUC_ACTION_SET, true, 0, false);
		cc.valid = true;
		if (cc.cut_ok && cc.cut_snap)
			pfree(DatumGetPointer(cc.cut_snap));
		cc.cut_snap = (Datum) 0;
		cc.cut_ok = !cc.n[CF_MAIN_CUT];
		if (cc.cut_ok)
		{
			/* a copy: the coordinate inside the context may be detoasted into a temporary */
			MemoryContext old = MemoryContextSwitchTo(TopMemoryContext);
			Datum		sn;

			coord_parts(cc.f[CF_MAIN_CUT], &cc.cut_epoch, &sn);
			cc.cut_snap = PointerGetDatum(PG_DETOAST_DATUM_COPY(sn));
			MemoryContextSwitchTo(old);
		}
	}
}

static Datum
ctx_field(int i, bool *isnull)
{
	int16		typlen;
	bool		typbyval;

	ctx_fill();
	*isnull = cc.n[i];
	if (cc.n[i])
		return (Datum) 0;
	get_typlenbyval(cc.ftype[i], &typlen, &typbyval);
	return datumCopy(cc.f[i], typbyval, typlen);
}

PG_FUNCTION_INFO_V1(gnomon_c_ctx);
Datum
gnomon_c_ctx(PG_FUNCTION_ARGS)
{
	ctx_fill();
	PG_RETURN_DATUM(datumCopy(cc.ctx, false, -1));
}

#define CTX_ACCESSOR(fn, field) \
	PG_FUNCTION_INFO_V1(fn); \
	Datum fn(PG_FUNCTION_ARGS) \
	{ \
		bool isnull; Datum d = ctx_field(field, &isnull); \
		if (isnull) PG_RETURN_NULL(); \
		PG_RETURN_DATUM(d); \
	}
CTX_ACCESSOR(gnomon_c_ctx_branch, CF_BRANCH)
CTX_ACCESSOR(gnomon_c_ctx_lb, CF_LB)
CTX_ACCESSOR(gnomon_c_ctx_lc, CF_LC)
CTX_ACCESSOR(gnomon_c_ctx_main_cut, CF_MAIN_CUT)
CTX_ACCESSOR(gnomon_c_ctx_main_xmin, CF_MAIN_XMIN)
CTX_ACCESSOR(gnomon_c_ctx_main_now, CF_MAIN_NOW)

PG_FUNCTION_INFO_V1(gnomon_c_ctx_asof_null);
Datum
gnomon_c_ctx_asof_null(PG_FUNCTION_ARGS)
{
	ctx_fill();
	PG_RETURN_BOOL(cc.n[CF_ASOF]);
}

PG_FUNCTION_INFO_V1(gnomon_c_ctx_main_xmax);
Datum
gnomon_c_ctx_main_xmax(PG_FUNCTION_ARGS)
{
	ctx_fill();
	PG_RETURN_INT64(cc.main_xmax);
}

PG_FUNCTION_INFO_V1(gnomon_c_ctx_valid_at);
Datum
gnomon_c_ctx_valid_at(PG_FUNCTION_ARGS)
{
	ctx_fill();
	if (cc.n[CF_VALID_AT])
		PG_RETURN_TIMESTAMPTZ(GetCurrentTransactionStartTimestamp());	/* coalesce(valid_at, now()) */
	PG_RETURN_DATUM(cc.f[CF_VALID_AT]);
}

/* --- shared-memory watermarks ------------------------------------------- */

typedef struct WmKey
{
	Oid			dbid;
	Oid			relid;
} WmKey;

typedef struct WmEntry
{
	WmKey		key;
	Oid			trigoid;		/* the C trigger (pg_trigger oid) every write since the start went through */
	pg_atomic_uint64 max_key;	/* no version of the table has a larger key */
} WmEntry;

#define WM_MAX_TABLES 4096
static HTAB *wm_hash = NULL;
static LWLock *wm_lock = NULL;
static shmem_request_hook_type prev_shmem_request = NULL;
static shmem_startup_hook_type prev_shmem_startup = NULL;
static Oid	c_trigger_fn = InvalidOid;

static void
wm_shmem_request(void)
{
	if (prev_shmem_request)
		prev_shmem_request();
	RequestAddinShmemSpace(MAXALIGN(sizeof(GnCounters)));
	RequestAddinShmemSpace(hash_estimate_size(WM_MAX_TABLES, sizeof(WmEntry)));
	RequestNamedLWLockTranche("gnomon_watermarks", 1);
	tf_shmem_request();
}

static void
wm_shmem_startup(void)
{
	HASHCTL		info;

	if (prev_shmem_startup)
		prev_shmem_startup();
	LWLockAcquire(AddinShmemInitLock, LW_EXCLUSIVE);
	memset(&info, 0, sizeof(info));
	info.keysize = sizeof(WmKey);
	info.entrysize = sizeof(WmEntry);
	wm_hash = ShmemInitHash("gnomon watermarks", WM_MAX_TABLES, WM_MAX_TABLES, &info, HASH_ELEM | HASH_BLOBS);
	wm_lock = &(GetNamedLWLockTranche("gnomon_watermarks"))->lock;
	{
		bool		found;

		gn_counters = ShmemInitStruct("gnomon_c counters", sizeof(GnCounters), &found);
		if (!found)
			for (int i = 0; i < GN_NCOUNTERS; i++)
				pg_atomic_init_u64(&gn_counters->c[i], 0);
	}
	tf_shmem_startup();
	LWLockRelease(AddinShmemInitLock);
}

/*
 * The touched-key filter: a bit array in shared memory with two bits per (touched-key
 * table, branch, key). A BEFORE INSERT trigger on the touched-key tables (gnomon_c_filter, ENABLE
 * ALWAYS, so restores and replication set them too) sets the bits before a row exists. A table's
 * bits count only once it is "ready": they were rebuilt since startup from a scan of every row
 * physically in the table, taken after its trigger was in place, and the trigger is still the one
 * they were built under. A point read then skips the touched-key scan for a key with none of its
 * levels' bits set. Bits are never cleared, so a key can only be wrongly "maybe touched" (and the
 * read scans as before), never wrongly untouched.
 */
typedef struct TfEntry
{
	WmKey		key;			/* database, touched-key table */
	Oid			trigoid;		/* the filter trigger the bits were built under */
	bool		ready;
} TfEntry;

static int	tf_kb = 1024;		/* gnomon.touched_filter_kb (postmaster) */
static bool tf_enabled = true;	/* gnomon.c_touched_filter */
static pg_atomic_uint32 *tf_bits = NULL;
static uint64 tf_nbits = 0;
static HTAB *tf_hash = NULL;
static Oid	tf_trig_fn = InvalidOid;
static uint64 tf_skips = 0,
			tf_scans = 0;

static void
tf_shmem_request(void)
{
	if (tf_kb <= 0)
		return;
	RequestAddinShmemSpace((Size) tf_kb * 1024);
	RequestAddinShmemSpace(hash_estimate_size(WM_MAX_TABLES, sizeof(TfEntry)));
}

static void
tf_shmem_startup(void)
{
	HASHCTL		info;
	bool		found;

	if (tf_kb <= 0)
		return;
	tf_bits = ShmemInitStruct("gnomon touched-key filter", (Size) tf_kb * 1024, &found);
	tf_nbits = (uint64) tf_kb * 1024 * 8;
	if (!found)
		for (uint64 i = 0; i < tf_nbits / 32; i++)
			pg_atomic_init_u32(&tf_bits[i], 0);
	memset(&info, 0, sizeof(info));
	info.keysize = sizeof(WmKey);
	info.entrysize = sizeof(TfEntry);
	tf_hash = ShmemInitHash("gnomon touched-key filter tables", WM_MAX_TABLES, WM_MAX_TABLES, &info, HASH_ELEM | HASH_BLOBS);
}

/* a touched-key table the filter can describe: (gn_branch, one fixed-size key, gn_fkey, gn_fxoff) */
static bool
tf_eligible(Relation r)
{
	TupleDesc	d = RelationGetDescr(r);
	Form_pg_attribute b,
				k;

	if (d->natts != 4)
		return false;
	b = TupleDescAttr(d, 0);
	k = TupleDescAttr(d, 1);
	return !b->attisdropped && !k->attisdropped && strcmp(NameStr(b->attname), "gn_branch") == 0 &&
		b->atttypid == INT4OID && k->attlen > 0 && k->attlen <= 16;
}

/* the table's enabled filter trigger, from the relcache */
static Oid
tf_trigger(Relation r)
{
	TriggerDesc *td = r->trigdesc;

	if (!OidIsValid(tf_trig_fn))
	{
		List	   *name = list_make2(makeString("_gnomon"), makeString("c_touch_filter"));

		tf_trig_fn = LookupFuncName(name, 0, NULL, true);
		if (!OidIsValid(tf_trig_fn))
			return InvalidOid;
	}
	if (td == NULL)
		return InvalidOid;
	for (int i = 0; i < td->numtriggers; i++)
	{
		Trigger    *tg = &td->triggers[i];

		if (strcmp(tg->tgname, "gnomon_c_filter") == 0)
			return (tg->tgfoid == tf_trig_fn && tg->tgenabled != TRIGGER_DISABLED && TRIGGER_FOR_BEFORE(tg->tgtype) &&
					TRIGGER_FOR_ROW(tg->tgtype) && TRIGGER_FOR_INSERT(tg->tgtype)) ? tg->tgoid : InvalidOid;
	}
	return InvalidOid;
}

static void
tf_positions(Oid relid, int32 branch, Datum key, int16 typlen, bool byval, uint64 *p1, uint64 *p2)
{
	unsigned char buf[sizeof(Oid) * 2 + sizeof(int32) + 16];
	int			n = 0;
	uint64		h;

	memcpy(buf + n, &MyDatabaseId, sizeof(Oid));
	n += sizeof(Oid);
	memcpy(buf + n, &relid, sizeof(Oid));
	n += sizeof(Oid);
	memcpy(buf + n, &branch, sizeof(int32));
	n += sizeof(int32);
	if (byval)
	{
		/* the value's own bytes, not the Datum's (which may be sign-extended) */
		switch (typlen)
		{
			case 1:
				{
					char		v = DatumGetChar(key);

					memcpy(buf + n, &v, 1);
					break;
				}
			case 2:
				{
					int16		v = DatumGetInt16(key);

					memcpy(buf + n, &v, 2);
					break;
				}
			case 4:
				{
					int32		v = DatumGetInt32(key);

					memcpy(buf + n, &v, 4);
					break;
				}
			default:
				{
					int64		v = DatumGetInt64(key);

					memcpy(buf + n, &v, 8);
					break;
				}
		}
	}
	else
		memcpy(buf + n, DatumGetPointer(key), typlen);
	n += typlen;
	h = hash_bytes_extended(buf, n, 0);
	*p1 = (h & 0xffffffff) % tf_nbits;
	*p2 = (h >> 32) % tf_nbits;
}

static void
tf_set(Oid relid, int32 branch, Datum key, int16 typlen, bool byval)
{
	uint64		p1,
				p2;

	tf_positions(relid, branch, key, typlen, byval, &p1, &p2);
	pg_atomic_fetch_or_u32(&tf_bits[p1 >> 5], (uint32) 1 << (p1 & 31));
	pg_atomic_fetch_or_u32(&tf_bits[p2 >> 5], (uint32) 1 << (p2 & 31));
}

static bool
tf_maybe(Oid relid, int32 branch, Datum key, int16 typlen, bool byval)
{
	uint64		p1,
				p2;

	tf_positions(relid, branch, key, typlen, byval, &p1, &p2);
	return (pg_atomic_read_u32(&tf_bits[p1 >> 5]) & ((uint32) 1 << (p1 & 31))) != 0 &&
		(pg_atomic_read_u32(&tf_bits[p2 >> 5]) & ((uint32) 1 << (p2 & 31))) != 0;
}

PG_FUNCTION_INFO_V1(gnomon_c_touch_filter);
Datum
gnomon_c_touch_filter(PG_FUNCTION_ARGS)
{
	TriggerData *td = (TriggerData *) fcinfo->context;

	if (!CALLED_AS_TRIGGER(fcinfo) || !TRIGGER_FIRED_BEFORE(td->tg_event) || !TRIGGER_FIRED_FOR_ROW(td->tg_event))
		elog(ERROR, "_gnomon.c_touch_filter must be a BEFORE ROW trigger");
	if (tf_bits != NULL && TRIGGER_FIRED_BY_INSERT(td->tg_event) && tf_eligible(td->tg_relation))
	{
		TupleDesc	d = RelationGetDescr(td->tg_relation);
		Form_pg_attribute ka = TupleDescAttr(d, 1);
		bool		n1,
					n2;
		Datum		br = heap_getattr(td->tg_trigtuple, 1, d, &n1);
		Datum		k = heap_getattr(td->tg_trigtuple, 2, d, &n2);

		if (!n1 && !n2)
			tf_set(RelationGetRelid(td->tg_relation), DatumGetInt32(br), k, ka->attlen, ka->attbyval);
	}
	return PointerGetDatum(td->tg_trigtuple);
}

/* Make the bits of a touched-key table count: every row physically there, under its trigger. */
static bool
tf_build(Relation r, Oid trig)
{
	TupleDesc	d = RelationGetDescr(r);
	Form_pg_attribute ka = TupleDescAttr(d, 1);
	TableScanDesc scan;
	TupleTableSlot *slot;
	WmKey		k;
	TfEntry    *e;
	bool		found;

	/* all tuples, dead and in-progress ones too: a superset of what any snapshot sees */
	scan = table_beginscan(r, SnapshotAny, 0, NULL);
	slot = table_slot_create(r, NULL);
	while (table_scan_getnextslot(scan, ForwardScanDirection, slot))
	{
		bool		n1,
					n2;
		Datum		br = slot_getattr(slot, 1, &n1);
		Datum		kv = slot_getattr(slot, 2, &n2);

		if (!n1 && !n2)
			tf_set(RelationGetRelid(r), DatumGetInt32(br), kv, ka->attlen, ka->attbyval);
	}
	ExecDropSingleTupleTableSlot(slot);
	table_endscan(scan);
	memset(&k, 0, sizeof(k));
	k.dbid = MyDatabaseId;
	k.relid = RelationGetRelid(r);
	LWLockAcquire(wm_lock, LW_EXCLUSIVE);
	e = hash_search(tf_hash, &k, HASH_ENTER_NULL, &found);
	if (e != NULL)
	{
		e->trigoid = trig;
		e->ready = true;
	}
	LWLockRelease(wm_lock);
	return e != NULL;
}

/*
 * May the filter answer for this touched-key table? Its trigger is in place (relcache, current as
 * of this statement's locks) and its bits are ready under that trigger; builds them if needed.
 */
static bool
tf_usable(Oid bk)
{
	Relation	r;
	Oid			trig;
	bool		ok = false;

	if (!tf_enabled || tf_bits == NULL || RecoveryInProgress())
		return false;
	r = table_open(bk, AccessShareLock);
	trig = tf_trigger(r);
	if (OidIsValid(trig) && tf_eligible(r))
	{
		WmKey		k;
		TfEntry    *e;

		memset(&k, 0, sizeof(k));
		k.dbid = MyDatabaseId;
		k.relid = bk;
		LWLockAcquire(wm_lock, LW_SHARED);
		e = hash_search(tf_hash, &k, HASH_FIND, NULL);
		ok = e != NULL && e->ready && e->trigoid == trig;
		LWLockRelease(wm_lock);
		if (!ok)
			ok = tf_build(r, trig);
	}
	table_close(r, AccessShareLock);
	return ok;
}

/* The C trigger wrote a version with this key (called after the stamp is final). */
static void
wm_note(Oid relid, int64 key)
{
	WmKey		k;
	WmEntry    *e;

	if (wm_hash == NULL)
		return;
	memset(&k, 0, sizeof(k));
	k.dbid = MyDatabaseId;
	k.relid = relid;
	LWLockAcquire(wm_lock, LW_SHARED);
	e = hash_search(wm_hash, &k, HASH_FIND, NULL);
	if (e != NULL)
	{
		uint64		cur = pg_atomic_read_u64(&e->max_key);

		while ((int64) cur < key && !pg_atomic_compare_exchange_u64(&e->max_key, &cur, (uint64) key))
			;
	}
	LWLockRelease(wm_lock);
}

/* The table's versioning trigger if it is the C trigger and enabled, else InvalidOid. */
static Oid
current_c_trigger(Oid relid)
{
	Relation	tgrel;
	ScanKeyData skey[2];
	SysScanDesc scan;
	HeapTuple	tup;
	Oid			result = InvalidOid;

	if (!OidIsValid(c_trigger_fn))
	{
		List	   *name = list_make2(makeString("_gnomon"), makeString("c_version_trigger"));

		c_trigger_fn = LookupFuncName(name, 0, NULL, true);
		if (!OidIsValid(c_trigger_fn))
			return InvalidOid;
	}
	tgrel = table_open(TriggerRelationId, AccessShareLock);
	ScanKeyInit(&skey[0], Anum_pg_trigger_tgrelid, BTEqualStrategyNumber, F_OIDEQ, ObjectIdGetDatum(relid));
	ScanKeyInit(&skey[1], Anum_pg_trigger_tgname, BTEqualStrategyNumber, F_NAMEEQ, CStringGetDatum("gnomon_v"));
	scan = systable_beginscan(tgrel, TriggerRelidNameIndexId, true, NULL, 2, skey);
	if (HeapTupleIsValid(tup = systable_getnext(scan)))
	{
		Form_pg_trigger tg = (Form_pg_trigger) GETSTRUCT(tup);

		if (tg->tgfoid == c_trigger_fn && tg->tgenabled != TRIGGER_DISABLED)
			result = tg->oid;
	}
	systable_endscan(scan);
	table_close(tgrel, AccessShareLock);
	return result;
}

/* tracked-table id -> relid, per backend (ids are never reused) */
static HTAB *tid_rel = NULL;
typedef struct TidRel
{
	int32		tid;
	Oid			relid;
} TidRel;

static Oid
tracked_relid(int32 tid)
{
	TidRel	   *e;
	bool		found;

	if (tid_rel == NULL)
	{
		HASHCTL		info;

		memset(&info, 0, sizeof(info));
		info.keysize = sizeof(int32);
		info.entrysize = sizeof(TidRel);
		tid_rel = hash_create("gnomon tracked ids", 64, &info, HASH_ELEM | HASH_BLOBS);
	}
	e = hash_search(tid_rel, &tid, HASH_ENTER, &found);
	if (!found)
	{
		Oid			argt[1] = {INT4OID};
		Datum		argv[1] = {Int32GetDatum(tid)};
		bool		isnull = true;

		e->relid = InvalidOid;
		SPI_connect();
		if (SPI_execute_with_args("select rel::oid from gnomon.tracked where id = $1", 1, argt, argv, NULL, true, 1) == SPI_OK_SELECT &&
			SPI_processed == 1)
			e->relid = DatumGetObjectId(SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &isnull));
		SPI_finish();
		if (!OidIsValid(e->relid))
		{
			hash_search(tid_rel, &tid, HASH_REMOVE, NULL);
			return InvalidOid;
		}
	}
	return e->relid;
}

/*
 * True only when no version of table tid has a key >= kxmin. The watermark is trusted only
 * while every write since it started went through the same C trigger: a new trigger (another
 * pg_trigger oid) restarts it, and with the PL/pgSQL trigger attached it is not used at all.
 * It starts at (epoch, next xid), above every key already written; never on a standby, where
 * versions arrive by replay.
 */
PG_FUNCTION_INFO_V1(gnomon_c_unchanged_since);
Datum
gnomon_c_unchanged_since(PG_FUNCTION_ARGS)
{
	int32		tid = PG_GETARG_INT32(0);
	int64		kxmin;
	Oid			relid,
				trig;

	if (PG_ARGISNULL(0) || PG_ARGISNULL(1) || wm_hash == NULL || RecoveryInProgress())
		PG_RETURN_BOOL(false);
	kxmin = PG_GETARG_INT64(1);
	relid = tracked_relid(tid);
	if (!OidIsValid(relid))
		PG_RETURN_BOOL(false);
	trig = current_c_trigger(relid);
	if (!OidIsValid(trig))
		PG_RETURN_BOOL(false);
	PG_RETURN_BOOL(wm_unchanged(relid, trig, kxmin));
}

/* the watermark of relid, kept while trig is its C trigger: no version with key >= kxmin? */
static bool
wm_unchanged(Oid relid, Oid trig, int64 kxmin)
{
	WmKey		k;
	WmEntry    *e;
	bool		found,
				result = false;

	if (wm_hash == NULL || RecoveryInProgress() || !OidIsValid(trig))
		return false;
	memset(&k, 0, sizeof(k));
	k.dbid = MyDatabaseId;
	k.relid = relid;
	LWLockAcquire(wm_lock, LW_SHARED);
	e = hash_search(wm_hash, &k, HASH_FIND, NULL);
	if (e != NULL && e->trigoid == trig)
	{
		result = (int64) pg_atomic_read_u64(&e->max_key) < kxmin;
		LWLockRelease(wm_lock);
		return result;
	}
	LWLockRelease(wm_lock);
	{
		/* start (or restart) the watermark above every key written so far */
		int64		ep;
		int64		bound;
		bool		isnull;

		SPI_connect();
		if (SPI_execute("select gnomon._epoch_ro()", true, 1) != SPI_OK_SELECT || SPI_processed != 1)
			elog(ERROR, "gnomon: cannot read the epoch");
		ep = DatumGetInt16(SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &isnull));
		SPI_finish();
		bound = (ep << 48) | (int64) U64FromFullTransactionId(ReadNextFullTransactionId());
		LWLockAcquire(wm_lock, LW_EXCLUSIVE);
		e = hash_search(wm_hash, &k, HASH_ENTER_NULL, &found);
		if (e != NULL)
		{
			if (!found || e->trigoid != trig)
			{
				e->trigoid = trig;
				pg_atomic_init_u64(&e->max_key, (uint64) bound);
			}
			result = (int64) pg_atomic_read_u64(&e->max_key) < kxmin;
		}
		LWLockRelease(wm_lock);
	}
	return result;
}

/* current_c_trigger from the relation's trigger list in the relcache (no catalog scan) */
static Oid
rel_c_trigger(Relation rel)
{
	TriggerDesc *td = rel->trigdesc;

	if (!OidIsValid(c_trigger_fn))
	{
		List	   *name = list_make2(makeString("_gnomon"), makeString("c_version_trigger"));

		c_trigger_fn = LookupFuncName(name, 0, NULL, true);
		if (!OidIsValid(c_trigger_fn))
			return InvalidOid;
	}
	if (td == NULL)
		return InvalidOid;
	for (int i = 0; i < td->numtriggers; i++)
	{
		Trigger    *tg = &td->triggers[i];

		if (strcmp(tg->tgname, "gnomon_v") == 0)
			return (tg->tgfoid == c_trigger_fn && tg->tgenabled != TRIGGER_DISABLED) ? tg->tgoid : InvalidOid;
	}
	return InvalidOid;
}

/* --- swapping core functions for C ones ---------------------------------- */

typedef struct Subst
{
	Oid			from;
	Oid			to;
} Subst;

static Subst *substs = NULL;
static int	nsubst = -1;		/* -1: not looked up in this database yet */

static void
proc_inval_cb(Datum arg, int cacheid, uint32 hashvalue)
{
	nsubst = -1;
	c_trigger_fn = InvalidOid;
}

static Oid
func_oid(const char *schema, const char *name, int nargs, Oid *types)
{
	List	   *fname = list_make2(makeString(pstrdup(schema)), makeString(pstrdup(name)));

	return LookupFuncName(fname, nargs, types, true);
}

static void
build_substs(void)
{
	static const struct
	{
		const char *core_schema;
		const char *core;
		const char *c;
		int			nargs;
	}			map[] = {
		{"gnomon", "_ctx", "c_ctx", 0},
		{"gnomon", "_ctx_main_now", "c_ctx_main_now", 0},
		{"gnomon", "_ctx_branch", "c_ctx_branch", 0},
		{"gnomon", "_ctx_asof_null", "c_ctx_asof_null", 0},
		{"gnomon", "_ctx_lb", "c_ctx_lb", 0},
		{"gnomon", "_ctx_lc", "c_ctx_lc", 0},
		{"gnomon", "_ctx_main_cut", "c_ctx_main_cut", 0},
		{"gnomon", "_ctx_main_xmin", "c_ctx_main_xmin", 0},
		{"gnomon", "_ctx_main_xmax", "c_ctx_main_xmax", 0},
		{"gnomon", "_ctx_valid_at", "c_ctx_valid_at", 0},
		{"_gnomon", "unchanged_since", "c_unchanged_since", 2},
	};
	Oid			two[2] = {INT4OID, INT8OID};
	MemoryContext old = MemoryContextSwitchTo(TopMemoryContext);

	if (substs == NULL)
		substs = palloc(sizeof(Subst) * lengthof(map));
	MemoryContextSwitchTo(old);
	nsubst = 0;
	for (int i = 0; i < (int) lengthof(map); i++)
	{
		Oid			from = func_oid(map[i].core_schema, map[i].core, map[i].nargs, map[i].nargs ? two : NULL);
		Oid			to = func_oid("_gnomon", map[i].c, map[i].nargs, map[i].nargs ? two : NULL);

		if (OidIsValid(from) && OidIsValid(to))
		{
			substs[nsubst].from = from;
			substs[nsubst].to = to;
			nsubst++;
		}
	}
}

static bool
subst_walker(Node *node, void *context)
{
	if (node == NULL)
		return false;
	if (IsA(node, FuncExpr))
	{
		FuncExpr   *f = (FuncExpr *) node;

		for (int i = 0; i < nsubst; i++)
			if (f->funcid == substs[i].from)
			{
				f->funcid = substs[i].to;
				break;
			}
	}
	if (IsA(node, Query))
		return query_tree_walker((Query *) node, subst_walker, context, 0);
	return expression_tree_walker(node, subst_walker, context);
}

/* --- point reads by primary key through a routing view (the custom scan) ---------
 *
 * SELECT ... FROM <routing view> WHERE <key> = <constant or parameter>, on a branch now or on
 * main as of a coordinate, is answered by a function with a few index probes instead of the
 * whole routing plan: the branch head, the touched keys of each lineage level, whether main's
 * history of the key changed since the cutoff (watermark or one probe), main's current row.
 * Anything else (an ancestor level touched the key, history to rebuild, a branch TRUNCATE, a
 * table tracked after the branch was made) runs the routing view itself, from inside the
 * function, so the answer is always the view's. PostgreSQL 16 and later (views are expanded
 * into subquery RTEs that keep the view's OID).
 */


/* A table of the point read and what a lookup by key in it needs, resolved once per view. */
typedef struct PtRel
{
	Oid			rel,
				idx;
	AttrNumber	branch_att,		/* 0: the table itself (no gn_branch) */
				key_att,
				x1_att,			/* gn_fkey, gn_fxoff of a touched-key table */
				x2_att;
	Oid			idx_type,		/* of the key's index column */
				idx_coll;
	int			nmap;			/* the view's columns -> this table's attribute numbers */
	AttrNumber *map;
} PtRel;

static void
ptrel_init(PtRel *pr, Oid rel, Oid idx, bool with_branch, const char *keycol, bool touched)
{
	Relation	ir;
	int			kcol = with_branch ? 1 : 0;

	if (pr->map)
		pfree(pr->map);
	pr->map = NULL;
	pr->nmap = 0;
	pr->rel = rel;
	pr->idx = idx;
	pr->branch_att = with_branch ? get_attnum(rel, "gn_branch") : 0;
	pr->key_att = get_attnum(rel, keycol);
	pr->x1_att = touched ? get_attnum(rel, "gn_fkey") : 0;
	pr->x2_att = touched ? get_attnum(rel, "gn_fxoff") : 0;
	ir = index_open(idx, AccessShareLock);
	pr->idx_type = ir->rd_opcintype[kcol];
	pr->idx_coll = ir->rd_indcollation[kcol];
	index_close(ir, AccessShareLock);
}

typedef struct PtView
{
	Oid			view;			/* hash key */
	bool		loaded;
	bool		usable;
	bool		scratch_view;
	Oid			base;
	int32		tid;
	char		keycol[NAMEDATALEN];
	AttrNumber	view_keyatt;
	Oid			keytype;
	Oid			keycoll;
	int64		track_key;
	int32		track_xoff;
	Oid			b_rel,
				b_u_rel,
				bk_rel,
				bk_u_rel,
				cleared_rel,
				cleared_idx;
	ItemPointerData tok;
	TransactionId tokx;
	bool		cleared_known;	/* has_cleared is current: a branch TRUNCATE changes the tracked row */
	bool		has_cleared;
	PtRel	   *pr_b,
			   *pr_b_u,
			   *pr_bk,
			   *pr_bk_u,
			   *pr_base;
	RegProcedure key_eqfn;		/* the key type's b-tree equality */
	PtRel	   *pr_bkk,			/* the touched-key tables by (key, gn_branch): every level at once */
			   *pr_bkk_u;
	bool		hist_ok;		/* main's rows may be rebuilt from history in C */
	int16		keylen;			/* the key type's length and by-value (the touched-key filter) */
	bool		keybyval;
} PtView;

static HTAB *pt_views = NULL;

/* the gnomon.tracked row of a table: its version, to notice a change of its settings */
static void
tracked_token(Oid base, ItemPointer tid, TransactionId *x)
{
	Oid			nsp = get_namespace_oid("gnomon", true);
	ScanKeyData sk[1];
	Oid			rel = OidIsValid(nsp) ? get_relname_relid("tracked", nsp) : InvalidOid;
	Oid			idx = OidIsValid(nsp) ? get_relname_relid("tracked_rel_key", nsp) : InvalidOid;

	ItemPointerSetInvalid(tid);
	*x = InvalidTransactionId;
	if (!OidIsValid(rel) || !OidIsValid(idx))
		return;
	ScanKeyInit(&sk[0], get_attnum(rel, "rel"), BTEqualStrategyNumber, F_OIDEQ, ObjectIdGetDatum(base));
	row_token(rel, idx, sk, 1, false, tid, x);
}

static Oid
pkey_of(Oid rel)
{
	Relation	r;
	Oid			idx;

	if (!OidIsValid(rel))
		return InvalidOid;
	r = table_open(rel, AccessShareLock);
	idx = RelationGetPrimaryKeyIndex(r
#if PG_VERSION_NUM >= 180000
									 , false
#endif
		);
	table_close(r, AccessShareLock);
	return idx;
}

static PtView *
pt_view(Oid view)
{
	PtView	   *pv;
	bool		found;
	ItemPointerData tid;
	TransactionId x;
	Oid			base;
	char	   *nsp;
	size_t		l;
	Oid			gnsp;

	if (pt_views == NULL)
	{
		HASHCTL		info;

		memset(&info, 0, sizeof(info));
		info.keysize = sizeof(Oid);
		info.entrysize = sizeof(PtView);
		pt_views = hash_create("gnomon point views", 64, &info, HASH_ELEM | HASH_BLOBS);
	}
	pv = hash_search(pt_views, &view, HASH_ENTER, &found);
	if (!found)
		memset(((char *) pv) + sizeof(Oid), 0, sizeof(PtView) - sizeof(Oid));
	/* a view's OID names one base table for its life; the tracked row says whether it changed */
	if (found && pv->loaded && ItemPointerIsValid(&pv->tok))
	{
		TokState	ts = token_visible(get_relname_relid("tracked", get_namespace_oid("gnomon", true)), &pv->tok, pv->tokx);

		if (ts == TOK_SAME)
			return pv;
		if (ts == TOK_UNKNOWN)
		{
			tracked_token(pv->base, &tid, &x);
			if (ItemPointerEquals(&tid, &pv->tok) && x == pv->tokx)
				return pv;
		}
	}
	base = routing_view_base(view);
	if (!OidIsValid(base) || !ActiveSnapshotSet())
	{
		pv->loaded = true;
		pv->usable = false;
		ItemPointerSetInvalid(&pv->tok);
		return pv;
	}
	tracked_token(base, &tid, &x);
	pv->loaded = true;
	pv->usable = false;
	pv->tok = tid;
	pv->tokx = x;
	pv->base = base;
	nsp = get_namespace_name(get_rel_namespace(view));
	gnsp = get_namespace_oid("_gnomon", true);
	if (nsp == NULL || strstr(nsp, "__m") != NULL || !OidIsValid(gnsp) || !ItemPointerIsValid(&tid))
		return pv;				/* masked profiles: their own views, through the planner */
	l = strlen(nsp);
	pv->scratch_view = l > 3 && strcmp(nsp + l - 3, "__s") == 0;
	SPI_connect();
	{
		Oid			argt[1] = {OIDOID};
		Datum		argv[1] = {ObjectIdGetDatum(base)};

		if (SPI_execute_with_args(
								  "select t.id, t.base, t.key_cols[1], t.track_key, t.track_xoff, "
								  "cardinality(t.key_cols) = 1 and not t.wide_key and t.mode = 'known' and not t.user_rls "
								  "and not (coalesce(t.retention, '{}') ? 'horizon_key'), "
								  "_gnomon.has_cleared(t.id) "   /* (the caller has no grants on _gnomon tables) */
								  "from gnomon.tracked t where t.rel = $1", 1, argt, argv, NULL, true, 1) == SPI_OK_SELECT &&
			SPI_processed == 1)
		{
			HeapTuple	t = SPI_tuptable->vals[0];
			TupleDesc	td = SPI_tuptable->tupdesc;
			bool		isnull;
			char	   *b = SPI_getvalue(t, td, 2);

			pv->tid = DatumGetInt32(SPI_getbinval(t, td, 1, &isnull));
			strlcpy(pv->keycol, SPI_getvalue(t, td, 3), NAMEDATALEN);
			pv->track_key = DatumGetInt64(SPI_getbinval(t, td, 4, &isnull));
			pv->track_xoff = DatumGetInt32(SPI_getbinval(t, td, 5, &isnull));
			pv->usable = DatumGetBool(SPI_getbinval(t, td, 6, &isnull));
			pv->has_cleared = DatumGetBool(SPI_getbinval(t, td, 7, &isnull));
			if (pv->usable)
			{
				AttrNumber	ba = get_attnum(base, pv->keycol);
				int32		tm;

				pv->view_keyatt = get_attnum(view, pv->keycol);
				pv->keytype = pv->keycoll = InvalidOid;
				if (ba != InvalidAttrNumber)
				{
					get_atttypetypmodcoll(base, ba, &pv->keytype, &tm, &pv->keycoll);
					get_typlenbyval(pv->keytype, &pv->keylen, &pv->keybyval);
				}
				pv->b_rel = get_relname_relid(psprintf("%s__b", b), gnsp);
				pv->b_u_rel = get_relname_relid(psprintf("%s__b_u", b), gnsp);
				pv->bk_rel = get_relname_relid(psprintf("%s__bk", b), gnsp);
				pv->bk_u_rel = get_relname_relid(psprintf("%s__bk_u", b), gnsp);
				pv->cleared_rel = get_relname_relid("cleared", gnsp);
				pv->cleared_idx = get_relname_relid("cleared_pkey", gnsp);
				pv->usable = pv->view_keyatt != InvalidAttrNumber && OidIsValid(pv->keytype) &&
					(!OidIsValid(pv->keycoll) || get_collation_isdeterministic(pv->keycoll)) &&
					OidIsValid(pv->b_rel) && OidIsValid(pv->bk_rel) && OidIsValid(pv->b_u_rel) &&
					OidIsValid(pv->bk_u_rel) && OidIsValid(pv->cleared_rel) && OidIsValid(pv->cleared_idx);
				if (pv->usable)
				{
					Oid			bi = pkey_of(pv->b_rel),
								bui = pkey_of(pv->b_u_rel),
								ki = pkey_of(pv->bk_rel),
								kui = pkey_of(pv->bk_u_rel),
								basei = pkey_of(base);

					pv->cleared_known = has_touch_trigger(pv->cleared_rel);
					pv->usable = OidIsValid(bi) && OidIsValid(bui) && OidIsValid(ki) && OidIsValid(kui) && OidIsValid(basei);
					if (pv->usable)
					{
						MemoryContext old = MemoryContextSwitchTo(TopMemoryContext);
						Relation	ir;

						if (pv->pr_b == NULL)
						{
							pv->pr_b = palloc0(sizeof(PtRel));
							pv->pr_b_u = palloc0(sizeof(PtRel));
							pv->pr_bk = palloc0(sizeof(PtRel));
							pv->pr_bk_u = palloc0(sizeof(PtRel));
							pv->pr_base = palloc0(sizeof(PtRel));
							pv->pr_bkk = palloc0(sizeof(PtRel));
							pv->pr_bkk_u = palloc0(sizeof(PtRel));
						}
						MemoryContextSwitchTo(old);
						ptrel_init(pv->pr_b, pv->b_rel, bi, true, pv->keycol, false);
						ptrel_init(pv->pr_b_u, pv->b_u_rel, bui, true, pv->keycol, false);
						ptrel_init(pv->pr_bk, pv->bk_rel, ki, true, pv->keycol, true);
						ptrel_init(pv->pr_bk_u, pv->bk_u_rel, kui, true, pv->keycol, true);
						ptrel_init(pv->pr_base, base, basei, false, pv->keycol, false);
						{
							Oid			kk = get_relname_relid(psprintf("%s__bk_key", b), gnsp),
										kku = get_relname_relid(psprintf("%s__bk_u_key", b), gnsp);

							pv->pr_bkk->rel = pv->pr_bkk_u->rel = InvalidOid;
							if (OidIsValid(kk) && OidIsValid(kku))
							{
								/* key first: no gn_branch scan key, the key is index column 1 */
								ptrel_init(pv->pr_bkk, pv->bk_rel, kk, false, pv->keycol, true);
								ptrel_init(pv->pr_bkk_u, pv->bk_u_rel, kku, false, pv->keycol, true);
								pv->pr_bkk->branch_att = pv->pr_bkk_u->branch_att = get_attnum(pv->bk_rel, "gn_branch");
							}
						}
						ir = index_open(basei, AccessShareLock);
						pv->key_eqfn = get_opcode(get_opfamily_member(ir->rd_opfamily[0], ir->rd_opcintype[0],
																	  ir->rd_opcintype[0], BTEqualStrategyNumber));
						index_close(ir, AccessShareLock);
						pv->usable = pv->pr_base->key_att != InvalidAttrNumber && pv->pr_b->key_att != InvalidAttrNumber &&
							pv->pr_bk->key_att != InvalidAttrNumber && OidIsValid(pv->key_eqfn);
						pv->hist_ok = pv->usable;
					}
				}
			}
		}
	}
	SPI_finish();
	return pv;
}

/*
 * One row by (gn_branch, key) of a branch table, or by key of the table itself, with the
 * statement's snapshot. Returns a copy, and the gn_fkey/gn_fxoff of a touched-key row.
 */
static HeapTuple
fetch_by_key(PtRel *pr, int32 branch, Datum key, RegProcedure eqfn, Snapshot snap, Datum *v1, Datum *v2)
{
	Relation	r = table_open(pr->rel, AccessShareLock);
	Relation	ir = index_open(pr->idx, AccessShareLock);
	ScanKeyData sk[2];
	SysScanDesc scan;
	HeapTuple	t,
				out = NULL;
	int			n = 0;

	if (pr->branch_att != 0)
		ScanKeyInit(&sk[n++], pr->branch_att, BTEqualStrategyNumber, F_INT4EQ, Int32GetDatum(branch));
	ScanKeyEntryInitialize(&sk[n++], 0, pr->key_att, BTEqualStrategyNumber, pr->idx_type, pr->idx_coll, eqfn, key);
	scan = systable_beginscan_ordered(r, ir, snap, n, sk);
	t = systable_getnext_ordered(scan, ForwardScanDirection);
	if (HeapTupleIsValid(t))
	{
		bool		isnull;

		out = heap_copytuple(t);
		if (pr->x1_att)
			*v1 = heap_getattr(out, pr->x1_att, RelationGetDescr(r), &isnull);
		if (pr->x2_att)
			*v2 = heap_getattr(out, pr->x2_att, RelationGetDescr(r), &isnull);
	}
	systable_endscan_ordered(scan);
	index_close(ir, AccessShareLock);
	table_close(r, AccessShareLock);
	return out;
}

/*
 * The touched-key rows of one key on the lineage's levels, in one scan of the (key, gn_branch)
 * index: lv[i] is set with that level's gn_fkey/gn_fxoff. False when the key has more rows than
 * it reads (many branches touched it): the caller probes level by level instead.
 */
#define PT_MAX_TOUCHES 64
static bool
touched_levels(PtRel *pr, Datum key, RegProcedure eqfn, Snapshot snap, Datum *lbv, int nb,
			   bool *lv, int64 *fk, int32 *fx)
{
	Relation	r = table_open(pr->rel, AccessShareLock);
	Relation	ir = index_open(pr->idx, AccessShareLock);
	ScanKeyData sk[1];
	SysScanDesc scan;
	HeapTuple	t;
	int			seen = 0;
	bool		ok = true;
	TupleDesc	td = RelationGetDescr(r);

	ScanKeyEntryInitialize(&sk[0], 0, pr->key_att, BTEqualStrategyNumber, pr->idx_type, pr->idx_coll, eqfn, key);
	scan = systable_beginscan_ordered(r, ir, snap, 1, sk);
	while (HeapTupleIsValid(t = systable_getnext_ordered(scan, ForwardScanDirection)))
	{
		bool		isnull;
		int32		br = DatumGetInt32(heap_getattr(t, pr->branch_att, td, &isnull));

		if (++seen > PT_MAX_TOUCHES)
		{
			ok = false;
			break;
		}
		for (int i = 0; i < nb; i++)
			if (DatumGetInt32(lbv[i]) == br)
			{
				lv[i] = true;
				fk[i] = DatumGetInt64(heap_getattr(t, pr->x1_att, td, &isnull));
				fx[i] = DatumGetInt32(heap_getattr(t, pr->x2_att, td, &isnull));
			}
	}
	systable_endscan_ordered(scan);
	index_close(ir, AccessShareLock);
	table_close(r, AccessShareLock);
	return ok;
}

/* the epoch and snapshot of a gnomon.coord datum */
static void
coord_parts(Datum coord, int16 *epoch, Datum *snap)
{
	HeapTupleHeader th = DatumGetHeapTupleHeader(coord);
	HeapTupleData tup;
	TupleDesc	td = lookup_rowtype_tupdesc(HeapTupleHeaderGetTypeId(th), HeapTupleHeaderGetTypMod(th));
	bool		isnull;

	tup.t_len = HeapTupleHeaderGetDatumLength(th);
	ItemPointerSetInvalid(&tup.t_self);
	tup.t_tableOid = InvalidOid;
	tup.t_data = th;
	*epoch = DatumGetInt16(heap_getattr(&tup, 1, td, &isnull));
	*snap = heap_getattr(&tup, 2, td, &isnull);
	ReleaseTupleDesc(td);
}

/* gnomon._vis(k, xoff, c) for a non-null coordinate */
static bool
vis_at(int64 k, int32 xoff, Datum coord)
{
	int16		epoch;
	Datum		snap;
	int64		ke = k >> 48;

	if (cc.valid && cc.cut_ok && coord == cc.f[CF_MAIN_CUT])
	{
		epoch = cc.cut_epoch;
		snap = cc.cut_snap;
	}
	else
		coord_parts(coord, &epoch, &snap);
	if (ke < epoch)
		return true;
	if (ke > epoch)
		return false;
	return DatumGetBool(DirectFunctionCall2(pg_visible_in_snapshot,
											Int64GetDatum((k & INT64CONST(281474976710655)) - xoff), snap));
}

/*
 * The highest partition a version the snapshot sees can be in. A version goes to the partition of
 * its writer's stamp (carry-forward keyframes and lazy baselines included, whatever stamp they
 * repeat), and a writer the snapshot sees stamped below the snapshot's xmax: its key is an xid,
 * the writer's own snapshot xmax, or a fresh xid of its own. So the partitions made ahead of the
 * writes (heartbeat) can be skipped. Only in the current epoch: an older one may come from another
 * cluster (logical cutover) whose xids do not compare with this one's.
 */
static int	point_epoch(void);

static int32
snap_part_hi(TableInfo *ti, Snapshot snap)
{
	FullTransactionId next = ReadNextFullTransactionId();
	uint64		ep = EpochFromFullTransactionId(next);
	uint64		fx;

	if (snap->xmax > XidFromFullTransactionId(next))
		ep--;					/* xmax is never ahead of the next xid: an earlier xid epoch */
	fx = (ep << 32) | snap->xmax;
	return (int32) ((int64) point_epoch() * 1000000 + Min(fx / (uint64) Max(ti->part_span, 1), 999999));
}

/* Has main's history of this key a version with key >= kxmin (visible to the snapshot)? */
static bool
main_changed_since(PtView *pv, Datum key, int64 kxmin, Snapshot snap)
{
	Relation	rel = table_open(pv->base, AccessShareLock);
	TableInfo  *ti = NULL;
	bool		changed = false;
	Datum		keys[1];
	VFound		f;
	Oid			relid = pv->base;
	int32		lo,
				hi;

	/* the shared-memory watermark answers without a probe when it can */
	if (wm_unchanged(pv->base, rel_c_trigger(rel), kxmin))
	{
		table_close(rel, AccessShareLock);
		return false;
	}
	if (table_info != NULL)
		ti = hash_search(table_info, &relid, HASH_FIND, NULL);
	if (ti == NULL || !ti->valid || ti->nleaves < 0)
	{
		SPI_connect();			/* the table's description is read through SPI the first time */
		ti = get_table_info(rel);
		if (ti->nleaves < 0)
			load_leaves(ti);
		SPI_finish();
	}
	keys[0] = key;
	lo = gnomon_part_of(ti, kxmin);
	hi = snap_part_hi(ti, snap);
	for (int i = 0; i < ti->nleaves && !changed; i++)
	{
		VLeaf	   *lf = &ti->leaves[i];

		if (lf->part != PG_INT32_MAX && (lf->part < lo || lf->part > hi))
			continue;
		latest_in_leaf(ti, lf, keys, snap, &f);
		if (f.found && f.key >= kxmin)
			changed = true;
	}
	table_close(rel, AccessShareLock);
	return changed;
}

/* Was a branch TRUNCATE ever recorded for the table? (then the general path) */
static bool
any_cleared(PtView *pv)
{
	ItemPointerData tid;
	TransactionId x;
	ScanKeyData sk[1];

	if (pv->cleared_known)
		return pv->has_cleared;
	ScanKeyInit(&sk[0], get_attnum(pv->cleared_rel, "tbl"), BTEqualStrategyNumber, F_INT4EQ, Int32GetDatum(pv->tid));
	row_token(pv->cleared_rel, pv->cleared_idx, sk, 1, false, &tid, &x);
	return ItemPointerIsValid(&tid);
}

typedef enum
{
	PT_NONE, PT_BASE, PT_HEAD, PT_GENERAL, PT_HIST
} PtResult;

/*
 * Main's row at a cutoff, rebuilt from its history in C: what the routing view's history arm
 * computes for one key. The newest version visible at the cutoff (partitions newest first; a
 * carry-forward keyframe repeats its source's stamp, so no lower partition holds a newer one; the
 * default partition is checked too), its keyframe in the same partition when it is a delta, and
 * each column from the delta's slot, else the keyframe's, else the column's default for columns
 * added since. False when it cannot answer (a value in the blob store, an unexpected column):
 * the caller reads the view.
 */
typedef struct VerTup
{
	bool		found;
	int64		key;
	int32		xoff;
	XLogRecPtr	lsn;
	int16		flags;
	int32		part;
	HeapTuple	tup;
	Oid			leaf;
} VerTup;

/* mode 0: the newest version visible at cut; mode 1: the newest keyframe before *pos, same partition */
static void
leaf_versions(const VLeaf *lf, Datum key, int64 kmax, Datum cut, int mode, const VerTup *pos, Snapshot snap, VerTup *out)
{
	Relation	heap = table_open(lf->heap, AccessShareLock);
	Relation	idx = index_open(lf->idx, AccessShareLock);
	ScanKeyData sk[2];
	IndexScanDesc scan;
	TupleTableSlot *slot;
	Oid			opno = get_opfamily_member(idx->rd_opfamily[0], idx->rd_opcintype[0], idx->rd_opcintype[0], BTEqualStrategyNumber);
	AttrNumber	ak = get_attnum(lf->heap, "gn_key"),
				ax = get_attnum(lf->heap, "gn_xoff"),
				al = get_attnum(lf->heap, "gn_lsn"),
				af = get_attnum(lf->heap, "gn_flags"),
				ap = get_attnum(lf->heap, "gn_part");

	out->found = false;
	ScanKeyEntryInitialize(&sk[0], 0, 1, BTEqualStrategyNumber, idx->rd_opcintype[0], idx->rd_indcollation[0], get_opcode(opno), key);
	ScanKeyEntryInitialize(&sk[1], 0, 2, BTLessEqualStrategyNumber, INT8OID, InvalidOid, F_INT8LE, Int64GetDatum(kmax));
#if PG_VERSION_NUM >= 180000
	scan = index_beginscan(heap, idx, snap, NULL, 2, 0);
#else
	scan = index_beginscan(heap, idx, snap, 2, 0);
#endif
	index_rescan(scan, sk, 2, NULL, 0);
	slot = table_slot_create(heap, NULL);
	while (index_getnext_slot(scan, BackwardScanDirection, slot))
	{
		bool		isnull;
		int64		k = DatumGetInt64(slot_getattr(slot, ak, &isnull));
		int32		x = DatumGetInt32(slot_getattr(slot, ax, &isnull));
		XLogRecPtr	l = DatumGetLSN(slot_getattr(slot, al, &isnull));
		int16		f = DatumGetInt16(slot_getattr(slot, af, &isnull));
		int32		p = DatumGetInt32(slot_getattr(slot, ap, &isnull));

		if (mode == 0 && !vis_at(k, x, cut))
			continue;
		if (mode == 1 && (k > pos->key || (k == pos->key && l >= pos->lsn) || p != pos->part || (f & 8) == 0))
			continue;
		out->found = true;
		out->key = k;
		out->xoff = x;
		out->lsn = l;
		out->flags = f;
		out->part = p;
		out->tup = ExecCopySlotHeapTuple(slot);
		out->leaf = lf->heap;
		break;
	}
	ExecDropSingleTupleTableSlot(slot);
	index_endscan(scan);
	index_close(idx, AccessShareLock);
	table_close(heap, AccessShareLock);
}

/* a version's value for one column: false if it is in the blob store */
static bool
version_value(const VerTup *t, TupleDesc td, const ValCol *c, Datum *val, bool *isnull)
{
	char		name[NAMEDATALEN];
	bool		ok = true;

	snprintf(name, sizeof(name), "gn_c%d", c->slot);
	*val = heap_getattr(t->tup, get_attnum(t->leaf, name), td, isnull);
	if (*isnull && c->large)
	{
		bool		hnull;

		snprintf(name, sizeof(name), "gn_h%d", c->slot);
		(void) heap_getattr(t->tup, get_attnum(t->leaf, name), td, &hnull);
		ok = hnull;				/* a hash: the value is in _gnomon.blob */
	}
	return ok;
}

/* is slot s in the version's mask (present) / within it (avail)? */
static void
mask_bits(const VerTup *t, TupleDesc td, int s, bool *present, bool *avail)
{
	bool		isnull;
	Datum		m = heap_getattr(t->tup, get_attnum(t->leaf, "gn_mask"), td, &isnull);

	*present = *avail = false;
	if (!isnull)
	{
		VarBit	   *vb = DatumGetVarBitP(m);

		*avail = VARBITLEN(vb) > s;
		*present = *avail && ((VARBITS(vb)[s / 8] >> (7 - s % 8)) & 1) != 0;
	}
}

static PtResult
rebuild_at(PtView *pv, Datum key, Datum cut, Snapshot snap, Datum *vals, bool *nulls)
{
	Relation	base = table_open(pv->base, AccessShareLock);
	TupleDesc	bd = RelationGetDescr(base);
	TableInfo  *ti = NULL;
	Oid			relid = pv->base;
	int64		kmax;
	VerTup		best = {0},
				kf = {0};
	PtResult	res = PT_GENERAL;
	Relation	vr,
				bl,
				kl;
	TupleDesc	vd;

	if (table_info != NULL)
		ti = hash_search(table_info, &relid, HASH_FIND, NULL);
	if (ti == NULL || !ti->valid || ti->nleaves < 0)
	{
		SPI_connect();
		ti = get_table_info(base);
		if (ti->nleaves < 0)
			load_leaves(ti);
		SPI_finish();
	}
	{
		int16		ep;
		Datum		sn;

		coord_parts(cut, &ep, &sn);
		kmax = ((int64) ep << 48) | (int64) DatumGetUInt64(DirectFunctionCall1(pg_snapshot_xmax, sn));
	}
	/*
	 * The newest version visible at the cutoff (leaves: the default partition, then newest first).
	 * Not only partitions up to the cutoff's: carry-forward keyframes and baselines repeat old
	 * stamps in later partitions. A key's stamps follow its writes (row locks), and so do
	 * partitions, so once a named partition has one, older ones hold nothing newer.
	 */
	{
		bool		named = false;
		int32		hi = snap_part_hi(ti, snap);

		for (int i = 0; i < ti->nleaves; i++)
		{
			const VLeaf *lf = &ti->leaves[i];
			VerTup		v;

			if (lf->part != PG_INT32_MAX && lf->part > hi)
				continue;
			if (lf->part != PG_INT32_MAX && named)
				break;
			leaf_versions(lf, key, kmax, cut, 0, NULL, snap, &v);
			if (!v.found)
				continue;
			if (!best.found || v.key > best.key || (v.key == best.key && v.lsn > best.lsn))
				best = v;
			if (lf->part != PG_INT32_MAX)
				named = true;
		}
	}
	if (!best.found || (best.flags & 4) != 0)
	{
		table_close(base, AccessShareLock);
		return PT_NONE;			/* not there at the cutoff, or deleted */
	}
	if ((best.flags & 8) == 0)
	{
		/* a delta: its keyframe, in the same partition (the leaf holding it) */
		for (int i = 0; i < ti->nleaves && !kf.found; i++)
			if (ti->leaves[i].heap == best.leaf)
				leaf_versions(&ti->leaves[i], key, best.key, cut, 1, &best, snap, &kf);
		if (!kf.found)
		{
			table_close(base, AccessShareLock);
			return PT_GENERAL;	/* unexpected: the view decides */
		}
	}
	/* the view's columns, in order */
	vr = relation_open(pv->view, AccessShareLock);
	vd = RelationGetDescr(vr);
	bl = table_open(best.leaf, AccessShareLock);
	kl = kf.found ? table_open(kf.leaf, AccessShareLock) : NULL;
	res = PT_HIST;
	for (int i = 0; i < vd->natts && res == PT_HIST; i++)
	{
		AttrNumber	b = get_attnum(pv->base, NameStr(TupleDescAttr(vd, i)->attname));
		const ValCol *c = NULL;
		bool		iskey = false;

		for (int k = 0; k < ti->nkeys; k++)
			if (ti->keyatt[k] == b)
				iskey = true;
		if (iskey)
		{
			vals[i] = heap_getattr(best.tup, get_attnum(best.leaf, NameStr(TupleDescAttr(vd, i)->attname)),
								   RelationGetDescr(bl), &nulls[i]);
			continue;
		}
		for (int v = 0; v < ti->nvals; v++)
			if (ti->vals[v].attnum == b)
				c = &ti->vals[v];
		if (b == InvalidAttrNumber || c == NULL)
		{
			res = PT_GENERAL;
			break;
		}
		{
			bool		pres,
						avail;

			mask_bits(&best, RelationGetDescr(bl), c->slot, &pres, &avail);
			if (pres)
			{
				if (!version_value(&best, RelationGetDescr(bl), c, &vals[i], &nulls[i]))
					res = PT_GENERAL;
			}
			else if ((best.flags & 8) != 0)
				vals[i] = getmissingattr(bd, b, &nulls[i]);
			else
			{
				mask_bits(&kf, RelationGetDescr(kl), c->slot, &pres, &avail);
				if (avail)
				{
					if (!version_value(&kf, RelationGetDescr(kl), c, &vals[i], &nulls[i]))
						res = PT_GENERAL;
				}
				else
					vals[i] = getmissingattr(bd, b, &nulls[i]);
			}
		}
	}
	if (kl)
		table_close(kl, AccessShareLock);
	table_close(bl, AccessShareLock);
	relation_close(vr, AccessShareLock);
	table_close(base, AccessShareLock);
	return res;
}

/* gnomon's current epoch (cached in gnomon._epoch on a primary once a session has read it) */
static int
point_epoch(void)
{
	static int	cached = -1;	/* a primary's session never outlives a timeline switch */
	const char *e;
	int			ep;
	bool		isnull;

	if (cached >= 0)
		return cached;
	e = GetConfigOption("gnomon._epoch", true, false);
	if (e != NULL && e[0] != '\0')
		return cached = atoi(e);
	SPI_connect();
	if (SPI_execute("select gnomon._epoch_ro()", true, 1) != SPI_OK_SELECT || SPI_processed != 1)
		elog(ERROR, "gnomon: cannot read the epoch");
	ep = DatumGetInt16(SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &isnull));
	SPI_finish();
	return ep;					/* cached once the session has the GUC (set by _epoch_ro) */
}

/*
 * Was this current version of a main row already the current one at the coordinate? It is
 * current now, so nothing has deleted it; if the transaction that wrote it is visible to the
 * coordinate's snapshot, the coordinate saw exactly this version. The raw xmin survives
 * freezing. Read as the newest full xid with those low bits, it can only err towards "later"
 * (an older wraparound cycle), which sends the read to the view. Only within one epoch: after a
 * logical cutover the xid counter starts over.
 */
static bool
row_unchanged_since(HeapTuple row, Datum coord)
{
	int16		cep;
	Datum		csnap;
	TransactionId x = HeapTupleHeaderGetRawXmin(row->t_data);
	FullTransactionId next;
	uint64		ep;

	if (!TransactionIdIsNormal(x))
		return false;
	if (cc.valid && cc.cut_ok && coord == cc.f[CF_MAIN_CUT])
	{
		cep = cc.cut_epoch;
		csnap = cc.cut_snap;
	}
	else
		coord_parts(coord, &cep, &csnap);
	if (cep != point_epoch())
		return false;
	next = ReadNextFullTransactionId();
	ep = EpochFromFullTransactionId(next);
	if (x > XidFromFullTransactionId(next))
		ep--;
	return DatumGetBool(DirectFunctionCall2(pg_visible_in_snapshot, UInt64GetDatum((ep << 32) | x), csnap));
}

static uint64 pt_stats[5];		/* how point reads were answered, for tests */

static PtResult
point_fast(PtView *pv, Datum key, HeapTuple *row, PtRel **src, Datum *hvals, bool *hnulls)
{
	Snapshot	snap = GetActiveSnapshot();
	int32		branch;
	bool		scratch;
	int64		kxmin;

	*row = NULL;
	ctx_fill();
	branch = DatumGetInt32(cc.f[CF_BRANCH]);
	scratch = strcmp(TextDatumGetCString(cc.f[CF_KIND]), "scratch") == 0;
	if (!cc.n[CF_VALID_AT])
		return PT_GENERAL;		/* valid time: bitemporal tables are not served here anyway */
	if (branch == 0 && cc.n[CF_ASOF])
	{
		/* main now: the table itself */
		*src = pv->pr_base;
		*row = fetch_by_key(pv->pr_base, 0, key, pv->key_eqfn, snap, NULL, NULL);
		return *row ? PT_BASE : PT_NONE;
	}
	if (branch != 0)
	{
		ArrayType  *lb = DatumGetArrayTypeP(cc.f[CF_LB]);
		ArrayType  *lc = DatumGetArrayTypeP(cc.f[CF_LC]);
		Datum	   *lbv,
				   *lcv;
		bool	   *lbn,
				   *lcn;
		int			nb,
					ncut;
		int16		ctyplen;
		bool		ctypbyval;
		char		ctypalign;

		if (!cc.n[CF_ASOF])
			return PT_GENERAL;	/* a branch as of a coordinate: rebuilt from its history */
		if (scratch && !pv->scratch_view)
			return PT_GENERAL;	/* the logged views refuse a scratch branch: let the view say so */
		/*
		 * 1. touched at some lineage level before that level's cutoff? On the branch itself the
		 * touched-key row comes first: every head row has one (the branch write inserts it first,
		 * in the same transaction, and only dropping the branch deletes it), so an untouched key
		 * needs no head probe.
		 */
		deconstruct_array(lb, INT4OID, 4, true, TYPALIGN_INT, &lbv, &lbn, &nb);
		get_typlenbyvalalign(ARR_ELEMTYPE(lc), &ctyplen, &ctypbyval, &ctypalign);
		deconstruct_array(lc, ARR_ELEMTYPE(lc), ctyplen, ctypbyval, ctypalign, &lcv, &lcn, &ncut);
		/* the touched-key filter: no level's bits set means no level touched the key */
		if (tf_usable(pv->bk_rel) && (!pv->scratch_view || tf_usable(pv->bk_u_rel)))
		{
			bool		maybe = false;

			for (int i = 0; i < nb && !maybe; i++)
				for (int u = 0; u < (pv->scratch_view ? 2 : 1) && !maybe; u++)
					maybe = tf_maybe(u ? pv->bk_u_rel : pv->bk_rel, DatumGetInt32(lbv[i]), key, pv->keylen, pv->keybyval);
			if (!maybe)
			{
				tf_skips++;
				gn_count(GC_FILTER_SKIPS);
				if (any_cleared(pv))
					return PT_GENERAL;
				goto main_at_cutoff;
			}
			tf_scans++;
			gn_count(GC_FILTER_SCANS);
		}
		{
			bool	   *lv[2];
			int64	   *lfk[2];
			int32	   *lfx[2];
			bool		bulk[2] = {false, false};
			int			nu = pv->scratch_view ? 2 : 1;

			for (int u = 0; u < nu; u++)
			{
				PtRel	   *kk = u ? pv->pr_bkk_u : pv->pr_bkk;

				lv[u] = palloc0(sizeof(bool) * nb);
				lfk[u] = palloc0(sizeof(int64) * nb);
				lfx[u] = palloc0(sizeof(int32) * nb);
				if (OidIsValid(kk->rel))
					bulk[u] = touched_levels(kk, key, pv->key_eqfn, snap, lbv, nb, lv[u], lfk[u], lfx[u]);
			}
			for (int i = 0; i < nb; i++)
			{
				bool		now = i >= ncut || lcn[i];

				for (int u = 0; u < nu; u++)
				{
					Datum		fk = 0,
								fx = 0;

					if (bulk[u])
					{
						if (!lv[u][i])
							continue;
						fk = Int64GetDatum(lfk[u][i]);
						fx = Int32GetDatum(lfx[u][i]);
					}
					else
					{
						HeapTuple	bk = fetch_by_key(u ? pv->pr_bk_u : pv->pr_bk, DatumGetInt32(lbv[i]), key, pv->key_eqfn, snap,
													  &fk, &fx);

						if (bk == NULL)
							continue;
						heap_freetuple(bk);
					}
					if (!now && !vis_at(DatumGetInt64(fk), DatumGetInt32(fx), lcv[i]))
						continue;
					if (i > 0 || !now)
						return PT_GENERAL;	/* an ancestor's row, from its history */
					/* the branch's own head, or deleted on the branch */
					*src = scratch ? pv->pr_b_u : pv->pr_b;
					*row = fetch_by_key(scratch ? pv->pr_b_u : pv->pr_b, branch, key, pv->key_eqfn, snap, NULL, NULL);
					return *row ? PT_HEAD : PT_NONE;
				}
				/* untouched on the branch: a branch TRUNCATE hides main's rows (the view's rules) */
				if (i == 0 && any_cleared(pv))
					return PT_GENERAL;
			}
		}
	}
	/* 3. main at the cutoff: the current row, unless the key changed since */
main_at_cutoff:
	if (cc.n[CF_MAIN_CUT] || cc.n[CF_MAIN_XMIN])
		return PT_GENERAL;
	if (!vis_at(pv->track_key, pv->track_xoff, cc.f[CF_MAIN_CUT]))
		return PT_GENERAL;		/* tracked after the cutoff: the view (its rows, or its error) */
	*src = pv->pr_base;
	*row = fetch_by_key(pv->pr_base, 0, key, pv->key_eqfn, snap, NULL, NULL);
	if (*row)
	{
		/* main's current version, if it is the one the cutoff saw; else rebuilt from history */
		if (row_unchanged_since(*row, cc.f[CF_MAIN_CUT]))
			return PT_BASE;
		heap_freetuple(*row);
		*row = NULL;
		return pv->hist_ok ? rebuild_at(pv, key, cc.f[CF_MAIN_CUT], snap, hvals, hnulls) : PT_GENERAL;
	}
	/* no row now: deleted since the cutoff, or never there */
	kxmin = DatumGetInt64(cc.f[CF_MAIN_XMIN]);
	if (!main_changed_since(pv, key, kxmin, snap))
		return PT_NONE;
	return pv->hist_ok ? rebuild_at(pv, key, cc.f[CF_MAIN_CUT], snap, hvals, hnulls) : PT_GENERAL;
}

typedef void (*PtEmit) (void *arg, TupleDesc out, Datum *vals, bool *nulls);

/* the view's columns (by name, in order) -> this table's attribute numbers; NULL if they differ */
static AttrNumber *
ptrel_map(PtRel *pr, Oid view, int natts)
{
	if (pr->map == NULL)
	{
		MemoryContext old = MemoryContextSwitchTo(TopMemoryContext);
		Relation	vr = relation_open(view, AccessShareLock);
		TupleDesc	vd = RelationGetDescr(vr);

		pr->map = palloc(sizeof(AttrNumber) * vd->natts);
		pr->nmap = vd->natts;
		for (int i = 0; i < vd->natts; i++)
			pr->map[i] = get_attnum(pr->rel, NameStr(TupleDescAttr(vd, i)->attname));
		relation_close(vr, AccessShareLock);
		MemoryContextSwitchTo(old);
	}
	return pr->nmap == natts ? pr->map : NULL;
}

/*
 * The rows of "select * from <view> where <key column> = key" (out: the view's columns), from
 * the fast path when it can answer, else from the view itself with the statement's snapshot.
 */
static void
point_answer(Oid view, AttrNumber keyatt, Oid keytype, Datum key, TupleDesc out, PtEmit emit, void *arg)
{
	PtView	   *pv = pt_view(view);
	PtResult	r = PT_GENERAL;
	HeapTuple	row = NULL;
	PtRel	   *src = NULL;
	Datum	   *vals = palloc(sizeof(Datum) * out->natts);
	bool	   *nulls = palloc(sizeof(bool) * out->natts);

	if (pv->usable && pv->view_keyatt == keyatt && pv->keytype == keytype && !RecoveryInProgress())
		r = point_fast(pv, key, &row, &src, vals, nulls);
	pt_stats[r]++;
	gn_count(r);
	if (r == PT_HIST)
		emit(arg, out, vals, nulls);	/* rebuilt in the view's column order */
	else if (r == PT_BASE || r == PT_HEAD)
	{
		Relation	sr = table_open(src->rel, AccessShareLock);
		AttrNumber *map = ptrel_map(src, view, out->natts);

		if (map == NULL)
			elog(ERROR, "gnomon: the point read's columns do not match view %s", get_rel_name(view));
		for (int i = 0; i < out->natts; i++)
		{
			if (map[i] == InvalidAttrNumber)
			{
				vals[i] = (Datum) 0;
				nulls[i] = true;
			}
			else
				vals[i] = heap_getattr(row, map[i], RelationGetDescr(sr), &nulls[i]);
		}
		emit(arg, out, vals, nulls);
		table_close(sr, AccessShareLock);
	}
	else if (r == PT_GENERAL)
	{
		Oid			argt[1] = {keytype};
		Datum		argv[1] = {key};
		char	   *sql;
		bool		prev = in_point_fallback;

		sql = psprintf("select * from %s.%s where %s = $1",
					   quote_identifier(get_namespace_name(get_rel_namespace(view))), quote_identifier(get_rel_name(view)),
					   quote_identifier(get_attname(view, keyatt, false)));
		in_point_fallback = true;
		PG_TRY();
		{
			SPI_connect();
			if (SPI_execute_with_args(sql, 1, argt, argv, NULL, true, 0) != SPI_OK_SELECT)
				elog(ERROR, "gnomon: routing view read failed");
			for (uint64 i = 0; i < SPI_processed; i++)
			{
				for (int c = 0; c < out->natts; c++)
					vals[c] = SPI_getbinval(SPI_tuptable->vals[i], SPI_tuptable->tupdesc, c + 1, &nulls[c]);
				emit(arg, out, vals, nulls);
			}
			SPI_finish();
		}
		PG_FINALLY();
		{
			in_point_fallback = prev;
		}
		PG_END_TRY();
	}
}

static void
emit_tuplestore(void *arg, TupleDesc out, Datum *vals, bool *nulls)
{
	tuplestore_putvalues((Tuplestorestate *) arg, out, vals, nulls);
}

/* The function form: for direct calls, and for plans made without the module's path hook. */
PG_FUNCTION_INFO_V1(gnomon_c_point);
Datum
gnomon_c_point(PG_FUNCTION_ARGS)
{
	Oid			view = PG_GETARG_OID(0);
	AttrNumber	keyatt = PG_GETARG_INT16(1);
	ReturnSetInfo *rsi = (ReturnSetInfo *) fcinfo->resultinfo;

	if (get_rel_relkind(view) != RELKIND_VIEW)
		ereport(ERROR, (errcode(ERRCODE_WRONG_OBJECT_TYPE), errmsg("gnomon: %u is not a view", view)));
	if (pg_class_aclcheck(view, GetUserId(), ACL_SELECT) != ACLCHECK_OK)
		aclcheck_error(ACLCHECK_NO_PRIV, OBJECT_VIEW, get_rel_name(view));
	InitMaterializedSRF(fcinfo, MAT_SRF_USE_EXPECTED_DESC);
	if (PG_ARGISNULL(2))
		return (Datum) 0;
	point_answer(view, keyatt, get_fn_expr_argtype(fcinfo->flinfo, 2), PG_GETARG_DATUM(2), rsi->setDesc,
				 emit_tuplestore, rsi->setResult);
	return (Datum) 0;
}

/*
 * The custom scan: the planner replaces the function scan of _gnomon.c_point with a
 * node that answers directly into its scan slot (no function call, no tuplestore). It scans no
 * relation of its own (scanrelid 0); its scan tuple is the view's row (custom_scan_tlist).
 */
typedef struct PtScanState
{
	CustomScanState css;
	Oid			view;
	AttrNumber	keyatt;
	Oid			keytype;
	ExprState  *keyexpr;
	MemoryContext rowcxt;
	List	   *rows;			/* of Datum arrays: natts values, then natts null flags */
	ListCell   *next;
	bool		done;
} PtScanState;

static Plan *pt_plan_path(PlannerInfo *root, RelOptInfo *rel, struct CustomPath *best_path, List *tlist,
						  List *clauses, List *custom_plans);
static Node *pt_create_state(CustomScan *cscan);
static void pt_begin(CustomScanState *node, EState *estate, int eflags);
static TupleTableSlot *pt_exec(CustomScanState *node);
static void pt_end(CustomScanState *node);
static void pt_rescan(CustomScanState *node);
static void pt_explain(CustomScanState *node, List *ancestors, ExplainState *es);

static const CustomPathMethods pt_path_methods = {
	.CustomName = "GnomonPoint",
	.PlanCustomPath = pt_plan_path,
};
static const CustomScanMethods pt_scan_methods = {
	.CustomName = "GnomonPoint",
	.CreateCustomScanState = pt_create_state,
};
static const CustomExecMethods pt_exec_methods = {
	.CustomName = "GnomonPoint",
	.BeginCustomScan = pt_begin,
	.ExecCustomScan = pt_exec,
	.EndCustomScan = pt_end,
	.ReScanCustomScan = pt_rescan,
	.ExplainCustomScan = pt_explain,
};
static set_rel_pathlist_hook_type prev_set_rel_pathlist = NULL;

static void
pt_set_rel_pathlist(PlannerInfo *root, RelOptInfo *rel, Index rti, RangeTblEntry *rte)
{
	RangeTblFunction *rtf;
	FuncExpr   *fe;
	CustomPath *cp;

	if (prev_set_rel_pathlist)
		prev_set_rel_pathlist(root, rel, rti, rte);
	if (rte->rtekind != RTE_FUNCTION || list_length(rte->functions) != 1 || rte->funcordinality ||
		!OidIsValid(c_point_fn) || rel->reloptkind != RELOPT_BASEREL)
		return;
	rtf = linitial_node(RangeTblFunction, rte->functions);
	if (!IsA(rtf->funcexpr, FuncExpr))
		return;
	fe = (FuncExpr *) rtf->funcexpr;
	if (fe->funcid != c_point_fn || fe->funcformat != COERCE_SQL_SYNTAX || list_length(fe->args) != 3 || !IsA(linitial(fe->args), Const) ||
		!IsA(lsecond(fe->args), Const) || contain_var_clause(lthird(fe->args)) || bms_num_members(rel->lateral_relids) > 0)
		return;
	cp = makeNode(CustomPath);
	cp->path.pathtype = T_CustomScan;
	cp->path.parent = rel;
	cp->path.pathtarget = rel->reltarget;
	cp->path.param_info = NULL;
	cp->path.parallel_aware = false;
	cp->path.parallel_safe = false;
	cp->path.parallel_workers = 0;
	cp->path.rows = 1;
	cp->path.startup_cost = 0;
	cp->path.total_cost = 0.01;
	cp->path.pathkeys = NIL;
	cp->flags = 0;
	cp->custom_paths = NIL;
	cp->custom_private = list_make1(fe);
	cp->methods = &pt_path_methods;
	rel->pathlist = NIL;
	rel->partial_pathlist = NIL;
	add_path(rel, &cp->path);
}

static Plan *
pt_plan_path(PlannerInfo *root, RelOptInfo *rel, struct CustomPath *best_path, List *tlist, List *clauses,
			 List *custom_plans)
{
	CustomScan *cs = makeNode(CustomScan);
	FuncExpr   *fe = linitial(best_path->custom_private);
	RangeTblEntry *rte = planner_rt_fetch(rel->relid, root);
	RangeTblFunction *rtf = linitial_node(RangeTblFunction, rte->functions);
	ListCell   *lt,
			   *lm,
			   *lc;
	AttrNumber	n = 0;
	List	   *names = rtf->funccolnames;

	Oid			view = DatumGetObjectId(linitial_node(Const, fe->args)->constvalue);
	Index		vrti = 0;

	cs->scan.plan.targetlist = tlist;
	cs->scan.plan.qual = extract_actual_clauses(clauses, false);
	cs->flags = best_path->flags;
	cs->custom_plans = NIL;
	cs->custom_exprs = list_make1(copyObject(lthird(fe->args)));
	cs->custom_private = list_make2(copyObject(linitial(fe->args)), copyObject(lsecond(fe->args)));
	cs->custom_scan_tlist = NIL;
	cs->methods = &pt_scan_methods;
	/*
	 * The scan tuple is the view's row, and the view is in the range table (unreferenced, from
	 * the rewrite): scanning "it" lets the executor use the view's cached tuple descriptor. The
	 * function's columns are the view's, in order, and scan-level Vars read the scan tuple.
	 */
	for (Index i = 1; i <= (Index) list_length(root->parse->rtable); i++)
	{
		RangeTblEntry *r = rt_fetch(i, root->parse->rtable);

		if (r->rtekind == RTE_RELATION && r->relid == view)
			vrti = i;
	}
	if (vrti > 0)
	{
		cs->scan.scanrelid = vrti;
		return &cs->scan.plan;
	}
	cs->scan.scanrelid = 0;
	forthree(lt, rtf->funccoltypes, lm, rtf->funccoltypmods, lc, rtf->funccolcollations)
	{
		n++;
		cs->custom_scan_tlist = lappend(cs->custom_scan_tlist,
										makeTargetEntry((Expr *) makeVar(rel->relid, n, lfirst_oid(lt), lfirst_int(lm), lfirst_oid(lc), 0),
														n, pstrdup(strVal(list_nth(names, n - 1))), false));
	}
	return &cs->scan.plan;
}

static Node *
pt_create_state(CustomScan *cscan)
{
	PtScanState *ps = palloc0(sizeof(PtScanState));

	NodeSetTag(ps, T_CustomScanState);
	ps->css.methods = &pt_exec_methods;
#if PG_VERSION_NUM >= 160000
	ps->css.slotOps = &TTSOpsVirtual;	/* (before 16 the scan slot is always virtual) */
#endif
	ps->view = DatumGetObjectId(linitial_node(Const, cscan->custom_private)->constvalue);
	ps->keyatt = DatumGetInt16(lsecond_node(Const, cscan->custom_private)->constvalue);
	ps->keytype = exprType(linitial(cscan->custom_exprs));
	return (Node *) ps;
}

static void
pt_begin(CustomScanState *node, EState *estate, int eflags)
{
	PtScanState *ps = (PtScanState *) node;
	CustomScan *cs = (CustomScan *) node->ss.ps.plan;

	ps->keyexpr = ExecInitExpr(linitial(cs->custom_exprs), (PlanState *) node);
	ps->rowcxt = AllocSetContextCreate(CurrentMemoryContext, "gnomon point rows", ALLOCSET_SMALL_SIZES);
	ps->rows = NIL;
	ps->done = false;
}

static void
emit_rows(void *arg, TupleDesc out, Datum *vals, bool *nulls)
{
	PtScanState *ps = (PtScanState *) arg;
	MemoryContext old = MemoryContextSwitchTo(ps->rowcxt);
	Datum	   *r = palloc(sizeof(Datum) * out->natts * 2);

	for (int i = 0; i < out->natts; i++)
	{
		Form_pg_attribute a = TupleDescAttr(out, i);

		r[out->natts + i] = BoolGetDatum(nulls[i]);
		r[i] = nulls[i] ? (Datum) 0 : datumCopy(vals[i], a->attbyval, a->attlen);
	}
	ps->rows = lappend(ps->rows, r);
	MemoryContextSwitchTo(old);
}

static TupleTableSlot *
pt_next(ScanState *ss)
{
	PtScanState *ps = (PtScanState *) ss;
	TupleTableSlot *slot = ss->ss_ScanTupleSlot;
	TupleDesc	td = slot->tts_tupleDescriptor;
	Datum	   *r;

	if (!ps->done)
	{
		ExprContext *econtext = ss->ps.ps_ExprContext;
		bool		isnull;
		Datum		key;

		ps->done = true;
		ResetExprContext(econtext);
		key = ExecEvalExprSwitchContext(ps->keyexpr, econtext, &isnull);
		if (!isnull)
			point_answer(ps->view, ps->keyatt, ps->keytype, key, td, emit_rows, ps);
		ps->next = list_head(ps->rows);
	}
	ExecClearTuple(slot);
	if (ps->next == NULL)
		return slot;
	r = lfirst(ps->next);
	ps->next = lnext(ps->rows, ps->next);
	for (int i = 0; i < td->natts; i++)
	{
		slot->tts_values[i] = r[i];
		slot->tts_isnull[i] = DatumGetBool(r[td->natts + i]);
	}
	return ExecStoreVirtualTuple(slot);
}

static bool
pt_recheck(ScanState *ss, TupleTableSlot *slot)
{
	return true;
}

static TupleTableSlot *
pt_exec(CustomScanState *node)
{
	return ExecScan(&node->ss, (ExecScanAccessMtd) pt_next, (ExecScanRecheckMtd) pt_recheck);
}

static void
pt_end(CustomScanState *node)
{
	PtScanState *ps = (PtScanState *) node;

	if (ps->rowcxt)
		MemoryContextDelete(ps->rowcxt);
	ps->rowcxt = NULL;
}

static void
pt_rescan(CustomScanState *node)
{
	PtScanState *ps = (PtScanState *) node;

	MemoryContextReset(ps->rowcxt);
	ps->rows = NIL;
	ps->done = false;
}

static void
pt_explain(CustomScanState *node, List *ancestors, ExplainState *es)
{
	PtScanState *ps = (PtScanState *) node;

	ExplainPropertyText("Routing View", quote_qualified_identifier(get_namespace_name(get_rel_namespace(ps->view)),
																	get_rel_name(ps->view)), es);
}

/* counts of point reads by how they were answered: none, main's row, the branch head, the view,
 * main's row rebuilt from its history */
PG_FUNCTION_INFO_V1(gnomon_c_point_stats);
Datum
gnomon_c_point_stats(PG_FUNCTION_ARGS)
{
	Datum		d[7];

	for (int i = 0; i < 5; i++)
		d[i] = Int64GetDatum((int64) pt_stats[i]);
	d[5] = Int64GetDatum((int64) tf_skips);	/* touched-key scans the filter saved */
	d[6] = Int64GetDatum((int64) tf_scans);	/* and the ones it could not */
	PG_RETURN_ARRAYTYPE_P(construct_array(d, 7, INT8OID, 8, true, TYPALIGN_DOUBLE));
}

/*
 * The feed's C arm. The query, built by _gnomon.feed_c_arm, scans the
 * partitions overlapping a window one by one in row-index order (partition, row key, version key
 * and LSN) and
 * gives each version's own values with, per column, whether the version stores it (present) and,
 * for a keyframe, whether it had the column (available). One pass rebuilds every image: per row
 * key and partition the keyframe's values and the previous image stay in memory, a version's
 * image is its own values over its keyframe's, and its predecessor's image is the one before.
 * Partitions are self-contained (a key's first write in one carries a keyframe forward), so a
 * group never needs a row outside the scan. Versions in the window are returned with the arms'
 * columns, so gnomon.changes orders them with the others.
 *
 *   q: the query (parameters $1..$11 as the arms'), cols: column names, kinds: 'k' for a key
 *   column (one output: its value) or 'v' (three: value, present, available), missing: per
 *   column, the value a version without it reads (a column added after its keyframe)
 */
static Datum
feed_image(int ncol, char **names, Datum *vals, bool *nulls)
{
	JsonbParseState *st = NULL;
	JsonbValue *res;

	pushJsonbValue(&st, WJB_BEGIN_OBJECT, NULL);
	for (int i = 0; i < ncol; i++)
	{
		JsonbValue	k,
					v;

		k.type = jbvString;
		k.val.string.val = names[i];
		k.val.string.len = strlen(names[i]);
		pushJsonbValue(&st, WJB_KEY, &k);
		if (nulls[i])
		{
			v.type = jbvNull;
			pushJsonbValue(&st, WJB_VALUE, &v);
		}
		else
		{
			Jsonb	   *jb = DatumGetJsonbP(vals[i]);

			v.type = jbvBinary;
			v.val.binary.data = &jb->root;
			v.val.binary.len = VARSIZE(jb) - VARHDRSZ;
			pushJsonbValue(&st, WJB_VALUE, &v);
		}
	}
	res = pushJsonbValue(&st, WJB_END_OBJECT, NULL);
	return JsonbPGetDatum(JsonbValueToJsonb(res));
}

PG_FUNCTION_INFO_V1(gnomon_c_feed);
Datum
gnomon_c_feed(PG_FUNCTION_ARGS)
{
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	char	   *q = text_to_cstring(PG_GETARG_TEXT_PP(0));
	ArrayType  *colarr = PG_GETARG_ARRAYTYPE_P(1);
	char	   *kinds = text_to_cstring(PG_GETARG_TEXT_PP(2));
	Jsonb	   *missing = PG_GETARG_JSONB_P(3);
	bool		with_old = PG_GETARG_BOOL(4);
	Oid			rel = PG_GETARG_OID(5);
	Datum		tname = PG_GETARG_DATUM(6);
	Datum	   *cold;
	bool	   *cnull;
	int			ncol;
	char	  **names;
	Datum	   *miss;
	bool	   *missnull;
	Oid			argtypes[11];
	Datum		args[11];
	char		argnulls[11];
	Portal		portal;
	MemoryContext outer = CurrentMemoryContext;
	MemoryContext groupcx,
				rowcx;
	/* per group: the current key and partition, the keyframe's values, the previous image */
	Datum		gkey = (Datum) 0;
	bool		have_group = false;
	int32		gpart = 0;
	Datum	   *kfval;
	bool	   *kfnull,
			   *kfavail;
	bool		have_kf = false;
	Datum		prev = (Datum) 0;
	bool		have_prev = false;
	int			prev_flags = 0;
	Datum	   *img;
	bool	   *imgnull;

	InitMaterializedSRF(fcinfo, 0);
	deconstruct_array(colarr, TEXTOID, -1, false, TYPALIGN_INT, &cold, &cnull, &ncol);
	if ((int) strlen(kinds) != ncol)
		elog(ERROR, "gnomon_c_feed: %d columns, %d kinds", ncol, (int) strlen(kinds));
	names = palloc(sizeof(char *) * ncol);
	miss = palloc0(sizeof(Datum) * ncol);
	missnull = palloc(sizeof(bool) * ncol);
	for (int i = 0; i < ncol; i++)
	{
		JsonbValue *e = getIthJsonbValueFromContainer(&missing->root, i);

		names[i] = TextDatumGetCString(cold[i]);
		missnull[i] = (e == NULL || e->type == jbvNull);
		if (!missnull[i])
			miss[i] = JsonbPGetDatum(JsonbValueToJsonb(e));
	}
	for (int i = 0; i < 11; i++)
	{
		argtypes[i] = get_fn_expr_argtype(fcinfo->flinfo, 7 + i);
		args[i] = PG_ARGISNULL(7 + i) ? (Datum) 0 : PG_GETARG_DATUM(7 + i);
		argnulls[i] = PG_ARGISNULL(7 + i) ? 'n' : ' ';
	}
	groupcx = AllocSetContextCreate(outer, "gnomon feed group", ALLOCSET_DEFAULT_SIZES);
	rowcx = AllocSetContextCreate(outer, "gnomon feed row", ALLOCSET_DEFAULT_SIZES);
	kfval = palloc0(sizeof(Datum) * ncol);
	kfnull = palloc(sizeof(bool) * ncol);
	kfavail = palloc0(sizeof(bool) * ncol);
	img = palloc0(sizeof(Datum) * ncol);
	imgnull = palloc(sizeof(bool) * ncol);

	SPI_connect();
	portal = SPI_cursor_open_with_args(NULL, q, 11, argtypes, args, argnulls, true, 0);
	for (;;)
	{
		SPI_cursor_fetch(portal, true, 2000);
		if (SPI_processed == 0)
			break;
		for (uint64 r = 0; r < SPI_processed; r++)
		{
			HeapTuple	tup = SPI_tuptable->vals[r];
			TupleDesc	td = SPI_tuptable->tupdesc;
			bool		isnull;
			int64		vkey = DatumGetInt64(SPI_getbinval(tup, td, 1, &isnull));
			Datum		vlsn = SPI_getbinval(tup, td, 2, &isnull);
			int			flags = DatumGetInt32(SPI_getbinval(tup, td, 3, &isnull));
			int64		xoff = DatumGetInt64(SPI_getbinval(tup, td, 4, &isnull));
			bool		rolenull;
			Datum		role = SPI_getbinval(tup, td, 5, &rolenull);
			int32		part = DatumGetInt32(SPI_getbinval(tup, td, 6, &isnull));
			Datum		rk = SPI_getbinval(tup, td, 7, &isnull);
			bool		inwin = DatumGetBool(SPI_getbinval(tup, td, 8, &isnull)) && !isnull;
			bool		keyframe = (flags & 8) != 0;
			int			f = 9;
			MemoryContext old;

			MemoryContextReset(rowcx);
			old = MemoryContextSwitchTo(rowcx);
			/* a new row key or partition starts a group */
			if (!have_group || part != gpart ||
				!DatumGetBool(DirectFunctionCall2(jsonb_eq, rk, gkey)))
			{
				MemoryContextReset(groupcx);
				MemoryContextSwitchTo(groupcx);
				gkey = datumCopy(rk, false, -1);
				MemoryContextSwitchTo(rowcx);
				gpart = part;
				have_group = true;
				have_kf = false;
				have_prev = false;
			}
			for (int i = 0; i < ncol; i++)
			{
				bool		snull;
				Datum		sv = SPI_getbinval(tup, td, f, &snull);

				if (kinds[i] == 'k')
				{
					img[i] = sv;
					imgnull[i] = snull;
					f += 1;
					continue;
				}
				{
					bool		pn,
								an;
					bool		present = DatumGetBool(SPI_getbinval(tup, td, f + 1, &pn)) && !pn;
					bool		avail = DatumGetBool(SPI_getbinval(tup, td, f + 2, &an)) && !an;

					if (present)
					{
						img[i] = sv;
						imgnull[i] = snull;
					}
					else if (!keyframe && have_kf && kfavail[i])
					{
						img[i] = kfval[i];
						imgnull[i] = kfnull[i];
					}
					else
					{
						img[i] = miss[i];
						imgnull[i] = missnull[i];
					}
					if (keyframe)
					{
						/* this version is the group's keyframe from here on */
						MemoryContextSwitchTo(groupcx);
						kfavail[i] = avail;
						kfnull[i] = snull;
						kfval[i] = snull ? (Datum) 0 : datumCopy(sv, false, -1);
						MemoryContextSwitchTo(rowcx);
					}
				}
				f += 3;
			}
			if (keyframe)
				have_kf = true;
			if (inwin)
			{
				Datum		values[10];
				bool		nulls[10] = {false};
				Datum		image = feed_image(ncol, names, img, imgnull);
				uint64		x = (uint64) ((vkey & INT64CONST(281474976710655)) - xoff);

				values[0] = Int64GetDatum(vkey);
				values[1] = vlsn;
				values[2] = ObjectIdGetDatum(rel);
				values[3] = tname;
				values[4] = rk;
				values[5] = CStringGetTextDatum((flags & 1) ? "insert" : (flags & 4) ? "delete" : "update");
				values[6] = UInt64GetDatum(x);	/* xid8 */
				values[7] = role;
				nulls[7] = rolenull;
				values[8] = image;
				nulls[8] = (flags & 4) != 0;
				nulls[9] = !(with_old && (flags & 1) == 0 && have_prev && (prev_flags & 4) == 0);
				values[9] = nulls[9] ? (Datum) 0 : prev;
				MemoryContextSwitchTo(outer);
				tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc, values, nulls);
				MemoryContextSwitchTo(rowcx);
				if (with_old)
				{
					MemoryContextSwitchTo(groupcx);
					prev = datumCopy(image, false, -1);
					MemoryContextSwitchTo(rowcx);
				}
			}
			else if (with_old)
			{
				Datum		image = feed_image(ncol, names, img, imgnull);

				MemoryContextSwitchTo(groupcx);
				prev = datumCopy(image, false, -1);
				MemoryContextSwitchTo(rowcx);
			}
			have_prev = true;
			prev_flags = flags;
			MemoryContextSwitchTo(old);
		}
		SPI_freetuptable(SPI_tuptable);
	}
	SPI_cursor_close(portal);
	SPI_finish();
	MemoryContextDelete(rowcx);
	MemoryContextDelete(groupcx);
	return (Datum) 0;
}

/* the shared counters as (name, value) rows; none when the module is not preloaded */
PG_FUNCTION_INFO_V1(gnomon_c_counters);
Datum
gnomon_c_counters(PG_FUNCTION_ARGS)
{
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;

	InitMaterializedSRF(fcinfo, 0);
	if (gn_counters == NULL)
		return (Datum) 0;
	for (int i = 0; i < GN_NCOUNTERS; i++)
	{
		Datum		values[2] = {CStringGetTextDatum(gn_counter_names[i]),
		Int64GetDatum((int64) pg_atomic_read_u64(&gn_counters->c[i]))};
		bool		nulls[2] = {false, false};

		tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc, values, nulls);
	}
	return (Datum) 0;
}

/*
 * The rewrite, on the analyzed query, before views are expanded: the query reads a function
 * instead of the view. The view stays in the range table, unreferenced, so the rewriter does not
 * expand it, and so that it is still locked, permission-checked (column grants included) and a
 * dependency of cached plans (gnomon regenerates views: the plan is rebuilt). A cached plan
 * therefore never holds the routing view's arms.
 */

static Node *
key_operand(Node *qual, PtView *pv)
{
	OpExpr	   *op;
	Node	   *l,
			   *r;
	Oid			eqop;

	if (!IsA(qual, OpExpr))
		return NULL;
	op = (OpExpr *) qual;
	if (list_length(op->args) != 2)
		return NULL;
	l = linitial(op->args);
	r = lsecond(op->args);
	if (IsA(r, Var) && !IsA(l, Var))
	{
		Node	   *tmp = l;

		l = r;
		r = tmp;
	}
	if (!IsA(l, Var) || ((Var *) l)->varno != 1 || ((Var *) l)->varlevelsup != 0 || ((Var *) l)->varattno != pv->view_keyatt)
		return NULL;
	if (!(IsA(r, Const) || (IsA(r, Param) && ((Param *) r)->paramkind == PARAM_EXTERN)))
		return NULL;
	if (exprType(r) != pv->keytype || exprType(l) != pv->keytype)
		return NULL;
	/* the type's own b-tree equality, under the column's collation (or a deterministic one) */
	eqop = get_opfamily_member(get_opclass_family(GetDefaultOpClass(pv->keytype, BTREE_AM_OID)),
							   pv->keytype, pv->keytype, BTEqualStrategyNumber);
	if (op->opno != eqop)
		return NULL;
	if (OidIsValid(op->inputcollid) && op->inputcollid != pv->keycoll && !get_collation_isdeterministic(op->inputcollid))
		return NULL;
	return r;
}

static void
point_rewrite(Query *q)
{
	RangeTblEntry *rte;
	RangeTblEntry *frte;
	Oid			view;
	PtView	   *pv;
	Node	   *quals;
	Node	   *keyexpr = NULL;
	List	   *conj;
	ListCell   *lc;
	Relation	vr;
	TupleDesc	vd;
	RangeTblFunction *rtf;
	FuncExpr   *fe;
	char	   *nsp;
	List	   *colnames = NIL;

	if (q->commandType != CMD_SELECT || q->utilityStmt != NULL || q->querySource != QSRC_ORIGINAL)
		return;
	if (q->hasAggs || q->hasWindowFuncs || q->hasTargetSRFs || q->hasSubLinks || q->hasDistinctOn ||
		q->hasRecursive || q->hasModifyingCTE || q->hasForUpdate || q->cteList || q->groupClause ||
		q->groupingSets || q->havingQual || q->windowClause || q->distinctClause || q->setOperations || q->rowMarks)
		return;
	if (list_length(q->rtable) != 1 || q->jointree == NULL || list_length(q->jointree->fromlist) != 1 ||
		!IsA(linitial(q->jointree->fromlist), RangeTblRef) || ((RangeTblRef *) linitial(q->jointree->fromlist))->rtindex != 1)
		return;
	rte = linitial_node(RangeTblEntry, q->rtable);
	if (rte->rtekind != RTE_RELATION || rte->relkind != RELKIND_VIEW || rte->tablesample || rte->lateral)
		return;
	view = rte->relid;
	nsp = get_namespace_name(get_rel_namespace(view));
	if (nsp == NULL || strncmp(nsp, "gnomon_r_", 9) != 0 || strstr(nsp, "__m") != NULL)
		return;
	if (!ActiveSnapshotSet() || get_namespace_oid("gnomon", true) == InvalidOid)
		return;
	/* the function checks SELECT on the whole view; a role with column grants keeps the view */
	if (pg_class_aclcheck(view, GetUserId(), ACL_SELECT) != ACLCHECK_OK)
		return;
	/* the extension may have been dropped and created again since: look the function up again */
	if (OidIsValid(c_point_fn) && !SearchSysCacheExists1(PROCOID, ObjectIdGetDatum(c_point_fn)))
		c_point_fn = InvalidOid;
	if (!OidIsValid(c_point_fn))
	{
		Oid			argtypes[3] = {OIDOID, INT2OID, ANYELEMENTOID};

		c_point_fn = func_oid("_gnomon", "c_point", 3, argtypes);
		if (!OidIsValid(c_point_fn))
			return;
	}
	pv = pt_view(view);
	if (!pv->usable)
		return;
	quals = q->jointree->quals;
	if (quals == NULL)
		return;
	conj = IsA(quals, BoolExpr) && ((BoolExpr *) quals)->boolop == AND_EXPR ? ((BoolExpr *) quals)->args : list_make1(quals);
	foreach(lc, conj)
	{
		keyexpr = key_operand(lfirst(lc), pv);
		if (keyexpr)
			break;
	}
	if (keyexpr == NULL)
		return;
	/* the function returns the view's columns in order, so the query's Vars only change RTE */
	vr = relation_open(view, AccessShareLock);
	vd = RelationGetDescr(vr);
	rtf = makeNode(RangeTblFunction);
	fe = makeFuncExpr(c_point_fn, RECORDOID,
					  list_make3(makeConst(OIDOID, -1, InvalidOid, sizeof(Oid), ObjectIdGetDatum(view), false, true),
								 makeConst(INT2OID, -1, InvalidOid, sizeof(int16), Int16GetDatum(pv->view_keyatt), false, true),
								 copyObject(keyexpr)), InvalidOid, InvalidOid, COERCE_EXPLICIT_CALL);
	fe->funcretset = true;
	/*
	 * The mark of a call this rewrite made, which SQL cannot write (the parser gives a function
	 * call this format only for the SQL-standard syntax of a few pg_catalog functions): only such
	 * a call becomes the custom scan, which relies on the view's own permission check (the view
	 * stays in the range table). A direct call keeps the function and its own check.
	 */
	fe->funcformat = COERCE_SQL_SYNTAX;
	rtf->funcexpr = (Node *) fe;
	rtf->funccolcount = vd->natts;
	for (int i = 0; i < vd->natts; i++)
	{
		Form_pg_attribute a = TupleDescAttr(vd, i);

		rtf->funccolnames = lappend(rtf->funccolnames, makeString(pstrdup(NameStr(a->attname))));
		rtf->funccoltypes = lappend_oid(rtf->funccoltypes, a->atttypid);
		rtf->funccoltypmods = lappend_int(rtf->funccoltypmods, a->atttypmod);
		rtf->funccolcollations = lappend_oid(rtf->funccolcollations, a->attcollation);
		colnames = lappend(colnames, makeString(pstrdup(NameStr(a->attname))));
	}
	relation_close(vr, AccessShareLock);
	frte = makeNode(RangeTblEntry);
	frte->rtekind = RTE_FUNCTION;
	frte->functions = list_make1(rtf);
	frte->funcordinality = false;
	frte->alias = copyObject(rte->alias);
	frte->eref = makeAlias(rte->eref->aliasname, colnames);
	frte->lateral = false;
	frte->inh = false;
	frte->inFromCl = true;
	/* every reference to RTE 1 (Vars, the FROM item) now names the function, RTE 2 */
	ChangeVarNodes((Node *) q, 1, 2, 0);
	q->rtable = lappend(q->rtable, frte);
	rte->inh = false;
	rte->inFromCl = false;
}

static PlannedStmt *
gnomon_planner(Query *parse, const char *query_string, int cursorOptions, ParamListInfo boundParams)
{
	if (substitute_enabled && IsTransactionState())
	{
		if (nsubst < 0)
			build_substs();
		if (nsubst > 0)
			(void) query_tree_walker(parse, subst_walker, NULL, 0);
	}
	if (prev_planner)
		return prev_planner(parse, query_string, cursorOptions, boundParams);
	return standard_planner(parse, query_string, cursorOptions, boundParams);
}

/* ------------------------------------------------------------------------ */

void
_PG_init(void)
{
	/* "on" only when preloaded: what the SQL core checks before relying on the module's hooks */
	DefineCustomStringVariable("gnomon.c_module", "Whether the gnomon C module is loaded (on) or only its functions (functions).", NULL,
							   &c_module_flag, process_shared_preload_libraries_in_progress ? "on" : "functions",
							   PGC_INTERNAL, 0, NULL, NULL, NULL);
	DefineCustomBoolVariable("gnomon.routing", "Route tracked tables to the current branch automatically.", NULL,
							 &routing_enabled, true, PGC_USERSET, 0, NULL, NULL, NULL);
	DefineCustomBoolVariable("gnomon.c_substitute", "Serve gnomon's read context and watermarks from C (planner hook).", NULL,
							 &substitute_enabled, true, PGC_USERSET, 0, NULL, NULL, NULL);
	DefineCustomBoolVariable("gnomon.c_touched_filter", "Let branch point reads skip the touched-key scan when the shared-memory filter says no level touched the key.", NULL,
							 &tf_enabled, true, PGC_USERSET, 0, NULL, NULL, NULL);
	DefineCustomBoolVariable("gnomon.c_point_reads", "Answer point reads by primary key through routing views with index probes.", NULL,
							 &point_enabled, true, PGC_USERSET, 0, NULL, NULL, NULL);
	DefineCustomBoolVariable("gnomon.c_search_views", "Read a table's search view instead of its routing view for a query whose restriction needs an index the branch policy would hide.", NULL,
							 &search_auto, true, PGC_USERSET, 0, NULL, NULL, NULL);
	DefineCustomBoolVariable("gnomon.c_direct_inserts", "Let the C trigger insert versions into the partition directly (no SPI plan).", NULL,
							 &direct_inserts, true, PGC_USERSET, 0, NULL, NULL, NULL);
	DefineCustomBoolVariable("gnomon.track_reads", "Record the keys a branch transaction reads, for stale-read detection.", NULL,
							 &track_reads, false, PGC_USERSET, 0, NULL, NULL, NULL);
	DefineCustomBoolVariable("gnomon.report_coordinate", "Report each statement's coordinate to the client in gnomon.last_coordinate.", NULL,
							 &report_coordinate, false, PGC_USERSET, 0, NULL, NULL, NULL);
	DefineCustomStringVariable("gnomon.last_coordinate", "The coordinate the last top-level statement read (gnomon.report_coordinate).", NULL,
							   &last_coordinate, "", PGC_INTERNAL, GUC_REPORT | GUC_NOT_IN_SAMPLE | GUC_DISALLOW_IN_FILE, NULL, NULL, NULL);
	/*
	 * Postmaster-level parts only when preloaded: loaded later (CREATE EXTENSION gnomon_c, or a
	 * restore of a database that has it, on a server without shared_preload_libraries) the
	 * functions still work; routing and the worker do not.
	 */
	if (process_shared_preload_libraries_in_progress)
	{
		DefineCustomStringVariable("gnomon.heartbeat_databases", "Databases where the worker runs gnomon.heartbeat().", NULL,
								   &heartbeat_databases, "", PGC_POSTMASTER, 0, NULL, NULL, NULL);
		DefineCustomIntVariable("gnomon.touched_filter_kb", "Shared memory for the touched-key filter, in kB (0: none).", NULL,
								&tf_kb, 1024, 0, 1048576, PGC_POSTMASTER, GUC_UNIT_KB, NULL, NULL, NULL);
	}
	else
		tf_kb = 0;
	DefineCustomIntVariable("gnomon.heartbeat_interval", "Milliseconds between heartbeats.", NULL,
							&heartbeat_interval_ms, 1000, 10, 3600000, PGC_SIGHUP, GUC_UNIT_MS, NULL, NULL, NULL);

	/* the C trigger and the C functions work in any backend; everything else needs the preload */
	CacheRegisterRelcacheCallback(relcache_cb, (Datum) 0);
	RegisterXactCallback(wc_xact_cb, NULL);
	RegisterSubXactCallback(wc_subxact_cb, NULL);
	if (!process_shared_preload_libraries_in_progress)
		return;
	register_workers();
	prev_shmem_request = shmem_request_hook;
	shmem_request_hook = wm_shmem_request;
	prev_shmem_startup = shmem_startup_hook;
	shmem_startup_hook = wm_shmem_startup;
	prev_planner = planner_hook;
	planner_hook = gnomon_planner;
	prev_set_rel_pathlist = set_rel_pathlist_hook;
	set_rel_pathlist_hook = pt_set_rel_pathlist;
	RegisterCustomScanMethods(&pt_scan_methods);
	CacheRegisterSyscacheCallback(PROCOID, proc_inval_cb, (Datum) 0);

	prev_post_parse_analyze = post_parse_analyze_hook;
	post_parse_analyze_hook = gnomon_post_parse_analyze;
	prev_process_utility = ProcessUtility_hook;
	ProcessUtility_hook = gnomon_process_utility;
	prev_executor_start = ExecutorStart_hook;
	ExecutorStart_hook = gnomon_executor_start;
	prev_executor_end = ExecutorEnd_hook;
	ExecutorEnd_hook = gnomon_executor_end;
	RegisterXactCallback(xact_callback, NULL);
}
