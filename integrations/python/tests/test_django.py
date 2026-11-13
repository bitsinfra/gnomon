import psycopg
import pytest

django = pytest.importorskip("django")


@pytest.fixture(scope="module")
def django_setup(gnomon_dsn):
    from django.conf import settings

    parts = dict(p.split("=", 1) for p in gnomon_dsn.split())
    if not settings.configured:
        settings.configure(
            DATABASES={"default": {"ENGINE": "django.db.backends.postgresql", "NAME": parts["dbname"],
                                   "USER": parts["user"], "HOST": parts["host"], "PORT": parts["port"]}},
            MIDDLEWARE=["gnomon.django.BranchMiddleware"], ROOT_URLCONF=__name__, SECRET_KEY="x",
            ALLOWED_HOSTS=["*"], INSTALLED_APPS=[], DEFAULT_AUTO_FIELD="django.db.models.AutoField")
        django.setup()
    return settings


def view(request):
    from django.db import connection
    from django.http import JsonResponse

    with connection.cursor() as c:
        if request.method == "POST":
            c.execute("update account set name = %s where id = 7", [request.body.decode()])
        c.execute("select name from account where id = 7")
        return JsonResponse({"name": c.fetchone()[0]})


from django.urls import path  # noqa: E402

urlpatterns = [path("acct", view)]


def test_header_routes_request(django_setup, gnomon_dsn):
    from django.test import Client

    with psycopg.connect(gnomon_dsn, autocommit=True) as admin:
        admin.execute("select gnomon.create_branch('dj')")
    try:
        client = Client()
        r = client.post("/acct", data="from django", content_type="text/plain", HTTP_X_GNOMON_BRANCH="dj")
        assert r.json()["name"] == "from django"
        assert client.get("/acct").json()["name"] == "acct 7"            # no header: main
        assert client.get("/acct", HTTP_X_GNOMON_BRANCH="dj").json()["name"] == "from django"
    finally:
        from django.db import connections

        connections.close_all()
        with psycopg.connect(gnomon_dsn, autocommit=True) as admin:
            admin.execute("select gnomon.drop_branch('dj')")


def test_django_orm_on_a_branch(django_setup, gnomon_dsn):
    """Django's ORM itself (a model: get, save, create, delete, filter) on a branch."""
    from django.db import connection, connections, models

    class Account(models.Model):
        name = models.TextField()
        balance = models.IntegerField(default=0)

        class Meta:
            app_label = "gnomon_tests"
            db_table = "account"
            managed = False

    with psycopg.connect(gnomon_dsn, autocommit=True) as admin:
        admin.execute("select gnomon.create_branch('dj-orm')")
    try:
        with connection.cursor() as c:
            c.execute("select gnomon.use('dj-orm')")
        a = Account.objects.get(id=8)
        a.name = "django orm"
        a.save()
        Account.objects.filter(id=9).update(balance=999)
        Account.objects.create(id=100, name="created by django")
        Account.objects.get(id=10).delete()
        assert Account.objects.get(id=8).name == "django orm"
        assert Account.objects.filter(balance=999).count() == 1
        assert not Account.objects.filter(id=10).exists()
        with connection.cursor() as c:
            c.execute("select gnomon.use('main')")
        assert Account.objects.get(id=8).name == "acct 8"
        assert Account.objects.filter(id=10).exists() and not Account.objects.filter(id=100).exists()
    finally:
        connections.close_all()
        with psycopg.connect(gnomon_dsn, autocommit=True) as admin:
            admin.execute("select gnomon.drop_branch('dj-orm')")
