"""Tests on branches (docs/tutorial.md, part 1). Each test gets a scratch branch of the seeded shop
database through the gnomon pytest plugin, so tests never see each other's writes and nothing
reaches main. Run:

    GNOMON_TEST_DSN="dbname=shop user=shop_app" pytest examples/tests
"""


def cancel(conn, order_id):
    """The code under test: cancel an order and put its items back in stock."""
    conn.execute("update orders set status = 'cancelled' where id = %s and status = 'new'", (order_id,))
    conn.execute("""update products p set stock = p.stock + i.qty
                      from order_items i where i.order_id = %s and i.product_id = p.id""", (order_id,))


def test_cancel_puts_items_back(gnomon_conn):
    before = gnomon_conn.execute("select stock from products where id = 8").fetchone()[0]
    cancel(gnomon_conn, 1)     # order 1 holds 2 of product 8
    assert gnomon_conn.execute("select status from orders where id = 1").fetchone()[0] == "cancelled"
    assert gnomon_conn.execute("select stock from products where id = 8").fetchone()[0] == before + 2


def test_each_test_starts_from_the_seed(gnomon_conn):
    # the first test's cancellation happened on its own branch, gone now
    assert gnomon_conn.execute("select status from orders where id = 1").fetchone()[0] == "new"


def test_what_cancel_changes(gnomon_conn, gnomon_snapshot):
    cancel(gnomon_conn, 2)
    # the branch's diff, one line per changed field, against a file under __gnomon_snapshots__
    # (recorded on the first run, or with --gnomon-update-snapshots)
    gnomon_snapshot.assert_match(gnomon_conn)
