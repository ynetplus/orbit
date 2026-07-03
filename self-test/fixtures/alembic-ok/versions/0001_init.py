"""init

Orbit self-test fixture — single-head alembic tree (GREEN case for
alembic-single-head.yml). Minimal revision, no real upgrade/downgrade logic
needed since alembic-single-head.yml only runs `alembic heads` (graph parse,
no DB, no env.py execution).
"""

revision = "0001"
down_revision = None
branch_labels = None
depends_on = None


def upgrade():
    pass


def downgrade():
    pass
